import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../domain/models.dart';
import 'database.dart';

class Repository extends ChangeNotifier {
  Repository(this.db, {DateTime Function()? clock})
    : now = clock ?? DateTime.now;
  final LocalDatabase db;
  final DateTime Function() now;
  final _uuid = const Uuid();
  late Snapshot snapshot;
  late String deviceId;
  String deviceName = Platform.localHostname;
  String syncStatus = 'Локально';
  String? syncError;
  CalendarView calendarView = CalendarView.day;
  double calendarFraction = .64, scratchpadFraction = .62;
  String? lastCalendarTaskId;
  int conflictCount = 0;
  Future<void> _tail = Future.value();
  Future<void> Function()? onChange;
  String newId() => _uuid.v4();
  void publish() => notifyListeners();

  Future<T> serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> initialize({String timezone = 'UTC'}) async {
    deviceId = await db.meta('device_id') ?? newId();
    await db.setMeta('device_id', deviceId);
    final view = await db.meta('calendar_view');
    calendarView =
        CalendarView.values.where((v) => v.name == view).firstOrNull ??
        CalendarView.day;
    calendarFraction =
        double.tryParse(await db.meta('home_calendar_fraction') ?? '') ?? .64;
    scratchpadFraction =
        double.tryParse(await db.meta('home_scratchpad_fraction') ?? '') ?? .62;
    lastCalendarTaskId = await db.meta('last_calendar_task');
    await reload();
    final initial = <Entity>[];
    if (await db.entity('scratchpad') == null) {
      initial.add(
        Note.create('scratchpad', 'Быстрая заметка', pinned: 'scratchpad'),
      );
    }
    if (await db.entity('reference') == null) {
      initial.add(Note.create('reference', 'Под рукой', pinned: 'reference'));
    }
    if (await db.entity('settings') == null) {
      initial.add(
        Entity(
          id: 'settings',
          kind: 'settings',
          data: {
            'default_minutes': 30,
            'reminders': [0],
            'timezone': timezone,
          },
        ),
      );
    }
    if (initial.isNotEmpty) await commit(initial);
    await rollover();
  }

  Future<void> reload() async {
    snapshot = Snapshot(await db.entities());
    conflictCount =
        (await db
                .customSelect('SELECT count(*) AS n FROM conflicts')
                .getSingle())
            .read<int>('n');
    notifyListeners();
  }

  Future<void> commit(List<Entity> changes) =>
      commitComputed(() async => changes);

  /// Compute dependent changes after queued local/sync writes have finished.
  Future<void> commitComputed(
    Future<List<Entity>> Function() compute,
  ) => serial(() async {
    final changes = await compute();
    if (changes.isEmpty) return;
    await db.transaction(() async {
      for (final proposed in changes) {
        final current = await db.entity(proposed.id);
        final record = proposed.withVersion(
          current?.version ?? proposed.version,
        );
        await db.put(record);
        final existing = await db
            .customSelect(
              'SELECT ordinal FROM outbox WHERE id=?',
              variables: [Variable(record.id)],
            )
            .getSingleOrNull();
        final ordinal =
            existing?.read<int>('ordinal') ??
            (int.parse(await db.meta('ordinal') ?? '0') + 1);
        if (existing == null) await db.setMeta('ordinal', '$ordinal');
        await db.customStatement(
          'INSERT INTO outbox(id,operation_id,payload,ordinal) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET operation_id=excluded.operation_id,payload=excluded.payload',
          [record.id, newId(), record.encoded, ordinal],
        );
      }
    });
    await reload();
    if (onChange != null) unawaited(onChange!());
  });
  Future<void> setView(CalendarView view) async {
    calendarView = view;
    notifyListeners();
    await db.setMeta('calendar_view', view.name);
  }

  Future<void> saveHomeLayout(double calendar, double scratchpad) async {
    calendarFraction = calendar.clamp(.25, .85);
    scratchpadFraction = scratchpad.clamp(.25, .75);
    await db.transaction(() async {
      await db.setMeta('home_calendar_fraction', '$calendarFraction');
      await db.setMeta('home_scratchpad_fraction', '$scratchpadFraction');
    });
    notifyListeners();
  }

  Task? get lastCalendarTask => snapshot.task(lastCalendarTaskId ?? '');

