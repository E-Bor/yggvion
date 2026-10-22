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
import '../domain/note_links.dart';
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
  CalendarView plannerView = CalendarView.day;
  bool sidebarCollapsed = false;
  bool lightTheme = false;
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
    final planner = await db.meta('planner_view');
    plannerView =
        CalendarView.values.where((v) => v.name == planner).firstOrNull ??
        calendarView;
    if (planner != plannerView.name) {
      await db.setMeta('planner_view', plannerView.name);
    }
    sidebarCollapsed = await db.meta('sidebar_collapsed') == 'true';
    lightTheme = await db.meta('light_theme') == 'true';
    calendarFraction =
        double.tryParse(await db.meta('home_calendar_fraction') ?? '') ?? .64;
    scratchpadFraction =
        double.tryParse(await db.meta('home_scratchpad_fraction') ?? '') ?? .62;
    lastCalendarTaskId = await db.meta('last_calendar_task');
    await reload();
    final initial = <Entity>[];
    for (final record in workspaceDefaults(timezone)) {
      if (await db.entity(record.id) == null) initial.add(record);
    }
    if (initial.isNotEmpty) await commit(initial);
    await rollover();
  }

  static List<Entity> workspaceDefaults(String timezone) => [
    Note.create('scratchpad', 'Быстрая заметка', pinned: 'scratchpad'),
    Note.create('reference', 'Под рукой', pinned: 'reference'),
    Entity(
      id: 'settings',
      kind: 'settings',
      data: {
        'default_minutes': 30,
        'reminders': [0],
        'timezone': timezone,
      },
    ),
  ];

  Future<void> reload() async {
    snapshot = Snapshot(await db.entities());
    conflictCount =
        (await db
                .customSelect('SELECT count(*) AS n FROM conflicts')
                .getSingle())
            .read<int>('n');
    notifyListeners();
  }

  Future<List<({String id, String created})>> localRecoverySnapshots() async {
    final rows = await db
        .customSelect(
          'SELECT id,created FROM recovery_snapshots ORDER BY created DESC',
        )
        .get();
    return rows
        .map(
          (row) => (
            id: row.read<String>('id'),
            created: row.read<String>('created'),
          ),
        )
        .toList();
  }

  Future<String> localRecoveryPayload(String id) async {
    final row = await db
        .customSelect(
          'SELECT payload FROM recovery_snapshots WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingle();
    return row.read<String>('payload');
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
  Future<void> setView(CalendarView view, {bool planner = false}) async {
    if (planner) {
      plannerView = view;
    } else {
      calendarView = view;
    }
    notifyListeners();
    await serial(
      () => db.setMeta(planner ? 'planner_view' : 'calendar_view', view.name),
    );
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

  Future<void> setSidebarCollapsed(bool value) async {
    sidebarCollapsed = value;
    notifyListeners();
    await serial(() => db.setMeta('sidebar_collapsed', '$value'));
  }

  Future<void> setLightTheme(bool value) => serial(() async {
    await db.setMeta('light_theme', '$value');
    lightTheme = value;
    notifyListeners();
  });

  Task? get lastCalendarTask => snapshot.task(lastCalendarTaskId ?? '');

  /// The shared running timer takes precedence over this device's last choice.
  Task? get globalTimerTask {
    WorkSession? latest;
    for (final session in snapshot.sessions) {
      if (!session.running) continue;
      final task = snapshot.task(session.taskId);
      if (task == null || task.done) continue;
      if (latest == null || session.start.isAfter(latest.start)) {
        latest = session;
      }
    }
    return latest == null ? lastCalendarTask : snapshot.task(latest.taskId);
  }

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
      task.entity.change({'status': status.wire, 'completed_at': status == TaskStatus.done ? wireTime(now()) : null}),
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
    bool acceptProposedTime = false,
    bool allDay = false,
    List<int>? reminders,
    String? timezone,
  }) async {
    validateInterval(start, end);
    await commitComputed(() async {
      final current = snapshot.task(task.id);
      if (current == null || (task.isProposed && !current.isProposed)) {
        return [];
      }
      if (acceptProposedTime) {
        if (!current.isProposed) return [];
        if (start.isBefore(now())) {
          throw StateError(
            'Предложенное время уже прошло. Выберите другой интервал в календаре.',
          );
        }
        if (snapshot.blocks.any(
          (b) =>
              !b.historical &&
              snapshot.task(b.taskId)?.isBirthday == false &&
              b.start.isBefore(end) &&
              b.end.isAfter(start),
        )) {
          throw StateError(
            'Это время уже занято. Выберите другой интервал в календаре.',
          );
        }
      }
      return [
        if (current.isProposed)
          current.entity.change({
            'proposal': {...current.proposal!, 'pending': false},
          }),
        TimeBlock.create(
          current.isProposed ? 'proposal_${current.id}' : newId(),
          current.id,
          start,
          end,
          timezone: timezone ?? snapshot.settings.timezone,
          allDay: allDay,
          reminders: reminders ?? snapshot.settings.reminders,
        ),
      ];
    });
  }

  Future<void> acceptProposal(Task task) async {
    final current = snapshot.task(task.id);
    if (current == null || !current.isProposed) return;
    await schedule(
      current,
      current.proposedStart!,
      current.proposedEnd!,
      timezone: current.proposedTimezone,
      acceptProposedTime: true,
    );
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
              snapshot.task(b.taskId)?.isBirthday != true &&
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

  /// Persist a calendar selection atomically; cancellation never writes drafts.
  Future<void> saveSessionRanges(
    String taskId,
    List<TimeRange> ranges, {
    WorkSession? replacing,
  }) async {
    if (ranges.isEmpty) throw ArgumentError('Выделите хотя бы один интервал');
    for (final range in ranges) {
      validateInterval(range.start, range.end);
      if (range.end.isAfter(now().add(const Duration(seconds: 2)))) {
        throw ArgumentError('Потраченное время не может находиться в будущем');
      }
    }
    await commitComputed(() async {
      final task = await db.entity(taskId);
      if (task == null || task.deleted) throw StateError('Задача уже удалена');
      Entity? current;
      if (replacing != null) {
        current = await db.entity(replacing.id);
        if (current == null ||
            current.deleted ||
            current.data['discarded'] == true ||
            current.data['task_id'] != taskId) {
          throw StateError('Запись времени уже удалена');
        }
        if (current.encoded != replacing.entity.encoded) {
          throw StateError('Запись времени изменилась. Откройте её заново');
        }
      }
      return [
        if (current != null)
          current.change({
            'discarded': true,
            if (current.data['end'] == null)
              'end': wireTime(_safeEnd(WorkSession(current), now())),
          }),
        for (final range in ranges)
          WorkSession.create(newId(), taskId, deviceId, range.start, range.end),
      ];
    });
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

  Future<Note> createNote({String folderId = ''}) async {
    late Entity note;
    await commitComputed(() async {
      if (folderId.isNotEmpty &&
          !snapshot.noteFolders.any((folder) => folder.id == folderId)) {
        throw ArgumentError('Папка уже удалена');
      }
      final siblings = snapshot.notesInFolder(folderId);
      note = Note.create(newId(), 'Новая заметка').change({
        'folder_id': folderId,
        'sort_order': (siblings.lastOrNull?.sortOrder ?? 0) + 1024,
      });
      return [note];
    });
    return Note(note);
  }

  /// Keep readable wiki links attached to their original notes when a title,
  /// heading or folder changes. These text edits share the same sync transaction.
  List<Entity> _preserveNoteLinks(List<Entity> changes) {
    final changed = {for (final entity in changes) entity.id: entity};
    final affectsNames = changes.any((entity) {
      if (entity.kind == 'note_folder') return true;
      if (entity.kind != 'note' || entity.deleted) return false;
      final old = snapshot.note(entity.id);
      final next = Note(entity);
      return old != null &&
          (old.displayLabel != next.displayLabel ||
              old.folderId != next.folderId);
    });
    if (!affectsNames) return changes;
    final existingIds = snapshot.entities.map((e) => e.id).toSet();
    final after = Snapshot([
      for (final entity in snapshot.entities)
        if (!(changed[entity.id] ?? entity).deleted)
          changed[entity.id] ?? entity,
      for (final entity in changes)
        if (!entity.deleted && !existingIds.contains(entity.id)) entity,
    ]);
    final beforeLinks = WikiNoteIndex(snapshot),
        afterLinks = WikiNoteIndex(after);
    for (final entity in after.entities) {
      final field = switch (entity.kind) {
        'note' => 'content',
        'task' || 'series' => 'description',
        _ => null,
      };
      if (field == null) continue;
      final text = entity.data[field] as String? ?? '';
      if (!text.contains('[[')) continue;
      final updated = beforeLinks.relink(text, afterLinks);
      if (updated != text) changed[entity.id] = entity.change({field: updated});
    }
    return changed.values.toList();
  }

  Future<void> saveNote(String id, String title, String content) =>
      commitComputed(() async {
        final entity = await db.entity(id);
        if (entity == null || entity.deleted) return [];
        return _preserveNoteLinks([
          entity.change({
            'title': title.trim().isEmpty ? 'Новая заметка' : title.trim(),
            'content': content,
          }),
        ]);
      });

  Future<void> renameNote(String id, String title) => commitComputed(() async {
    if (utf8.encode(title.trim()).length > 1000) {
      throw ArgumentError('Название слишком длинное');
    }
    final entity = await db.entity(id);
    if (entity == null || entity.deleted || entity.kind != 'note') return [];
    return _preserveNoteLinks([
      entity.change({
        'title': title.trim().isEmpty ? 'Новая заметка' : title.trim(),
      }),
    ]);
  });

  Future<void> saveNoteContent(String id, String content) => commitComputed(
    () async {
      final entity = await db.entity(id);
      if (entity == null || entity.deleted || entity.kind != 'note') return [];
      return _preserveNoteLinks([
        entity.change({'content': content}),
      ]);
    },
  );

  Future<void> saveNoteFolder(String title, {NoteFolder? folder}) async {
    if (title.trim().isEmpty || utf8.encode(title.trim()).length > 1000) {
      throw ArgumentError('Введите название папки до 250 символов');
    }
    await commitComputed(
      () async => _preserveNoteLinks([
        folder?.entity.change({'title': title.trim()}) ??
            Entity(
              id: newId(),
              kind: 'note_folder',
              data: {
                'title': title.trim(),
                'sort_order':
                    (snapshot.noteFolders.lastOrNull?.sortOrder ?? 0) + 1024,
              },
            ),
      ]),
    );
  }

  Future<void> deleteNoteFolder(NoteFolder folder) => commitComputed(
    () async => _preserveNoteLinks([
      for (final note in snapshot.notes.where((n) => n.folderId == folder.id))
        note.entity.change({'folder_id': ''}),
      folder.entity.tombstone(),
    ]),
  );

  Future<void> moveNote(String id, String folderId, {String? beforeId}) =>
      commitComputed(() async {
        final note = snapshot.note(id);
        if (note == null || note.pinned.isNotEmpty) return [];
        if (folderId.isNotEmpty &&
            !snapshot.noteFolders.any((f) => f.id == folderId)) {
          throw ArgumentError('Папка уже удалена');
        }
        final siblings = snapshot
            .notesInFolder(folderId)
            .where((n) => n.id != id)
            .toList();
        var index = beforeId == null
            ? siblings.length
            : siblings.indexWhere((n) => n.id == beforeId);
        if (index < 0) index = siblings.length;
        final lower = index == 0
            ? (siblings.firstOrNull?.sortOrder ?? 0) - 2048
            : siblings[index - 1].sortOrder;
        final upper = index == siblings.length
            ? lower + 2048
            : siblings[index].sortOrder;
        if (upper - lower > 1 && lower.abs() < 1000000000000) {
          return _preserveNoteLinks([
            note.entity.change({
              'folder_id': folderId,
              'sort_order': (lower + upper) ~/ 2,
            }),
          ]);
        }
        siblings.insert(index, note);
        return _preserveNoteLinks([
          for (var i = 0; i < siblings.length; i++)
            siblings[i].entity.change({
              'folder_id': folderId,
              'sort_order': (i + 1) * 1024,
            }),
        ]);
      });

  Future<void> reorderNoteFolders(List<String> ids) => commitComputed(
    () async => [
      for (var i = 0; i < ids.length; i++)
        for (final folder in snapshot.noteFolders.where((f) => f.id == ids[i]))
          folder.entity.change({'sort_order': (i + 1) * 1024}),
    ],
  );

  Future<void> discardEmptyNotes(Iterable<String> noteIds) {
    final ids = noteIds.toSet();
    return commitComputed(() async {
      final changes = <Entity>[];
      for (final id in ids) {
        if (id == 'scratchpad' || id == 'reference') continue;
        final entity = await db.entity(id);
        if (entity == null || entity.deleted || entity.kind != 'note') continue;
        final note = Note(entity);
        if (note.pinned.isEmpty &&
            note.explicitTitle.isEmpty &&
            note.content.trim().isEmpty) {
          changes.add(entity.tombstone());
        }
      }
      return changes;
    });
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
    String timezone, {
    int? accentColor,
    int? searchTypos,
  }) async {
    if (minutes < 5 || minutes > 1440) {
      throw ArgumentError('Длительность: от 5 до 1440 минут');
    }
    if (accentColor != null &&
        (accentColor < 0xff000000 || accentColor > 0xffffffff)) {
      throw ArgumentError('Выберите непрозрачный акцентный цвет');
    }
    if (searchTypos != null && (searchTypos < 0 || searchTypos > 2)) {
      throw ArgumentError('Допустимо от 0 до 2 опечаток');
    }
    await commitComputed(() async {
      final current = await db.entity('settings');
      if (current == null || current.deleted) {
        throw StateError('Настройки недоступны');
      }
      return [
        current.change({
          'default_minutes': minutes,
          'reminders': reminders,
          'timezone': timezone,
          'task_color': ?accentColor,
          'search_typos': ?searchTypos,
        }),
      ];
    });
  }

  static const maxAttachmentMiB = 300;
  static const maxAttachmentBytes = maxAttachmentMiB * 1024 * 1024;
  static const attachmentSizeError =
      'Размер файла не должен превышать $maxAttachmentMiB МБ';

  /// Materialize native clipboard streams without retaining the whole file in RAM.
  Future<String> attachStream(Stream<List<int>> stream, String name) async {
    final directory = await Directory.systemTemp.createTemp('yggvion-paste-');
    final basename = p
        .basename(name.replaceAll('\\', '/'))
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .trim();
    final safeName = basename.isEmpty || basename == '.' || basename == '..'
        ? 'Вложение'
        : basename;
    final file = File(p.join(directory.path, safeName));
    try {
      final sink = await file.open(mode: FileMode.write);
      var size = 0;
      try {
        await for (final chunk in stream) {
          size += chunk.length;
          if (size > maxAttachmentBytes) {
            throw ArgumentError(attachmentSizeError);
          }
          await sink.writeFrom(chunk);
        }
      } finally {
        await sink.close();
      }
      return await attachFile(file.path);
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<String> attachFile(String sourcePath) async {
    final source = File(sourcePath);
    if (await source.length() > maxAttachmentBytes) {
      throw ArgumentError(attachmentSizeError);
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
