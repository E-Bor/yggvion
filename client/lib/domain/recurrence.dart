import 'package:rrule/rrule.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../data/repository.dart';
import 'models.dart';

enum RepeatScope { instance, following, series }

class RecurrenceService {
  RecurrenceService(this.repo);
  final Repository repo;
  bool _expanding = false;
  static DateTime wall(DateTime value) => DateTime.utc(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
    value.second,
  );
  static RecurrenceRule parse(String value) => RecurrenceRule.fromString(
    value.startsWith('RRULE:') ? value : 'RRULE:$value',
  );

  Future<void> delete(Task task, RepeatScope scope) async {
    if (task.seriesId.isEmpty || scope == RepeatScope.instance) {
      await repo.deleteEntity(task.entity);
      return;
    }
    final series = await repo.db.entity(task.seriesId);
    if (series == null || series.deleted) {
      await repo.deleteEntity(task.entity);
      return;
    }
    final cutoff = parseTime(task.occurrence);
    final entire =
        scope == RepeatScope.series ||
        !cutoff.isAfter(parseTime(series.data['start']));
    await repo.commitComputed(() async {
      final current = await repo.db.entity(series.id);
      if (current == null || current.deleted) return [];
      final snapshot = Snapshot(await repo.db.entities());
      final ids = snapshot.tasks
          .where(
            (t) =>
                t.seriesId == task.seriesId &&
                (entire || !parseTime(t.occurrence).isBefore(cutoff)),
          )
          .map((t) => t.id)
          .toSet();
      return [
        if (entire)
          current.tombstone()
        else
          current.change({
            'cancelled_from': wireTime(cutoff),
            'rule': parse(current.data['rule'] as String)
                .copyWith(
                  until: cutoff.subtract(const Duration(seconds: 1)),
                  clearCount: true,
                )
                .toString(),
          }),
        ...snapshot.entities
            .where(
              (e) =>
                  (e.kind == 'task' && ids.contains(e.id)) ||
                  ({'block', 'session', 'snooze'}.contains(e.kind) &&
                      ids.contains(e.data['task_id'])),
            )
            .map((e) => e.tombstone()),
      ];
    });
  }

  /// A new pattern starts at this occurrence. Past work and tracked future
  /// exceptions survive as independent tasks; unworked future plans regenerate.
  Future<void> changeRuleFrom(Task task, String rule) async {
    if (rule.isNotEmpty) parse(rule);
    final blocks = repo.snapshot.taskBlocks(task.id);
    if (blocks.isEmpty) throw StateError('Сначала запланируйте задачу');
    if (task.seriesId.isEmpty) {
      if (rule.isNotEmpty) await create(task, blocks.first, rule);
      return;
    }
    final old = await repo.db.entity(task.seriesId);
    if (old == null || old.deleted) throw StateError('Серия уже удалена');
    final cutoff = parseTime(task.occurrence), block = blocks.first;
    final changes = <Entity>[
      old.change({
        'rule': parse(old.data['rule'] as String)
            .copyWith(
              until: cutoff.subtract(const Duration(seconds: 1)),
              clearCount: true,
            )
            .toString(),
      }),
    ];
    final exceptions = <String>[];
    for (final next in repo.snapshot.tasks.where(
      (t) =>
          t.id != task.id &&
          t.seriesId == task.seriesId &&
          !parseTime(t.occurrence).isBefore(cutoff),
    )) {
      if (next.done ||
          repo.snapshot.sessions.any(
            (s) => s.taskId == next.id && !s.discarded,
          )) {
        changes.add(next.entity.change({'series_id': '', 'occurrence': ''}));
        exceptions.addAll(
          repo.snapshot.taskBlocks(next.id).map((b) => occurrenceKey(b.start)),
        );
      } else {
        changes.add(next.entity.tombstone());
        changes.addAll(
          repo.snapshot.entities
              .where(
                (e) =>
                    {'block', 'session', 'snooze'}.contains(e.kind) &&
                    e.data['task_id'] == next.id,
              )
              .map((e) => e.tombstone()),
        );
      }
    }
    final id = rule.isEmpty ? '' : repo.newId();
    final zone = tz.getLocation(block.timezone);
    if (rule.isNotEmpty) {
      changes.add(
        Entity(
          id: id,
          kind: 'series',
          data: {
            ...old.data,
            'cancelled_from': null,
            'title': task.title,
            'description': task.description,
            'project_id': task.projectId,
            'start': wireTime(block.start),
            'timezone': block.timezone,
            'anchor_timezone': block.timezone,
            'minutes': block.duration.inMinutes,
            'day_span': wall(
              tz.TZDateTime.from(block.end, zone),
            ).difference(wall(tz.TZDateTime.from(block.start, zone))).inDays,
            'offset_minutes': 0,
            'rule': rule,
            'reminders': block.reminders,
            'all_day': block.allDay,
            'exceptions': exceptions,
          },
        ),
      );
    }
    changes.add(
      task.entity.change({
        'series_id': id,
        'occurrence': id.isEmpty ? '' : occurrenceKey(block.start),
      }),
    );
    await repo.commit(changes);
    if (rule.isNotEmpty) {
      await expand(block.start, block.start.add(const Duration(days: 90)));
    }
  }