  Future<void> toggleCalendarTimer(Task task) async {
    await toggleTimer(task);
    lastCalendarTaskId = task.id;
    await db.setMeta('last_calendar_task', task.id);
    notifyListeners();
  }

  Future<Task> createTask(
    String title, {
    String description = '',
    String projectId = '',
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    List<int>? reminders,
    String? timezone,
  }) async {
    if (title.trim().isEmpty) throw ArgumentError('Введите название задачи');
    final task = Task.create(
      newId(),
      title,
      description: description,
      projectId: projectId,
    );
    final changes = [task];
    if (start != null) {
      final finish =
          end ?? start.add(Duration(minutes: snapshot.settings.defaultMinutes));
      validateInterval(start, finish);
      changes.add(
        TimeBlock.create(
          newId(),
          task.id,
          start,
          finish,
          timezone: timezone ?? snapshot.settings.timezone,
          allDay: allDay,
          reminders: reminders ?? snapshot.settings.reminders,
        ),
      );
    }
    await commit(changes);
    return Task(task);
  }

  Future<void> updateTask(
    Task task, {
    String? title,
    String? description,
    String? projectId,
  }) async {
    if (title != null && title.trim().isEmpty) {
      throw ArgumentError('Введите название');
    }
    await commit([
      task.entity.change({
        if (title != null) 'title': title.trim(),
        'description': ?description,
        'project_id': ?projectId,
      }),
    ]);
  }

  Future<void> status(Task task, TaskStatus status) async {
    final changes = [
      task.entity.change({'status': status.wire}),
    ];
    if (status == TaskStatus.done || status == TaskStatus.waiting) {
      for (final s in snapshot.sessions.where(
        (s) => s.taskId == task.id && s.running,
      )) {
        changes.add(s.entity.change({'end': wireTime(_safeEnd(s, now()))}));
      }
    }
    await commit(changes);
  }

  Future<void> completeForReview(Task task) async {
    if (task.done) return;
    final changes = [
      task.entity.change({'status': 'done'}),
      Task.create(
        newId(),
        'Проверить: ${task.title}',
        description: task.description,
        projectId: task.projectId,
        parentId: task.id,
      ),
    ];
    for (final s in snapshot.sessions.where(
      (s) => s.taskId == task.id && s.running,
    )) {
      changes.add(s.entity.change({'end': wireTime(_safeEnd(s, now()))}));
    }
    await commit(changes);
  }

  static void validateInterval(DateTime start, DateTime end) {
    if (!end.isAfter(start)) {
      throw ArgumentError('Конец должен быть позже начала');
    }
    if (end.difference(start) > const Duration(days: 366)) {
      throw ArgumentError('Интервал не может превышать 366 дней');
    }
  }

  Future<void> schedule(
    Task task,
    DateTime start,
    DateTime end, {
    bool allDay = false,
    List<int>? reminders,
    String? timezone,
  }) async {
    validateInterval(start, end);
    await commit([
      TimeBlock.create(
        newId(),
        task.id,
        start,
        end,
        timezone: timezone ?? snapshot.settings.timezone,
        allDay: allDay,
        reminders: reminders ?? snapshot.settings.reminders,
      ),
    ]);
  }

  Future<void> changeBlock(
    TimeBlock block,
    DateTime start,
    DateTime end, {
    bool? allDay,
    List<int>? reminders,
    String? timezone,
  }) async {
    validateInterval(start, end);
    await commit([
      block.entity.change({
        'start': wireTime(start),
        'end': wireTime(end),
        'historical': false,
        'all_day': ?allDay,
        'reminders': ?reminders,
        'timezone': ?timezone,
      }),
    ]);
  }

  Future<void> splitBlock(TimeBlock block, DateTime at) async {
    if (!at.isAfter(block.start) || !at.isBefore(block.end)) {
      throw ArgumentError('Выберите время внутри блока');
    }
    await commit([
      block.entity.change({'end': wireTime(at)}),
      TimeBlock.create(
        newId(),
        block.taskId,
        at,
        block.end,
        timezone: block.timezone,
        reminders: block.reminders,
      ),
    ]);
  }

  Future<void> unschedule(TimeBlock block) =>
      commit([block.entity.tombstone()]);
  Future<void> rollover() async {
    final boundary = snapshot.dayBoundary(now());
    final changes = snapshot.blocks
        .where(
          (b) =>
              !b.historical &&
              !b.end.isAfter(boundary) &&
              snapshot.task(b.taskId)?.done == false,
        )
        .map((b) => b.entity.change({'historical': true}))
        .toList();
    if (changes.isNotEmpty) await commit(changes);
  }

