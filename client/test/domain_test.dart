import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/reminders.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/ical.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/recurrence.dart';

void main() {
  late Repository repo;
  late DateTime now;
  setUpAll(tzdata.initializeTimeZones);
  setUp(() async {
    now = DateTime.utc(2026, 10, 19, 12);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize();
  });
  tearDown(() async {
    await repo.db.close();
  });
  test(
    'new tasks have no estimate until planned; split preserves sum',
    () async {
      final t = await repo.createTask('Статья');
      expect(repo.snapshot.unscheduled(t, now), isTrue);
      expect(repo.snapshot.estimate(t.id), Duration.zero);
      await repo.schedule(t, now, now.add(const Duration(hours: 3)));
      final b = repo.snapshot.taskBlocks(t.id).single;
      await repo.splitBlock(b, now.add(const Duration(hours: 1)));
      expect(repo.snapshot.taskBlocks(t.id), hasLength(2));
      expect(repo.snapshot.estimate(t.id), const Duration(hours: 3));
    },
  );
  test(
    'rollover keeps history and tracked time and respects future blocks',
    () async {
      final past = now.subtract(const Duration(days: 1));
      final t = await repo.createTask(
        'Задача',
        start: past,
        end: past.add(const Duration(hours: 1)),
      );
      await repo.saveSession(t.id, past, past.add(const Duration(minutes: 45)));
      await repo.rollover();
      expect(repo.snapshot.unscheduled(t, now), isTrue);
      expect(repo.snapshot.taskBlocks(t.id).single.historical, isTrue);
      expect(repo.snapshot.spent(t.id, now), const Duration(minutes: 45));
      await repo.schedule(
        t,
        now.add(const Duration(days: 1)),
        now.add(const Duration(days: 1, hours: 1)),
      );
      await repo.rollover();
      expect(repo.snapshot.unscheduled(t, now), isFalse);
    },
  );
  test(
    'review copies title description and project only, old block remains',
    () async {
      final t = await repo.createTask(
        'Письмо',
        description: '**Проверить**',
        start: now,
      );
      await repo.toggleTimer(t);
      now = now.add(const Duration(minutes: 10));
      await repo.completeForReview(repo.snapshot.task(t.id)!);
      final copy = repo.snapshot.tasks.singleWhere(
        (t) => t.parentId.isNotEmpty,
      );
      expect(copy.title, 'Проверить: Письмо');
      expect(copy.description, t.description);
      expect(copy.status, TaskStatus.todo);
      expect(repo.snapshot.taskBlocks(copy.id), isEmpty);
      expect(repo.snapshot.spent(copy.id, now), Duration.zero);
      expect(repo.snapshot.task(t.id)!.done, isTrue);
      expect(repo.snapshot.taskBlocks(t.id), hasLength(1));
      expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
    },
  );
  test(
    'one local timer; unscheduled start uses configurable duration',
    () async {
      await repo.updateSettings(45, [0], 'UTC');
      final a = await repo.createTask('A'), b = await repo.createTask('B');
      await repo.toggleTimer(a);
      expect(repo.snapshot.estimate(a.id), const Duration(minutes: 45));
      now = now.add(const Duration(minutes: 5));
      await repo.toggleTimer(b);
      expect(
        repo.snapshot.sessions.where((s) => s.running).single.taskId,
        b.id,
      );
      expect(repo.snapshot.spent(a.id, now), const Duration(minutes: 5));
    },
  );
  test('manual time rejects invalid and future intervals', () async {
    final t = await repo.createTask('A');
    await expectLater(repo.saveSession(t.id, now, now), throwsArgumentError);
    await expectLater(
      repo.saveSession(t.id, now, now.add(const Duration(minutes: 1))),
      throwsArgumentError,
    );
    await repo.saveSession(t.id, now.subtract(const Duration(hours: 1)), now);
    final s = repo.snapshot.sessions.single;
    await repo.saveSession(
      t.id,
      now.subtract(const Duration(minutes: 40)),
      now,
      session: s,
    );
    expect(repo.snapshot.spent(t.id, now), const Duration(minutes: 40));
  });
  test(
    'merge unions overlaps while retaining gaps and original records',
    () async {
      final t = await repo.createTask('A');
      DateTime at(int minutes) => DateTime.utc(2026, 10, 19, 9, minutes);
      await repo.commit([
        WorkSession.create('a', t.id, 'device-a', at(0), at(30)),
        WorkSession.create('b', t.id, 'device-b', at(20), at(45)),
        WorkSession.create('c', t.id, 'device-a', at(60), at(75)),
      ]);
      final conflict = sessionConflicts(repo.snapshot.sessions, now).single;
      await repo.resolveSessions(conflict, null);
      expect(repo.snapshot.spent(t.id, now), const Duration(hours: 1));
      expect(repo.snapshot.sessions.where((s) => s.discarded), hasLength(2));
      expect(sessionConflicts(repo.snapshot.sessions, now), isEmpty);
      expect(repo.snapshot.sessions.where((s) => !s.discarded), hasLength(2));
    },
  );
  test(
    'full text search includes Cyrillic descriptions and persistent notes',
    () async {
      final t = await repo.createTask(
        'Проект',
        description: 'документация календаря',
      );
      await repo.saveNote('scratchpad', 'Быстрая заметка', 'Временная мысль');
      expect((await repo.db.search('докум')).single.id, t.id);
      expect((await repo.db.search('Временная')).single.id, 'scratchpad');
      await repo.deleteEntity(t.entity);
      expect(await repo.db.search('докум'), isEmpty);
      expect(await repo.db.search('" OR *'), isEmpty);
    },
  );
  test('all day estimate follows civil day across DST', () async {
    final loc = tz.getLocation('Europe/Berlin');
    final start = tz.TZDateTime(loc, 2026, 3, 29),
        end = tz.TZDateTime(loc, 2026, 3, 30);
    final t = await repo.createTask(
      'День',
      start: start,
      end: end,
      allDay: true,
      timezone: loc.name,
    );
    expect(repo.snapshot.estimate(t.id), const Duration(hours: 23));
  });
  test(
    'repeat materialization is idempotent and statuses independent',
    () async {
      final t = await repo.createTask('Зарядка', start: now);
      final r = RecurrenceService(repo);
      await r.create(
        t,
        repo.snapshot.taskBlocks(t.id).single,
        'FREQ=DAILY;COUNT=3',
      );
      await r.expand(
        now.subtract(const Duration(days: 1)),
        now.add(const Duration(days: 10)),
      );
      expect(repo.snapshot.tasks, hasLength(3));
      await repo.status(repo.snapshot.task(t.id)!, TaskStatus.done);
      expect(repo.snapshot.tasks.where((t) => t.done), hasLength(1));
      await r.expand(now, now.add(const Duration(days: 10)));
      expect(repo.snapshot.tasks, hasLength(3));
    },
  );
  test(
    'ICS unfolds title, keeps exclusive all-day end and de-duplicates',
    () async {
      const text =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:example-event\r\nDTSTART;VALUE=DATE:20261019\r\nDTEND;VALUE=DATE:20261020\r\nSUMMARY:Длинное\r\n  название\r\nDESCRIPTION:Первая\\nВторая\r\nEND:VEVENT\r\nEND:VCALENDAR';
      final imported = parseCalendar(text, 'UTC');
      expect(imported.warnings, isEmpty);
      expect(imported.events.single.title, 'Длинное название');
      expect(imported.events.single.description, 'Первая\nВторая');
      expect(await importCalendar(repo, imported, ''), 1);
      expect(await importCalendar(repo, imported, ''), 0);
      expect(repo.snapshot.blocks.single.duration, const Duration(days: 1));
    },
  );
  test('completed task removes all pending reminders', () async {
    final t = await repo.createTask(
      'Напомнить',
      start: now.add(const Duration(hours: 1)),
      reminders: [0, 10, 30],
    );
    expect(remindersFor(repo.snapshot, now), hasLength(3));
    await repo.status(t, TaskStatus.done);
    expect(remindersFor(repo.snapshot, now), isEmpty);
  });
  test(
    'splitting a counted series keeps count and cancelled occurrences',
    () async {
      final t = await repo.createTask('Серия', start: now);
      final r = RecurrenceService(repo);
      await r.create(
        t,
        repo.snapshot.taskBlocks(t.id).single,
        'FREQ=DAILY;COUNT=5',
      );
      final tasks = [...repo.snapshot.tasks]
        ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
      await repo.deleteEntity(tasks[3].entity);
      await r.edit(
        tasks[1],
        RepeatScope.following,
        title: 'Новая серия',
        description: '',
        projectId: '',
      );
      await r.expand(now, now.add(const Duration(days: 20)));
      expect(repo.snapshot.tasks, hasLength(4));
      expect(
        repo.snapshot.tasks.where((t) => t.title == 'Серия'),
        hasLength(1),
      );
      expect(
        repo.snapshot.tasks.where((t) => t.title == 'Новая серия'),
        hasLength(3),
      );
    },
  );
  test('series timing edits preserve wall clock across DST', () async {
    final zone = tz.getLocation('Europe/Berlin');
    now = tz.TZDateTime(zone, 2026, 3, 28, 8);
    final t = await repo.createTask(
      'Утро',
      start: tz.TZDateTime(zone, 2026, 3, 28, 9),
      timezone: zone.name,
    );
    final r = RecurrenceService(repo);
    await r.create(
      t,
      repo.snapshot.taskBlocks(t.id).single,
      'FREQ=DAILY;COUNT=4',
    );
    final block = repo.snapshot.taskBlocks(t.id).single;
    await r.editTiming(
      block,
      RepeatScope.series,
      tz.TZDateTime(zone, 2026, 3, 28, 10),
      tz.TZDateTime(zone, 2026, 3, 28, 11),
      timezone: zone.name,
      allDay: false,
      reminders: [10],
    );
    for (final b in repo.snapshot.blocks) {
      expect(tz.TZDateTime.from(b.start, zone).hour, 10);
      expect(b.duration, const Duration(hours: 1));
      expect(b.reminders, [10]);
    }
    expect(repo.snapshot.blocks.map((b) => b.start.hour).toSet(), {8, 9});
  });
  test(
    'all-day repeating blocks end at next civil midnight across DST',
    () async {
      final zone = tz.getLocation('Europe/Berlin');
      now = tz.TZDateTime(zone, 2026, 3, 29);
      final t = await repo.createTask(
        'День',
        start: now,
        end: tz.TZDateTime(zone, 2026, 3, 30),
        allDay: true,
        timezone: zone.name,
      );
      await RecurrenceService(
        repo,
      ).create(t, repo.snapshot.taskBlocks(t.id).single, 'FREQ=DAILY;COUNT=3');
      expect(repo.snapshot.blocks, hasLength(3));
      for (final b in repo.snapshot.blocks) {
        expect(tz.TZDateTime.from(b.end, zone).hour, 0);
        final start = tz.TZDateTime.from(b.start, zone);
        expect(
          b.end.isAtSameMomentAs(
            tz.TZDateTime(zone, start.year, start.month, start.day + 1),
          ),
          isTrue,
        );
      }
    },
  );
  test(
    'moved and cancelled ICS exceptions do not reappear from master',
    () async {
      final parsed = parseCalendar('''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:daily
DTSTART:20261019T120000Z
DTEND:20261019T123000Z
SUMMARY:Обычная встреча
RRULE:FREQ=DAILY;COUNT=3
END:VEVENT
BEGIN:VEVENT
UID:daily
RECURRENCE-ID:20261020T120000Z
DTSTART:20261020T140000Z
DTEND:20261020T150000Z
SUMMARY:Перенесённая встреча
END:VEVENT
BEGIN:VEVENT
UID:daily
RECURRENCE-ID:20261021T120000Z
STATUS:CANCELLED
END:VEVENT
END:VCALENDAR''', 'UTC');
      await importCalendar(repo, parsed, '');
      await RecurrenceService(
        repo,
      ).expand(now, now.add(const Duration(days: 10)));
      expect(repo.snapshot.tasks, hasLength(2));
      expect(
        repo.snapshot.blocks.where((b) => b.start.day == 20).single.start.hour,
        14,
      );
      expect(repo.snapshot.blocks.where((b) => b.start.day == 21), isEmpty);
    },
  );
  test('rollover uses configured timezone, not host timezone', () async {
    await repo.updateSettings(30, [0], 'Europe/Moscow');
    now = DateTime.utc(2026, 10, 19, 22);
    final t = await repo.createTask(
      'Вчера',
      start: DateTime.utc(2026, 10, 19, 19),
    );
    await repo.rollover();
    expect(repo.snapshot.taskBlocks(t.id).single.historical, isTrue);
    expect(repo.snapshot.unscheduled(t, now), isTrue);
  });
  test('notification claim is shared and changes when event moves', () async {
    final original = PlannedReminder('block:10', 'task', 'Название', now);
    expect(await repo.db.claimReminder(original.deliveryKey), isTrue);
    expect(await repo.db.claimReminder(original.deliveryKey), isFalse);
    final moved = PlannedReminder(
      original.key,
      'task',
      'Название',
      now.add(const Duration(hours: 1)),
    );
    expect(await repo.db.claimReminder(moved.deliveryKey), isTrue);
    await repo.db.releaseReminder(original.deliveryKey);
    expect(await repo.db.claimReminder(original.deliveryKey), isTrue);
  });
  test('SQLite and pending operations survive reopening', () async {
    final temp = await Directory.systemTemp.createTemp('yggvion-test-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/data.sqlite');
    final first = Repository(
      LocalDatabase(NativeDatabase(file)),
      clock: () => now,
    );
    await first.initialize();
    final t = await first.createTask('Сохранено');
    await first.db.close();
    final second = Repository(
      LocalDatabase(NativeDatabase(file)),
      clock: () => now,
    );
    await second.initialize();
    expect(second.snapshot.task(t.id)!.title, 'Сохранено');
    expect(
      (await second.db.customSelect('SELECT * FROM outbox').get()).length,
      greaterThan(0),
    );
    await second.db.close();
  });
  test(
    'unschedule removes the block, keeps task and tracked time, cancels reminders',
    () async {
      final task = await repo.createTask(
        'Снять план',
        start: now.add(const Duration(hours: 1)),
      );
      await repo.saveSession(
        task.id,
        now.subtract(const Duration(minutes: 20)),
        now,
      );
      final block = repo.snapshot.taskBlocks(task.id).single;
      expect(remindersFor(repo.snapshot, now), hasLength(1));
      await repo.unschedule(block);
      expect(repo.snapshot.task(task.id), isNotNull);
      expect(repo.snapshot.taskBlocks(task.id), isEmpty);
      expect(repo.snapshot.unscheduled(task, now), isTrue);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 20));
      expect(remindersFor(repo.snapshot, now), isEmpty);
      expect((await repo.db.entity(block.id))!.deleted, isTrue);
    },
  );

  for (final scope in RepeatScope.values) {
    test(
      'delete $scope persists across expansion and removes related time and reminders',
      () async {
        final initial = await repo.createTask('Повторение', start: now);
        final recurrence = RecurrenceService(repo);
        await recurrence.create(
          initial,
          repo.snapshot.taskBlocks(initial.id).single,
          'FREQ=DAILY',
        );
        final tasks = repo.snapshot.tasks
          ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
        final selected = tasks[2];
        await repo.saveSession(
          selected.id,
          now.subtract(const Duration(minutes: 15)),
          now,
        );
        await repo.snooze(selected.id, const Duration(minutes: 20));
        await recurrence.delete(selected, scope);
        if (scope == RepeatScope.following) {
          final master = (await repo.db.entity(selected.seriesId))!;
          expect(
            Entity.fromJson(master.toJson()).data['cancelled_from'],
            selected.occurrence,
          );
        }

        await recurrence.expand(
          now.subtract(const Duration(days: 1)),
          now.add(const Duration(days: 200)),
        );
        expect(repo.snapshot.task(selected.id), isNull);
        expect(repo.snapshot.taskBlocks(selected.id), isEmpty);
        expect(
          repo.snapshot.sessions.where((s) => s.taskId == selected.id),
          isEmpty,
        );
        expect(
          repo.snapshot.entities.where(
            (e) => e.kind == 'snooze' && e.data['task_id'] == selected.id,
          ),
          isEmpty,
        );
        if (scope == RepeatScope.instance) {
          expect(repo.snapshot.task(tasks.first.id), isNotNull);
          expect(
            repo.snapshot.tasks.any(
              (t) => parseTime(
                t.occurrence,
              ).isAfter(parseTime(selected.occurrence)),
            ),
            isTrue,
          );
        } else if (scope == RepeatScope.following) {
          expect(repo.snapshot.tasks, hasLength(2));
        } else {
          expect(repo.snapshot.tasks, isEmpty);
          expect(repo.snapshot.blocks, isEmpty);
        }
      },
    );
  }

  test('unscheduled recurring occurrence is not rematerialized', () async {
    final t = await repo.createTask('Повторение', start: now);
    final recurrence = RecurrenceService(repo);
    await recurrence.create(
      t,
      repo.snapshot.taskBlocks(t.id).single,
      'FREQ=DAILY;COUNT=2',
    );
    await repo.unschedule(repo.snapshot.taskBlocks(t.id).single);
    await recurrence.expand(now, now.add(const Duration(days: 5)));
    expect(repo.snapshot.taskBlocks(t.id), isEmpty);
    expect(repo.snapshot.tasks, hasLength(2));
  });

  test(
    'custom weekly interval follows selected weekdays in application timezone',
    () async {
      await repo.updateSettings(30, [0], 'Europe/Moscow');
      final t = await repo.createTask('Через неделю', start: now);
      await RecurrenceService(repo).create(
        t,
        repo.snapshot.taskBlocks(t.id).single,
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE',
      );
      final dates = repo.snapshot.blocks.map((b) => b.start).toList()..sort();
      expect(dates.take(4).map((d) => d.day), [19, 21, 2, 4]);
      expect(dates.every((d) => d.hour == 12), isTrue);
    },
  );

  test(
    'changing recurrence keeps completed work and ends old pattern',
    () async {
      final t = await repo.createTask('Ритм', start: now);
      final recurrence = RecurrenceService(repo);
      await recurrence.create(
        t,
        repo.snapshot.taskBlocks(t.id).single,
        'FREQ=DAILY',
      );
      final tasks = repo.snapshot.tasks
        ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
      final worked = tasks[2];
      await repo.saveSession(
        worked.id,
        now.subtract(const Duration(minutes: 10)),
        now,
      );
      await recurrence.changeRuleFrom(
        tasks[1],
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU',
      );
      await recurrence.expand(now, now.add(const Duration(days: 30)));
      expect(repo.snapshot.task(t.id), isNotNull);
      expect(repo.snapshot.task(worked.id)!.seriesId, isEmpty);
      expect(repo.snapshot.spent(worked.id, now), const Duration(minutes: 10));
      final newSeries = repo.snapshot.task(tasks[1].id)!.seriesId;
      expect(
        repo.snapshot.blocks
            .where((b) => repo.snapshot.task(b.taskId)?.seriesId == newSeries)
            .every((b) => b.start.weekday == DateTime.tuesday),
        isTrue,
      );
      expect(repo.snapshot.task(tasks[3].id), isNull);
    },
  );

  test(
    'global timer remembers calendar selection and excludes other timer sources',
    () async {
      final a = await repo.createTask('Календарь'),
          b = await repo.createTask('Другая');
      await repo.toggleCalendarTimer(a);
      expect(repo.lastCalendarTask!.id, a.id);
      now = now.add(const Duration(minutes: 3));
      await repo.toggleTimer(b);
      expect(repo.lastCalendarTask!.id, a.id);
      await repo.toggleCalendarTimer(repo.lastCalendarTask!);
      expect(
        repo.snapshot.sessions.where((s) => s.running).single.taskId,
        a.id,
      );
      await repo.toggleCalendarTimer(repo.lastCalendarTask!);
      expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
      await repo.initialize();
      expect(repo.lastCalendarTask!.id, a.id);
      await repo.deleteEntity(repo.lastCalendarTask!.entity);
      expect(repo.lastCalendarTask, isNull);
    },
  );

  test(
    'home panel proportions survive restart without entering sync queue',
    () async {
      final before =
          (await repo.db.customSelect('SELECT * FROM outbox').get()).length;
      await repo.saveHomeLayout(.55, .7);
      await repo.initialize();
      expect(repo.calendarFraction, .55);
      expect(repo.scratchpadFraction, .7);
      expect(
        (await repo.db.customSelect('SELECT * FROM outbox').get()).length,
        before,
      );
    },
  );

  test(
    'home and planner views persist independently, migrating the previous choice',
    () async {
      await repo.db.customStatement(
        "DELETE FROM metadata WHERE key='planner_view'",
      );
      await repo.db.setMeta('calendar_view', 'week');
      await repo.initialize();
      expect(repo.calendarView, CalendarView.week);
      expect(repo.plannerView, CalendarView.week);
      await repo.setView(CalendarView.day);
      await repo.initialize();
      expect(repo.calendarView, CalendarView.day);
      expect(repo.plannerView, CalendarView.week);
      await repo.setView(CalendarView.threeDays, planner: true);
      await repo.initialize();
      expect(repo.calendarView, CalendarView.day);
      expect(repo.plannerView, CalendarView.threeDays);
      await repo.db.setMeta('planner_view', 'invalid');
      await repo.initialize();
      expect(repo.plannerView, CalendarView.day);
    },
  );

  test('sidebar preference survives restart and stays local', () async {
    final before =
        (await repo.db.customSelect('SELECT * FROM outbox').get()).length;
    expect(repo.sidebarCollapsed, isFalse);
    await repo.setSidebarCollapsed(true);
    await repo.initialize();
    expect(repo.sidebarCollapsed, isTrue);
    await repo.setSidebarCollapsed(false);
    await repo.initialize();
    expect(repo.sidebarCollapsed, isFalse);
    expect(
      (await repo.db.customSelect('SELECT * FROM outbox').get()).length,
      before,
    );
  });

  test('invalid intervals do not partially alter a calendar block', () async {
    final t = await repo.createTask('Интервал', start: now);
    final b = repo.snapshot.taskBlocks(t.id).single;
    await expectLater(repo.changeBlock(b, now, now), throwsArgumentError);
    expect(repo.snapshot.taskBlocks(t.id).single.end, b.end);
  });
  test(
    'subsecond start does not duplicate first occurrence; legacy identities still match',
    () async {
      final at = now.add(const Duration(milliseconds: 473));
      final task = await repo.createTask('Точное начало', start: at);
      final recurrence = RecurrenceService(repo);
      await recurrence.create(
        task,
        repo.snapshot.taskBlocks(task.id).single,
        'FREQ=DAILY;COUNT=4',
      );
      expect(repo.snapshot.tasks, hasLength(4));
      final current = repo.snapshot.task(task.id)!;
      await repo.commit([
        current.entity.change({'occurrence': wireTime(at)}),
      ]);
      await recurrence.expand(now, now.add(const Duration(days: 10)));
      expect(repo.snapshot.tasks, hasLength(4));
      await repo.deleteEntity(repo.snapshot.task(task.id)!.entity);
      await recurrence.expand(now, now.add(const Duration(days: 10)));
      expect(repo.snapshot.tasks, hasLength(3));
    },
  );
  test(
    'concurrent horizon expansion cannot bring deleted following instances back offline',
    () async {
      final task = await repo.createTask('Одновременно', start: now);
      await RecurrenceService(
        repo,
      ).create(task, repo.snapshot.taskBlocks(task.id).single, 'FREQ=DAILY');
      final instances = repo.snapshot.tasks
        ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
      await Future.wait([
        RecurrenceService(repo).expand(now, now.add(const Duration(days: 200))),
        RecurrenceService(repo).delete(instances[2], RepeatScope.following),
      ]);
      expect(repo.snapshot.tasks, hasLength(2));
      await RecurrenceService(
        repo,
      ).expand(now, now.add(const Duration(days: 250)));
      expect(repo.snapshot.tasks, hasLength(2));
    },
  );
  test(
    'accent color reuses legacy settings, roundtrips, and survives other settings edits',
    () async {
      expect(repo.snapshot.settings.accentColor, 0xff9cb9ff);
      expect(
        AppSettings(
          repo.snapshot.settings.entity.change({'task_color': null}),
        ).accentColor,
        AppSettings.defaultAccentColor,
      );
      await repo.updateSettings(30, [15], 'UTC', accentColor: 0xffb7a6e8);
      final decoded = AppSettings(
        Entity.fromJson(repo.snapshot.settings.entity.toJson()),
      );
      expect(decoded.accentColor, 0xffb7a6e8);
      expect(decoded.entity.data['task_color'], 0xffb7a6e8);
      await repo.updateSettings(45, [0], 'Europe/Moscow');
      expect(repo.snapshot.settings.accentColor, 0xffb7a6e8);
      await expectLater(
        repo.updateSettings(45, [0], 'UTC', accentColor: 0x809cb9ff),
        throwsArgumentError,
      );
      expect(repo.snapshot.settings.accentColor, 0xffb7a6e8);
    },
  );
  test('queued settings edits preserve the newly selected accent', () async {
    await Future.wait([
      repo.updateSettings(30, [15], 'UTC', accentColor: 0xff8ac9b4),
      repo.updateSettings(45, [0], 'Europe/Moscow'),
    ]);
    await repo.reload();
    expect(repo.snapshot.settings.accentColor, 0xff8ac9b4);
    expect(repo.snapshot.settings.defaultMinutes, 45);
    expect(repo.snapshot.settings.timezone, 'Europe/Moscow');
  });
}