  Future<void> create(Task task, TimeBlock block, String rule) async {
    parse(rule);
    final id = repo.newId();
    final series = Entity(
      id: id,
      kind: 'series',
      data: {
        'title': task.title,
        'description': task.description,
        'project_id': task.projectId,
        'start': wireTime(block.start),
        'minutes': block.duration.inMinutes,
        'timezone': block.timezone,
        'anchor_timezone': block.timezone,
        'day_span':
            wall(tz.TZDateTime.from(block.end, tz.getLocation(block.timezone)))
                .difference(
                  wall(
                    tz.TZDateTime.from(
                      block.start,
                      tz.getLocation(block.timezone),
                    ),
                  ),
                )
                .inDays,
        'rule': rule,
        'reminders': block.reminders,
        'all_day': block.allDay,
        'exceptions': <String>[],
      },
    );
    await repo.commit([
      series,
      task.entity.change({
        'series_id': id,
        'occurrence': occurrenceKey(block.start),
      }),
    ]);
    await expand(
      repo.now().subtract(const Duration(days: 1)),
      repo.now().add(const Duration(days: 90)),
    );
  }

  Future<void> expand(DateTime from, DateTime to) async {
    if (_expanding) return;
    _expanding = true;
    try {
      final all = await repo.db.entities(includeDeleted: true);
      final known = all.map((e) => e.id).toSet();
      final changes = <Entity>[];
      final expectedSeries = {
        for (final e in repo.snapshot.entities.where((e) => e.kind == 'series'))
          e.id: e.encoded,
      };
      for (final series in repo.snapshot.entities.where(
        (e) => e.kind == 'series',
      )) {
        final d = series.data,
            location = tz.getLocation(
              (series.data['anchor_timezone'] ?? series.data['timezone'])
                  as String,
            );
        final displayLocation = tz.getLocation(d['timezone'] as String);
        final original = tz.TZDateTime.from(parseTime(d['start']), location);
        final exceptions = (d['exceptions'] as List? ?? [])
            .cast<String>()
            .map((value) => occurrenceKey(parseTime(value)))
            .toSet();
        final existing = repo.snapshot.tasks
            .where((t) => t.seriesId == series.id)
            .map((t) => t.occurrence)
            .toSet();
        var rule = parse(d['rule'] as String);
        if (rule.until != null) {
          rule = rule.copyWith(
            until: wall(tz.TZDateTime.from(rule.until!, location)),
          );
        }
        if (to.isBefore(original)) continue;
        final lower = from.isBefore(original)
            ? original
            : tz.TZDateTime.from(from, location);
        final occurrences = rule
            .getInstances(
              start: wall(original),
              after: wall(lower),
              includeAfter: true,
              before: wall(tz.TZDateTime.from(to, location)),
              includeBefore: true,
            )
            .take(5000);
        for (final occurrence in occurrences) {
          final local = tz.TZDateTime(
            location,
            occurrence.year,
            occurrence.month,
            occurrence.day,
            occurrence.hour,
            occurrence.minute,
            occurrence.second,
          );
          // Nonexistent local times during spring transition are skipped, rather than silently shifted.
          if (local.hour != occurrence.hour ||
              local.minute != occurrence.minute) {
            continue;
          }
          final key = wireTime(local),
              id = const Uuid().v5(
                '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
                'yggvion:${series.id}:$key',
              );
          if (exceptions.contains(key) ||
              existing.contains(key) ||
              known.contains(id)) {
            continue;
          }
          final shifted = occurrence.add(
            Duration(minutes: d['offset_minutes'] as int? ?? 0),
          );
          final start = tz.TZDateTime(
            displayLocation,
            shifted.year,
            shifted.month,
            shifted.day,
            shifted.hour,
            shifted.minute,
            shifted.second,
          );
          DateTime end = start.add(Duration(minutes: d['minutes'] as int));
          if (d['all_day'] == true) {
            end = tz.TZDateTime(
              displayLocation,
              start.year,
              start.month,
              start.day +
                  ((d['day_span'] as int? ??
                          ((d['minutes'] as int) / 1440).round())
                      .clamp(1, 366)),
              start.hour,
              start.minute,
            );
          }
          changes.add(
            Task.create(
              id,
              d['title'] as String,
              description: d['description'] as String,
              projectId: d['project_id'] as String,
              seriesId: series.id,
              occurrence: key,
            ),
          );
          changes.add(
            TimeBlock.create(
              const Uuid().v5(
                '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
                'block:$id',
              ),
              id,
              start,
              end,
              timezone: displayLocation.name,
              allDay: d['all_day'] as bool? ?? false,
              reminders: (d['reminders'] as List).cast<int>(),
            ),
          );
        }
      }
      if (changes.isNotEmpty) {
        await repo.commitComputed(() async {
          final current = {
            for (final e in await repo.db.entities(includeDeleted: true))
              e.id: e,
          };
          final accepted = changes
              .where(
                (e) =>
                    e.kind == 'task' &&
                    !current.containsKey(e.id) &&
                    current[e.data['series_id']]?.deleted == false &&
                    current[e.data['series_id']]?.encoded ==
                        expectedSeries[e.data['series_id']],
              )
              .map((e) => e.id)
              .toSet();
          return changes
              .where(
                (e) => e.kind == 'task'
                    ? accepted.contains(e.id)
                    : accepted.contains(e.data['task_id']) &&
                          !current.containsKey(e.id),
              )
              .toList();
        });
      }
    } finally {
      _expanding = false;
    }
  }