  DateTime _safeEnd(WorkSession s, DateTime value) => value.isAfter(s.start)
      ? value
      : s.start.add(const Duration(milliseconds: 1));
  Future<void> toggleTimer(Task task) async {
    if (task.done) throw StateError('Сначала верните задачу в работу');
    final time = now();
    final changes = <Entity>[];
    final running = snapshot.sessions.where((s) => s.running).toList();
    final stopping = running.any((s) => s.taskId == task.id);
    for (final s in running) {
      changes.add(s.entity.change({'end': wireTime(_safeEnd(s, time))}));
    }
    if (!stopping) {
      changes.add(task.entity.change({'status': 'in_progress'}));
      if (snapshot.unscheduled(task, time)) {
        changes.add(
          TimeBlock.create(
            newId(),
            task.id,
            time,
            time.add(Duration(minutes: snapshot.settings.defaultMinutes)),
            timezone: snapshot.settings.timezone,
            reminders: const [],
          ),
        );
      }
      changes.add(WorkSession.create(newId(), task.id, deviceId, time, null));
    }
    await commit(changes);
  }

  Future<void> saveSession(
    String taskId,
    DateTime start,
    DateTime end, {
    WorkSession? session,
  }) async {
    validateInterval(start, end);
    if (end.isAfter(now().add(const Duration(seconds: 2)))) {
      throw ArgumentError('Потраченное время не может находиться в будущем');
    }
    await commit([
      session == null
          ? WorkSession.create(newId(), taskId, deviceId, start, end)
          : session.entity.change({
              'start': wireTime(start),
              'end': wireTime(end),
            }),
    ]);
  }

  Future<void> discardSession(WorkSession session) => commit([
    session.entity.change({'discarded': true}),
  ]);

  /// Original records remain as discarded history. Union is applied per task so work is not attributed to a different task.
  Future<void> resolveSessions(
    SessionConflict conflict,
    String? selectedDevice,
  ) async {
    final changes = <Entity>[];
    final chosen = conflict.sessions
        .where((s) => selectedDevice == null || s.deviceId == selectedDevice)
        .toList();
    for (final s in conflict.sessions) {
      changes.add(
        s.entity.change({
          'discarded': true,
          if (s.end == null) 'end': wireTime(_safeEnd(s, now())),
        }),
      );
    }
    for (final taskId in chosen.map((s) => s.taskId).toSet()) {
      final ranges = unionRanges(
        chosen
            .where((s) => s.taskId == taskId)
            .map((s) => TimeRange(s.start, s.end ?? now())),
      );
      for (final range in ranges) {
        changes.add(
          WorkSession.create(newId(), taskId, deviceId, range.start, range.end),
        );
      }
    }
    await commit(changes);
  }

  Future<Note> createNote() async {
    final note = Note.create(newId(), 'Новая заметка');
    await commit([note]);
    return Note(note);
  }

  Future<void> saveNote(String id, String title, String content) async {
    final entity = await db.entity(id);
    if (entity == null || entity.deleted) return;
    await commit([
      entity.change({
        'title': title.trim().isEmpty ? 'Без названия' : title.trim(),
        'content': content,
      }),
    ]);
  }

  Future<void> saveProject(String title, int color, {Project? project}) async {
    if (title.trim().isEmpty) throw ArgumentError('Введите название проекта');
    await commit([
      project?.entity.change({'title': title.trim(), 'color': color}) ??
          Entity(
            id: newId(),
            kind: 'project',
            data: {'title': title.trim(), 'color': color},
          ),
    ]);
  }

  Future<void> deleteProject(Project project) async {
    await commit([
      ...snapshot.tasks
          .where((t) => t.projectId == project.id)
          .map((t) => t.entity.change({'project_id': ''})),
      ...snapshot.entities
          .where(
            (e) => e.kind == 'series' && e.data['project_id'] == project.id,
          )
          .map((e) => e.change({'project_id': ''})),
      project.entity.tombstone(),
    ]);
  }

