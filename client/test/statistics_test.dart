import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/data/activity.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/statistics.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('activity intensity uses fixed foreground-time thresholds', () {
    final date = DateTime.utc(2026, 10, 19);
    for (final entry in <Duration, int>{
      Duration.zero: 0,
      const Duration(seconds: 1): 1,
      const Duration(minutes: 4, seconds: 59): 1,
      const Duration(minutes: 5): 2,
      const Duration(minutes: 19, seconds: 59): 2,
      const Duration(minutes: 20): 3,
      const Duration(minutes: 59, seconds: 59): 3,
      const Duration(hours: 1): 4,
      const Duration(hours: 8): 4,
    }.entries) {
      expect(
        DailyActivity(date, entry.key).level,
        entry.value,
        reason: '${entry.key}',
      );
    }
  });

  test(
    'annual activity clips the window and future, merges overlaps and splits midnight',
    () {
      final now = DateTime.utc(2026, 10, 19, 12);
      final history = ActivityHistory.calculate(
        [
          TimeRange(
            DateTime.utc(2025, 10, 19, 23, 50),
            DateTime.utc(2025, 10, 20, 0, 10),
          ),
          TimeRange(DateTime.utc(2025, 10, 1), DateTime.utc(2025, 10, 2)),
          TimeRange(
            DateTime.utc(2026, 10, 18, 23, 30),
            DateTime.utc(2026, 10, 19, 0, 30),
          ),
          TimeRange(
            DateTime.utc(2026, 10, 19, 10),
            DateTime.utc(2026, 10, 19, 13),
          ),
          TimeRange(
            DateTime.utc(2026, 10, 19, 10, 30),
            DateTime.utc(2026, 10, 19, 11),
          ),
          TimeRange(DateTime.utc(2026, 10, 20), DateTime.utc(2026, 10, 21)),
          TimeRange(now, now),
        ],
        now,
        location: tz.UTC,
      );
      expect(history.days, hasLength(365));
      expect(history.days.first.date, DateTime.utc(2025, 10, 20));
      expect(history.days.last.date, DateTime.utc(2026, 10, 19));
      expect(history.days.first.duration, const Duration(minutes: 10));
      expect(history.days[363].duration, const Duration(minutes: 30));
      expect(history.days.last.duration, const Duration(hours: 2, minutes: 30));
      expect(history.activeDays, 3);
      expect(history.total, const Duration(hours: 3, minutes: 10));
      expect(history.currentStreak, 2);
    },
  );

  test('annual activity follows local dates, leap days and DST', () {
    final zone = tz.getLocation('Europe/Berlin');
    final from = tz.TZDateTime(zone, 2026, 10, 25);
    final until = tz.TZDateTime(zone, 2026, 10, 26);
    final history = ActivityHistory.calculate(
      [TimeRange(from, until)],
      until,
      location: zone,
    );
    expect(history.days[363].date, from);
    expect(history.days[363].duration, const Duration(hours: 25));
    expect(history.days.last.duration, Duration.zero);
    expect(history.activeDays, 1);
    expect(history.currentStreak, 1);
    final leap = ActivityHistory.calculate(
      [],
      DateTime.utc(2024, 3, 1),
      location: tz.UTC,
    );
    expect(leap.days, hasLength(365));
    expect(
      leap.days.where((day) => dayKey(day.date) == '2024-02-29'),
      hasLength(1),
    );
    expect(leap.activeDays, 0);
    expect(leap.currentStreak, 0);
    expect(leap.longestStreak, 0);
  });

  test(
    'usage streak allows today to be empty but never bridges a missed day',
    () {
      final now = DateTime.utc(2026, 10, 19, 12);
      final usage = [
        for (final day in [12, 13, 14, 17, 18])
          TimeRange(
            DateTime.utc(2026, 10, day, 10),
            DateTime.utc(2026, 10, day, 10, 1),
          ),
      ];
      final history = ActivityHistory.calculate(usage, now, location: tz.UTC);
      expect(history.currentStreak, 2);
      expect(history.longestStreak, 3);
      expect(history.activeDays, 5);
      usage.add(TimeRange(now.subtract(const Duration(minutes: 1)), now));
      expect(
        ActivityHistory.calculate(usage, now, location: tz.UTC).currentStreak,
        3,
      );
      expect(
        ActivityHistory.calculate(
          usage,
          now.add(const Duration(days: 2)),
          location: tz.UTC,
        ).currentStreak,
        0,
      );
    },
  );

  final start = DateTime.utc(2026, 10, 19);
  final end = DateTime.utc(2026, 10, 20);
  DateTime at(int hour, [int minute = 0]) =>
      DateTime.utc(2026, 10, 19, hour, minute);
  Entity block(String id, String task, DateTime from, DateTime to) =>
      TimeBlock.create(id, task, from, to, timezone: 'UTC');
  Entity session(String id, String task, DateTime from, DateTime? to) =>
      WorkSession.create(id, task, 'device', from, to);

  test(
    'daily plan retains missed blocks, fact unions overlaps and excludes discarded work/birthdays',
    () {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults('UTC'),
        Task.create('a', 'Работа', projectId: 'p').change({'status': 'done'}),
        Task.create('b', 'Личное'),
        Task.create(
          'birthday',
          'День рождения',
        ).change({'birthday_date': '1990-10-19'}),
        const Entity(
          id: 'p',
          kind: 'project',
          data: {'title': 'Проект', 'color': 0xff9cb9ff},
        ),
        block('pa', 'a', at(9), at(11)),
        block('pb', 'b', at(10), at(12)).change({'historical': true}),
        block('birthday-block', 'birthday', start, end),
        session('a1', 'a', at(9), at(10, 30)),
        session('a2', 'a', at(10), at(11)), // overlap within one task
        session('b1', 'b', at(10), at(12)), // overlap across tasks
        session('discarded', 'b', at(0), at(6)).change({'discarded': true}),
        session('birthday-session', 'birthday', at(0), at(8)),
        session('future', 'b', at(15), at(16)),
        session('deleted', 'b', at(0), at(6)).tombstone(),
      ]);
      final report = StatisticsReport.calculate(
        snapshot,
        [],
        start,
        end,
        at(12),
      );
      expect(report.planned, const Duration(hours: 4));
      expect(report.actual, const Duration(hours: 3));
      expect(report.overlap, const Duration(hours: 1));
      expect(report.plannedTasks, 2);
      expect(report.completedTasks, 1);
      expect(report.activeDays, 1);
      expect(
        report.projects.singleWhere((p) => p.title == 'Проект').actual,
        const Duration(hours: 2),
      );
      expect(report.estimates.single.actual, const Duration(hours: 2));
      expect(report.estimates.single.planned, const Duration(hours: 2));
    },
  );

  test(
    'midnight and running sessions are clipped to the requested range and now',
    () {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults('UTC'),
        Task.create('a', 'Через полночь'),
        block('p', 'a', start.subtract(const Duration(hours: 1)), at(1)),
        session('s', 'a', start.subtract(const Duration(hours: 1)), null),
      ]);
      final report = StatisticsReport.calculate(
        snapshot,
        [TimeRange(start.subtract(const Duration(minutes: 10)), at(1))],
        start,
        end,
        at(0, 30),
      );
      expect(report.planned, const Duration(hours: 1));
      expect(report.actual, const Duration(minutes: 30));
      expect(report.application, const Duration(minutes: 30));
      expect(report.applicationSessions, 0); // started outside this period
    },
  );

  test(
    'calendar days follow timezone and DST rather than fixed 24-hour steps',
    () {
      final zone = tz.getLocation('Europe/Berlin');
      final from = tz.TZDateTime(zone, 2026, 3, 29);
      final until = tz.TZDateTime(zone, 2026, 3, 30);
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults(zone.name),
        Task.create('a', 'Весь день'),
        block('p', 'a', from, until).change({'all_day': true}),
        session('s', 'a', from, until),
      ]);
      final report = StatisticsReport.calculate(
        snapshot,
        [],
        from,
        until,
        until,
      );
      expect(report.days, hasLength(1));
      expect(report.days.single.date.day, 29);
      expect(report.planned, const Duration(hours: 23));
      expect(report.actual, const Duration(hours: 23));
    },
  );

  test(
    'full-task estimate comparison includes work outside the period but never assumes missing time is zero effort',
    () {
      final snapshot = Snapshot([
        ...Repository.workspaceDefaults('UTC'),
        Task.create('a', 'Два дня').change({'status': 'done'}),
        Task.create('b', 'Без таймера').change({'status': 'done'}),
        block('a-old', 'a', start.subtract(const Duration(hours: 2)), start),
        block('a-new', 'a', at(9), at(10)),
        block('b-plan', 'b', at(11), at(12)),
        session('a-work', 'a', start.subtract(const Duration(hours: 2)), start),
        session('a-more', 'a', at(9), at(11)),
      ]);
      final report = StatisticsReport.calculate(
        snapshot,
        [],
        start,
        end,
        at(12),
      );
      expect(report.estimates.first.planned, const Duration(hours: 3));
      expect(report.estimates.first.actual, const Duration(hours: 4));
      expect(report.estimates.last.actual, Duration.zero);
      expect(report.actual, const Duration(hours: 2));
    },
  );

  test('empty period returns zero totals and no fabricated percentage', () {
    final report = StatisticsReport.calculate(
      Snapshot(Repository.workspaceDefaults('UTC')),
      [],
      start,
      end,
      end,
    );
    expect(report.plannedTasks, 0);
    expect(report.completedTasks, 0);
    expect(report.planned, Duration.zero);
    expect(report.actual, Duration.zero);
    expect(report.estimates, isEmpty);
    expect(report.projects, isEmpty);
  });

  test(
    'usage stops when idle/backgrounded, resumes in new intervals, never enters sync',
    () async {
      final db = LocalDatabase(NativeDatabase.memory());
      var now = at(9);
      final recorder = ApplicationActivity(db, clock: () => now);
      await recorder.setForeground(true);
      now = at(9, 1);
      await recorder.interact();
      now = at(9, 10);
      await recorder.flush();
      var intervals = await db.activity(start, end);
      expect(sumRanges(intervals), const Duration(minutes: 3));
      expect(intervals, hasLength(1));
      await recorder.interact();
      now = at(9, 11);
      await recorder.setForeground(false);
      now = at(12);
      await recorder.interact(); // background input is ignored
      await recorder.flush();
      intervals = await db.activity(start, end);
      expect(sumRanges(intervals), const Duration(minutes: 4));
      expect(intervals, hasLength(2));
      await recorder.setForeground(true);
      now = at(12, 1);
      await recorder.setForeground(false);
      expect(
        sumRanges(await db.activity(start, end)),
        const Duration(minutes: 5),
      );
      expect(await db.activityStarted, at(9));
      expect(await db.entities(), isEmpty);
      expect(await db.customSelect('SELECT * FROM outbox').get(), isEmpty);
      expect(recorder.error, isNull);
      recorder.dispose();
      await db.close();
    },
  );

  test('rapid foreground transitions keep usage intervals alive', () async {
    final db = LocalDatabase(NativeDatabase.memory());
    var now = at(9);
    final recorder = ApplicationActivity(db, clock: () => now);
    await recorder.setForeground(true);
    final pause = recorder.setForeground(false);
    final resume = recorder.setForeground(true);
    await pause;
    await resume;
    now = at(9, 1);
    await recorder.setForeground(false);
    expect(
      sumRanges(await db.activity(start, end)),
      const Duration(minutes: 1),
    );
    recorder.dispose();
    await db.close();
  });

  testWidgets(
    'usage keyboard observer preserves shortcuts and stops in background',
    (tester) async {
      final db = _ActivityMemory();
      var now = at(9);
      final recorder = ApplicationActivity(db, clock: () => now);
      var shortcuts = 0;
      recorder.start();
      await recorder.setForeground(true);
      await recorder.flush();
      await tester.pumpWidget(
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                shortcuts++,
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      );
      await tester.pump();
      now = at(9, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(shortcuts, 1);
      await recorder.flush();
      recorder.didChangeAppLifecycleState(AppLifecycleState.paused);
      await recorder.flush();
      now = at(12);
      await recorder.flush();
      expect(sumRanges(db.intervals.values), const Duration(minutes: 1));
      recorder.dispose();
      await db.close();
      await tester.pumpWidget(const SizedBox());
    },
  );
}

// SQLite round trips are covered above; keep the keyboard test in Flutter's
// simulated event loop so real database I/O cannot stall its fake clock.
class _ActivityMemory extends LocalDatabase {
  _ActivityMemory() : super(NativeDatabase.memory());
  final intervals = <int, TimeRange>{};
  @override
  Future<int> beginActivity(DateTime time) async {
    final id = intervals.length + 1;
    intervals[id] = TimeRange(time, time);
    return id;
  }

  @override
  Future<void> endActivity(int id, DateTime time) async {
    intervals[id] = TimeRange(intervals[id]!.start, time);
  }
}