  Future<void> edit(
    Task task,
    RepeatScope scope, {
    required String title,
    required String description,
    required String projectId,
  }) async {
    if (scope == RepeatScope.instance || task.seriesId.isEmpty) {
      await repo.updateTask(
        task,
        title: title,
        description: description,
        projectId: projectId,
      );
      return;
    }
    final series = await repo.db.entity(task.seriesId);
    if (series == null) return;
    final changes = <Entity>[];
    if (scope == RepeatScope.series) {
      changes.add(
        series.change({
          'title': title,
          'description': description,
          'project_id': projectId,
        }),
      );
      changes.addAll(
        repo.snapshot.tasks
            .where((t) => t.seriesId == task.seriesId)
            .map(
              (t) => t.entity.change({
                'title': title,
                'description': description,
                'project_id': projectId,
              }),
            ),
      );
    } else {
      final occurrence = parseTime(task.occurrence);
      final cutoff = occurrence.subtract(const Duration(seconds: 1));
      final oldRule = parse(series.data['rule'] as String);
      final anchorLocation = tz.getLocation(
        (series.data['anchor_timezone'] ?? series.data['timezone']) as String,
      );
      var followingRule = oldRule;
      if (oldRule.count != null) {
        final before = oldRule
            .getInstances(
              start: wall(
                tz.TZDateTime.from(
                  parseTime(series.data['start']),
                  anchorLocation,
                ),
              ),
              before: wall(tz.TZDateTime.from(occurrence, anchorLocation)),
            )
            .length;
        followingRule = oldRule.copyWith(
          count: (oldRule.count! - before).clamp(1, oldRule.count!),
        );
      }
      changes.add(
        series.change({
          'rule': oldRule.copyWith(until: cutoff, clearCount: true).toString(),
        }),
      );
      final id = repo.newId();
      changes.add(
        Entity(
          id: id,
          kind: 'series',
          data: {
            ...series.data,
            'title': title,
            'description': description,
            'project_id': projectId,
            'start': wireTime(occurrence),
            'rule': followingRule.toString(),
            'exceptions': List<String>.from(
              series.data['exceptions'] as List? ?? [],
            ).where((e) => !parseTime(e).isBefore(occurrence)).toList(),
          },
        ),
      );
      changes.addAll(
        repo.snapshot.tasks
            .where(
              (t) =>
                  t.seriesId == task.seriesId &&
                  !parseTime(t.occurrence).isBefore(occurrence),
            )
            .map(
              (t) => t.entity.change({
                'series_id': id,
                'title': title,
                'description': description,
                'project_id': projectId,
              }),
            ),
      );
    }
    await repo.commit(changes);
  }