  Future<void> deleteEntity(Entity entity) async {
    if (entity.id == 'scratchpad' || entity.id == 'reference') {
      throw ArgumentError('Постоянная заметка не удаляется');
    }
    final changes = <Entity>[];
    if (entity.kind == 'task') {
      final task = Task(entity);
      if (task.seriesId.isNotEmpty) {
        final series = await db.entity(task.seriesId);
        if (series != null) {
          changes.add(
            series.change({
              'exceptions': [
                ...List<String>.from(series.data['exceptions'] as List? ?? []),
                task.occurrence,
              ],
            }),
          );
        }
      }
      changes.addAll(
        snapshot.blocks
            .where((b) => b.taskId == entity.id)
            .map((b) => b.entity.tombstone()),
      );
      changes.addAll(
        snapshot.sessions
            .where((s) => s.taskId == entity.id)
            .map((s) => s.entity.tombstone()),
      );
      changes.addAll(
        snapshot.entities
            .where((e) => e.kind == 'snooze' && e.data['task_id'] == entity.id)
            .map((e) => e.tombstone()),
      );
    }
    changes.add(entity.tombstone());
    await commit(changes);
  }

  Future<void> updateSettings(
    int minutes,
    List<int> reminders,
    String timezone,
  ) async {
    if (minutes < 5 || minutes > 1440) {
      throw ArgumentError('Длительность: от 5 до 1440 минут');
    }
    await commit([
      snapshot.settings.entity.change({
        'default_minutes': minutes,
        'reminders': reminders,
        'timezone': timezone,
      }),
    ]);
  }

  Future<String> attachFile(String sourcePath) async {
    final source = File(sourcePath);
    if (await source.length() > 50 * 1024 * 1024) {
      throw ArgumentError('Размер файла не должен превышать 50 МБ');
    }
    final digest = await sha256.bind(source.openRead()).first;
    final id = digest.toString();
    final directory = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'attachments'),
    );
    await directory.create(recursive: true);
    final extension = p.extension(sourcePath).toLowerCase();
    final target = p.join(
      directory.path,
      '$id${RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension) ? extension : ''}',
    );
    await source.copy(target);
    await db.customStatement(
      'INSERT INTO files(id,name,path) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path',
      [id, p.basename(sourcePath), target],
    );
    if (onChange != null) unawaited(onChange!());
    final label = p.basename(sourcePath).replaceAll(RegExp(r'[\[\]\n\r]'), '');
    return '${RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(sourcePath) ? '!' : ''}[$label](attachment:$id)';
  }

  Future<String?> attachmentPath(String id) async =>
      (await db
              .customSelect(
                'SELECT path FROM files WHERE id=?',
                variables: [Variable(id)],
              )
              .getSingleOrNull())
          ?.read<String>('path');
  Future<List<Map<String, dynamic>>> conflicts() async =>
      (await db.customSelect('SELECT * FROM conflicts').get())
          .map(
            (r) => {
              'id': r.read<String>('id'),
              'local': jsonDecode(r.read<String>('local')),
              'remote': jsonDecode(r.read<String>('remote')),
            },
          )
          .toList();
  Future<void> resolveRecordConflict(
    String id, {
    required bool keepLocal,
    bool keepBoth = false,
  }) async {
    final row = await db
        .customSelect(
          'SELECT * FROM conflicts WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingle();
    final local = Entity.fromJson(
      jsonDecode(row.read<String>('local')) as Map<String, dynamic>,
    );
    final remote = Entity.fromJson(
      jsonDecode(row.read<String>('remote')) as Map<String, dynamic>,
    );
    await serial(() async {
      await db.transaction(() async {
        await db.put(remote);
        await db.customStatement('DELETE FROM conflicts WHERE id=?', [id]);
      });
      await reload();
    });
    if (keepBoth && local.kind == 'note') {
      await commit([
        Entity(
          id: newId(),
          kind: 'note',
          data: {
            ...local.data,
            'title': '${local.data['title']} — копия с устройства',
            'pinned': '',
          },
        ),
      ]);
    } else if (keepLocal) {
      await commit([local.withVersion(remote.version)]);
    }
  }

  Future<void> snooze(String taskId, Duration delay) => commit([
    Entity(
      id: newId(),
      kind: 'snooze',
      data: {'task_id': taskId, 'at': wireTime(now().add(delay))},
    ),
  ]);
  @override
  void dispose() {
    db.close();
    super.dispose();
  }
}