  Future<void> editTiming(
    TimeBlock block,
    RepeatScope scope,
    DateTime start,
    DateTime end, {
    required String timezone,
    required bool allDay,
    required List<int> reminders,
  }) async {
    Repository.validateInterval(start, end);
    var task = repo.snapshot.task(block.taskId)!;
    if (task.seriesId.isEmpty || scope == RepeatScope.instance) {
      await repo.changeBlock(
        block,
        start,
        end,
        timezone: timezone,
        allDay: allDay,
        reminders: reminders,
      );
      return;
    }
    if (scope == RepeatScope.following) {
      await edit(
        task,
        scope,
        title: task.title,
        description: task.description,
        projectId: task.projectId,
      );
      task = repo.snapshot.task(task.id)!;
    }
    final series = (await repo.db.entity(task.seriesId))!;
    final sourceZone = tz.getLocation(block.timezone),
        targetZone = tz.getLocation(timezone);
    final shift = wall(
      tz.TZDateTime.from(start, targetZone),
    ).difference(wall(tz.TZDateTime.from(block.start, sourceZone)));
    final days = wall(
      tz.TZDateTime.from(end, targetZone),
    ).difference(wall(tz.TZDateTime.from(start, targetZone))).inDays;
    final changes = <Entity>[
      series.change({
        'anchor_timezone':
            series.data['anchor_timezone'] ?? series.data['timezone'],
        'offset_minutes':
            (series.data['offset_minutes'] as int? ?? 0) + shift.inMinutes,
        'timezone': timezone,
        'minutes': end.difference(start).inMinutes,
        'day_span': days,
        'all_day': allDay,
        'reminders': reminders,
      }),
    ];
    for (final occurrence in repo.snapshot.tasks.where(
      (t) => t.seriesId == task.seriesId,
    )) {
      final blocks = repo.snapshot.taskBlocks(occurrence.id);
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        final civil = wall(tz.TZDateTime.from(b.start, sourceZone)).add(shift);
        final next = tz.TZDateTime(
          targetZone,
          civil.year,
          civil.month,
          civil.day,
          civil.hour,
          civil.minute,
          civil.second,
        );
        final finish = i == 0
            ? (allDay
                  ? tz.TZDateTime(
                      targetZone,
                      next.year,
                      next.month,
                      next.day + days,
                    )
                  : next.add(end.difference(start)))
            : next.add(b.duration);
        changes.add(
          b.entity.change({
            'start': wireTime(next),
            'end': wireTime(finish),
            'timezone': timezone,
            'all_day': i == 0 ? allDay : b.allDay,
            'reminders': reminders,
          }),
        );
      }
    }
    await repo.commit(changes);
  }
}
