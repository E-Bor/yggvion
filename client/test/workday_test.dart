import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/statistics.dart';
import 'package:yggvion/domain/workday.dart';

void main() {
  setUpAll(data.initializeTimeZones);
  final monday = DateTime.utc(2026, 10, 19);
  late DateTime now;
  late Repository repo;
  setUp(() async {
    now = DateTime.utc(2026, 10, 20, 12);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize();
    await repo.updateSettings(30, [0], 'UTC');
  });
  tearDown(() => repo.close());

  test(
    'first regime change preserves existing defaults before yesterday',
    () async {
      await repo.commit([
        repo.snapshot.settings.entity.change({
          'workday_start': 420,
          'workday_end': 960,
          'workdays': [1, 2, 5],
        }),
      ]);
      await repo.updateWorkdaySettings(600, 1140, [1, 2, 3, 4, 5]);
      await repo.reload();
      final schedule = WorkdaySchedule(repo.snapshot);
      final earlier = schedule.forDate(DateTime.utc(2026, 10, 16))!;
      expect(earlier.start.hour, 7);
      expect(earlier.end.hour, 16);
      expect(schedule.forDate(DateTime.utc(2026, 10, 14)), isNull);
      for (final date in [
        DateTime.utc(2026, 10, 19),
        DateTime.utc(2026, 10, 20),
        DateTime.utc(2026, 10, 28),
      ]) {
        final day = schedule.forDate(date)!;
        expect(day.start.hour, 10);
        expect(day.end.hour, 19);
      }
      expect(schedule.history.previous.single.until, '2026-10-19');
      expect(schedule.records, isEmpty);
    },
  );

  test(
    'same-day changes replace one regime and later edits append history',
    () async {
      final original = repo.snapshot.settings.entity.encoded;
      await repo.updateWorkdaySettings(540, 1080, [5, 4, 3, 2, 1, 1]);
      expect(repo.snapshot.settings.entity.encoded, original);
      await repo.updateWorkdaySettings(480, 1020, [1, 2, 3, 4, 5]);
      await repo.updateWorkdaySettings(600, 1140, [1, 2, 3, 4, 5]);
      var history = WorkdayHistory(repo.snapshot.settings);
      expect(history.previous, hasLength(1));
      expect(history.forDate('2026-10-18').start, 540);
      expect(history.forDate('2026-10-19').start, 600);
      now = DateTime.utc(2026, 10, 22, 12);
      await repo.updateWorkdaySettings(660, 1500, [1, 2, 3, 4, 5]);
      await repo.updateSettings(45, [5], 'UTC', searchTypos: 2);
      await repo.reload();
      history = WorkdayHistory(repo.snapshot.settings);
      expect(history.previous.map((p) => p.until), [
        '2026-10-19',
        '2026-10-21',
      ]);
      expect(history.forDate('2026-10-16').start, 540);
      expect(history.forDate('2026-10-19').start, 600);
      expect(history.forDate('2026-10-20').end, 1140);
      expect(history.forDate('2026-10-21').start, 660);
      expect(history.forDate('2026-10-30').end, 1500);
    },
  );

  test(
    'earlier statistics stay intact while yesterday uses the new regime',
    () async {
      final friday = DateTime.utc(2026, 10, 16);
      final task = await repo.createTask('Work');
      await repo.saveSession(
        task.id,
        friday.add(const Duration(hours: 8)),
        friday.add(const Duration(hours: 10)),
      );
      final before = StatisticsReport.calculate(
        repo.snapshot,
        [],
        friday,
        monday,
        now,
      );
      await repo.updateWorkdaySettings(480, 1500, [1, 2, 3, 4, 5, 6, 7]);
      final after = StatisticsReport.calculate(
        repo.snapshot,
        [],
        friday,
        monday,
        now,
      );
      expect(after.workdayAvailable, before.workdayAvailable);
      expect(after.workdayActual, before.workdayActual);
      expect(after.outsideWorkday, before.outsideWorkday);
      expect(after.meanWorkdayStart, before.meanWorkdayStart);
      expect(after.meanWorkdayEnd, before.meanWorkdayEnd);
      final schedule = WorkdaySchedule(repo.snapshot);
      expect(schedule.forDate(DateTime.utc(2026, 10, 17)), isNull);
      expect(schedule.forDate(DateTime.utc(2026, 10, 18)), isNull);
      expect(
        schedule.forDate(monday)!.end.toUtc(),
        DateTime.utc(2026, 10, 20, 1),
      );
      expect(schedule.forDate(DateTime.utc(2026, 10, 24)), isNotNull);
      await repo.setWorkdayBoundary(
        friday,
        start: true,
        value: friday.add(const Duration(hours: 8)),
      );
      expect(WorkdaySchedule(repo.snapshot).forDate(friday)!.end.hour, 18);
      final corrected = StatisticsReport.calculate(
        repo.snapshot,
        [],
        friday,
        monday,
        now,
      );
      expect(corrected.workdayActual, const Duration(hours: 2));
    },
  );

  test(
    'weekday changes affect yesterday onward including disabling the workweek',
    () async {
      await repo.updateWorkdaySettings(540, 1080, []);
      final schedule = WorkdaySchedule(repo.snapshot);
      expect(schedule.forDate(DateTime.utc(2026, 10, 16)), isNotNull);
      expect(schedule.forDate(monday), isNull);
      expect(schedule.forDate(DateTime.utc(2026, 10, 21)), isNull);
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        DateTime.utc(2026, 10, 16),
        DateTime.utc(2026, 10, 22),
        now,
      );
      expect(report.workdays.map((d) => d.startMinutes), [
        540,
        null,
        null,
        null,
        null,
        null,
      ]);
      expect(report.meanWorkdayStart, 540);
    },
  );

  test(
    'effective date uses workspace civil yesterday through midnight and DST',
    () async {
      final cases = [
        (
          'Pacific/Kiritimati',
          DateTime.utc(2026, 10, 19, 10, 15),
          '2026-10-19',
        ),
        (
          'America/Los_Angeles',
          DateTime.utc(2026, 10, 20, 6, 30),
          '2026-10-18',
        ),
        ('America/New_York', DateTime.utc(2026, 3, 9, 4, 30), '2026-03-08'),
        ('America/New_York', DateTime.utc(2026, 11, 2, 5, 30), '2026-11-01'),
      ];
      for (var i = 0; i < cases.length; i++) {
        final (zone, instant, expected) = cases[i];
        now = instant;
        await repo.updateSettings(30, [0], zone);
        await repo.updateWorkdaySettings(480 + i * 5, 1020, [1, 2, 3, 4, 5]);
        expect(
          WorkdayHistory(repo.snapshot.settings).previous.last.until,
          expected,
        );
      }
    },
  );

  test(
    'moving the effective date backwards preserves the earlier regimes',
    () async {
      await repo.updateWorkdaySettings(480, 1020, [1, 2, 3, 4, 5]);
      now = DateTime.utc(2026, 10, 24, 12);
      await repo.updateWorkdaySettings(600, 1140, [1, 2, 3, 4, 5]);
      now = DateTime.utc(2026, 10, 22, 12);
      await repo.updateWorkdaySettings(660, 1200, [1, 2, 3, 4, 5]);
      final history = WorkdayHistory(repo.snapshot.settings);
      expect(history.previous.map((p) => p.until), [
        '2026-10-19',
        '2026-10-21',
      ]);
      expect(history.forDate('2026-10-16').start, 540);
      expect(history.forDate('2026-10-20').start, 480);
      expect(history.forDate('2026-10-21').start, 660);
      expect(history.forDate('2026-10-24').start, 660);
    },
  );

  test('invalid history dates ranges and ordering are rejected', () {
    Map<String, dynamic> entry(String until) => {
      'until': until,
      'start': 540,
      'end': 1080,
      'days': [1, 2, 3, 4, 5],
    };
    for (final history in [
      [entry('2026-02-30')],
      [entry('2026-10-19'), entry('2026-10-19')],
      [entry('2026-10-21'), entry('2026-10-19')],
      [
        {...entry('2026-10-19'), 'until': null},
      ],
      [
        {...entry('2026-10-19'), 'end': 539},
      ],
      [
        {
          ...entry('2026-10-19'),
          'days': [8],
        },
      ],
    ]) {
      expect(
        () => WorkdayHistory(
          AppSettings(
            repo.snapshot.settings.entity.change({'workday_history': history}),
          ),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'defaults are weekdays, settings autosave and invalid ranges leave them intact',
    () async {
      var schedule = WorkdaySchedule(repo.snapshot);
      expect(schedule.forDate(monday)!.start.hour, 9);
      expect(schedule.forDate(monday)!.end.hour, 18);
      expect(schedule.forDate(DateTime.utc(2026, 10, 24)), isNull);
      expect(schedule.records, isEmpty);
      await repo.updateWorkdaySettings(8 * 60, 17 * 60, [1, 6, 6]);
      await repo.reload();
      schedule = WorkdaySchedule(repo.snapshot);
      expect(schedule.forDate(monday)!.start.hour, 8);
      expect(schedule.forDate(DateTime.utc(2026, 10, 24))!.end.hour, 17);
      expect(repo.snapshot.settings.workdays, [1, 6]);
      for (final invalid in [
        (-1, 500, [1]),
        (600, 600, [1]),
        (600, 601, [1]),
        (600, 2041, [1]),
        (600, 900, [8]),
      ]) {
        await expectLater(
          repo.updateWorkdaySettings(invalid.$1, invalid.$2, invalid.$3),
          throwsArgumentError,
        );
      }
      expect(repo.snapshot.settings.workdayStart, 480);
    },
  );

  test(
    'moving a boundary affects one date, freezes defaults and can be reset',
    () async {
      await repo.setWorkdayBoundary(
        monday,
        start: true,
        value: monday.add(const Duration(hours: 10)),
      );
      await repo.updateWorkdaySettings(7 * 60, 16 * 60, [1, 2, 3, 4, 5]);
      var schedule = WorkdaySchedule(repo.snapshot);
      final saved = schedule.forDate(monday)!;
      expect(saved.start.hour, 10);
      expect(saved.end.hour, 18);
      expect(saved.plannedStart.hour, 9);
      expect(
        schedule.forDate(monday.add(const Duration(days: 1)))!.start.hour,
        7,
      );
      expect(repo.snapshot.tasks, isEmpty);
      expect(repo.snapshot.blocks, isEmpty);
      await expectLater(
        repo.setWorkdayBoundary(
          monday,
          start: false,
          value: monday.add(const Duration(hours: 9)),
        ),
        throwsFormatException,
      );
      await expectLater(
        repo.setWorkdayBoundary(
          monday,
          start: false,
          value: monday.add(const Duration(days: 3)),
        ),
        throwsArgumentError,
      );
      expect(WorkdaySchedule(repo.snapshot).forDate(monday)!.end.hour, 18);
      await repo.setWorkdayBoundary(monday, start: true, value: null);
      schedule = WorkdaySchedule(repo.snapshot);
      expect(schedule.records, isEmpty);
      expect(schedule.forDate(monday)!.start.hour, 7);
      await repo.setWorkdayBoundary(
        monday,
        start: true,
        value: monday.add(const Duration(hours: 8)),
      );
      expect(
        WorkdaySchedule(repo.snapshot).forDate(monday)!.record!.start!.hour,
        8,
      );
    },
  );

  test(
    'all elapsed workday boundaries count automatically, including idle days',
    () async {
      final first = DateTime.utc(2026, 10, 16);
      final end = DateTime.utc(2026, 10, 22);
      var report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        first,
        end,
        now,
      );
      expect(report.workdays.map((d) => d.startMinutes), [
        540,
        null,
        null,
        540,
        540,
        null,
      ]);
      expect(report.workdays.map((d) => d.endMinutes), [
        1080,
        null,
        null,
        1080,
        null,
        null,
      ]);
      expect(report.meanWorkdayStart, 540);
      expect(report.meanWorkdayEnd, 1080);
      expect(WorkdaySchedule(repo.snapshot).records, isEmpty);
      expect(repo.snapshot.sessions, isEmpty);

      // Correcting a past day replaces the default in the same statistics.
      await repo.setWorkdayBoundary(
        monday,
        start: true,
        value: monday.add(const Duration(hours: 10)),
      );
      await repo.setWorkdayBoundary(
        monday,
        start: false,
        value: monday.add(const Duration(hours: 17)),
      );
      report = StatisticsReport.calculate(repo.snapshot, [], first, end, now);
      expect(report.meanWorkdayStart, 560);
      expect(report.meanWorkdayEnd, 1050);
      expect(report.workdays[3].startMinutes, 600);
      expect(report.workdays[3].endMinutes, 1020);
    },
  );

  test(
    'default overnight end enters averages only when its time arrives',
    () async {
      await repo.updateWorkdaySettings(540, 1500, [1, 2, 3, 4, 5]);
      final next = DateTime.utc(2026, 10, 20);
      var report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        next,
        next.add(const Duration(minutes: 30)),
      );
      expect(report.meanWorkdayStart, 540);
      expect(report.meanWorkdayEnd, isNull);
      expect(report.workdayAvailable, const Duration(hours: 15, minutes: 30));
      report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        next,
        next.add(const Duration(hours: 1)),
      );
      expect(report.meanWorkdayEnd, 1500);
      expect(report.workdayAvailable, const Duration(hours: 16));
      expect(WorkdaySchedule(repo.snapshot).records, isEmpty);
    },
  );

  test(
    'work percentage merges timers and separates work outside the day',
    () async {
      final a = await repo.createTask('A');
      final b = await repo.createTask('B');
      await repo.saveSession(
        a.id,
        monday.add(const Duration(hours: 8)),
        monday.add(const Duration(hours: 10)),
      );
      await repo.saveSession(
        b.id,
        monday.add(const Duration(hours: 9)),
        monday.add(const Duration(hours: 12)),
      );
      var report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        monday.add(const Duration(days: 1)),
        now,
      );
      expect(report.workdayActual, const Duration(hours: 3));
      expect(report.outsideWorkday, const Duration(hours: 1));
      expect(report.workdayAvailable, const Duration(hours: 9));
      expect(report.workdayPercent, closeTo(100 / 3, .0001));
      expect(report.meanWorkdayStart, 540);
      expect(report.meanWorkdayEnd, 1080);
      await repo.setWorkdayBoundary(
        monday,
        start: true,
        value: monday.add(const Duration(hours: 10)),
      );
      await repo.setWorkdayBoundary(
        monday,
        start: false,
        value: monday.add(const Duration(hours: 16)),
      );
      report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        monday.add(const Duration(days: 1)),
        now,
      );
      expect(report.workdayActual, const Duration(hours: 2));
      expect(report.outsideWorkday, const Duration(hours: 2));
      expect(report.workdayAvailable, const Duration(hours: 6));
      expect(report.meanWorkdayStart, 600);
      expect(report.meanWorkdayEnd, 960);
    },
  );

  test('workday occupancy is clipped to the day and selected period', () async {
    final task = await repo.createTask('Work');
    await repo.saveSession(
      task.id,
      monday.add(const Duration(hours: 9)),
      monday.add(const Duration(hours: 13)),
    );
    var report = StatisticsReport.calculate(
      repo.snapshot,
      [],
      monday.add(const Duration(hours: 11)),
      monday.add(const Duration(hours: 13)),
      now,
    );
    expect(report.workdayAvailable, const Duration(hours: 2));
    expect(report.workdayActual, const Duration(hours: 2));
    expect(report.workdayPercent, 100);
    expect(report.outsideWorkday, Duration.zero);

    await repo.setWorkdayBoundary(
      monday,
      start: true,
      value: monday.add(const Duration(hours: 9)),
    );
    await repo.updateSettings(30, [0], 'Pacific/Kiritimati');
    final zone = tz.getLocation('Pacific/Kiritimati');
    report = StatisticsReport.calculate(
      repo.snapshot,
      [],
      tz.TZDateTime(zone, 2026, 10, 19),
      tz.TZDateTime(zone, 2026, 10, 21),
      now,
    );
    expect(report.workdays.first.available, const Duration(hours: 9));
    expect(report.workdays.first.worked, const Duration(hours: 4));
    expect(report.workdays.first.outside, Duration.zero);
    expect(report.workdays.last.worked, Duration.zero);
    expect(report.workdays.last.outside, Duration.zero);
  });

  test(
    'today stops at now and future boundaries never enter averages',
    () async {
      final today = DateTime.utc(2026, 10, 20);
      final task = await repo.createTask('Working');
      await repo.commit([
        WorkSession.create(
          'running',
          task.id,
          repo.deviceId,
          today.add(const Duration(hours: 10)),
          null,
        ),
      ]);
      await repo.setWorkdayBoundary(
        today,
        start: true,
        value: today.add(const Duration(hours: 10)),
      );
      await repo.setWorkdayBoundary(
        today,
        start: false,
        value: today.add(const Duration(hours: 17)),
      );
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        today,
        today.add(const Duration(days: 2)),
        now,
      );
      expect(report.workdayAvailable, const Duration(hours: 2));
      expect(report.workdayActual, const Duration(hours: 2));
      expect(report.workdayPercent, 100);
      expect(report.meanWorkdayStart, 600);
      expect(report.meanWorkdayEnd, isNull);
      expect(report.workdays.last.percent, isNull);
    },
  );

  test(
    'full workday respects DST and weekend work remains outside its bounds',
    () async {
      now = DateTime.utc(2026, 3, 1);
      await repo.updateSettings(30, [0], 'America/New_York');
      await repo.updateWorkdaySettings(0, 1440, [1, 2, 3, 4, 5, 6, 7]);
      final zone = tz.getLocation('America/New_York');
      for (final date in [
        tz.TZDateTime(zone, 2026, 3, 8),
        tz.TZDateTime(zone, 2026, 11, 1),
      ]) {
        final next = tz.TZDateTime(zone, date.year, date.month, date.day + 1);
        final report = StatisticsReport.calculate(
          repo.snapshot,
          [],
          date,
          next,
          next,
        );
        expect(report.workdayAvailable.inHours, date.month == 3 ? 23 : 25);
      }
      now = DateTime.utc(2026, 10, 18, 12);
      await repo.updateSettings(30, [0], 'UTC');
      await repo.updateWorkdaySettings(540, 1080, [1, 2, 3, 4, 5]);
      final saturday = DateTime.utc(2026, 10, 17);
      final task = await repo.createTask('Weekend');
      await repo.saveSession(
        task.id,
        saturday.add(const Duration(hours: 10)),
        saturday.add(const Duration(hours: 12)),
      );
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        saturday,
        saturday.add(const Duration(days: 1)),
        now,
      );
      expect(report.workdayAvailable, Duration.zero);
      expect(report.workdayPercent, isNull);
      expect(report.outsideWorkday, const Duration(hours: 2));
    },
  );

  test('overnight defaults and individual endings survive reload', () async {
    expect(WorkdaySchedule.endMinute(540, 60), 1500);
    expect(WorkdaySchedule.endMinute(540, 1080), 1080);
    expect(WorkdaySchedule.endMinute(540, 540), 1980);
    await repo.updateWorkdaySettings(540, 1500, [1, 2, 3, 4, 5]);
    var day = WorkdaySchedule(repo.snapshot).forDate(monday)!;
    expect(day.end.toUtc(), DateTime.utc(2026, 10, 20, 1));
    await repo.setWorkdayBoundary(
      monday,
      start: false,
      value: DateTime.utc(2026, 10, 20, 2),
    );
    await repo.reload();
    day = WorkdaySchedule(repo.snapshot).forDate(monday)!;
    expect(day.plannedEnd.toUtc(), DateTime.utc(2026, 10, 20, 1));
    expect(day.end.toUtc(), DateTime.utc(2026, 10, 20, 2));
    await expectLater(
      repo.setWorkdayBoundary(
        monday,
        start: true,
        value: DateTime.utc(2026, 10, 20),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repo.setWorkdayBoundary(
        monday,
        start: false,
        value: DateTime.utc(2026, 10, 20, 11),
      ),
      throwsFormatException,
    );
    await repo.setWorkdayBoundary(monday, start: false, value: null);
    expect(
      WorkdaySchedule(repo.snapshot).forDate(monday)!.end.toUtc(),
      DateTime.utc(2026, 10, 20, 1),
    );
  });

  test(
    'night is assigned to its starting day even at the report boundary',
    () async {
      final task = await repo.createTask('Night');
      await repo.setWorkdayBoundary(
        monday,
        start: false,
        value: DateTime.utc(2026, 10, 20, 1),
      );
      await repo.saveSession(
        task.id,
        DateTime.utc(2026, 10, 19, 23),
        DateTime.utc(2026, 10, 20, 2),
      );
      var report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        DateTime.utc(2026, 10, 20),
        now,
      );
      expect(report.actual, const Duration(hours: 1));
      expect(report.workdayActual, const Duration(hours: 2));
      expect(report.workdayAvailable, const Duration(hours: 16));
      expect(report.workdayPercent, 12.5);
      expect(report.meanWorkdayEnd, 1500);
      expect(report.outsideWorkday, Duration.zero);

      report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        DateTime.utc(2026, 10, 20),
        DateTime.utc(2026, 10, 21),
        now,
      );
      expect(report.actual, const Duration(hours: 2));
      expect(report.workdayActual, Duration.zero);
      expect(report.outsideWorkday, const Duration(hours: 1));

      report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        DateTime.utc(2026, 10, 21),
        now,
      );
      expect(report.workdayActual, const Duration(hours: 2));
      expect(report.outsideWorkday, const Duration(hours: 1));
      expect(report.workdays.last.worked, Duration.zero);
    },
  );

  test(
    'an ongoing night stops at now instead of the period midnight',
    () async {
      final task = await repo.createTask('Still working');
      await repo.setWorkdayBoundary(
        monday,
        start: false,
        value: DateTime.utc(2026, 10, 20, 1),
      );
      await repo.commit([
        WorkSession.create(
          'ongoing-night',
          task.id,
          repo.deviceId,
          DateTime.utc(2026, 10, 19, 23),
          null,
        ),
      ]);
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        DateTime.utc(2026, 10, 20),
        DateTime.utc(2026, 10, 20, 0, 30),
      );
      expect(report.workdayActual, const Duration(minutes: 90));
      expect(report.workdayAvailable, const Duration(hours: 15, minutes: 30));
      expect(report.meanWorkdayEnd, isNull);
      expect(report.workdays.single.percent, closeTo(90 / 930 * 100, .0001));
    },
  );

  test('overlapping workdays and timers count every minute once', () async {
    await repo.setWorkdayBoundary(
      monday,
      start: true,
      value: DateTime.utc(2026, 10, 19, 10),
    );
    await repo.setWorkdayBoundary(
      monday,
      start: false,
      value: DateTime.utc(2026, 10, 20, 10),
    );
    for (final title in ['A', 'B']) {
      final task = await repo.createTask(title);
      await repo.saveSession(
        task.id,
        DateTime.utc(2026, 10, 20, 9),
        DateTime.utc(2026, 10, 20, 11),
      );
    }
    final report = StatisticsReport.calculate(
      repo.snapshot,
      [],
      monday,
      DateTime.utc(2026, 10, 21),
      now,
    );
    expect(report.workdayActual, const Duration(hours: 2));
    expect(report.workdays.first.worked, const Duration(hours: 1));
    expect(report.workdays.last.worked, const Duration(hours: 1));
    expect(report.workdays.last.available, const Duration(hours: 2));
    expect(report.outsideWorkday, Duration.zero);
    expect(report.workdays.every((d) => (d.percent ?? 0) <= 100), isTrue);
  });

  test('overnight work on a weekend and DST use elapsed time', () async {
    now = DateTime.utc(2026, 3, 1);
    await repo.updateSettings(30, [0], 'America/New_York');
    await repo.updateWorkdaySettings(1320, 1680, [6]);
    final zone = tz.getLocation('America/New_York');
    for (final date in [
      tz.TZDateTime(zone, 2026, 3, 7),
      tz.TZDateTime(zone, 2026, 10, 31),
    ]) {
      final next = tz.TZDateTime(zone, date.year, date.month, date.day + 1);
      final finish = tz.TZDateTime(
        zone,
        date.year,
        date.month,
        date.day + 1,
        4,
      );
      final task = await repo.createTask('DST');
      final begin = tz.TZDateTime(zone, date.year, date.month, date.day, 22);
      await repo.commit([
        WorkSession.create(
          'night-${date.month}',
          task.id,
          repo.deviceId,
          begin,
          finish,
        ),
      ]);
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        date,
        next,
        finish,
      );
      final hours = date.month == 3 ? 5 : 7;
      expect(report.workdayAvailable.inHours, hours);
      expect(report.workdayActual.inHours, hours);
      expect(report.workdayPercent, 100);
      final sunday = StatisticsReport.calculate(
        repo.snapshot,
        [],
        next,
        tz.TZDateTime(zone, date.year, date.month, date.day + 2),
        finish,
      );
      expect(sunday.workdayActual, Duration.zero);
      expect(sunday.outsideWorkday, Duration.zero);
    }
  });

  test(
    'average ending uses next-day offset instead of averaging clock faces',
    () async {
      await repo.setWorkdayBoundary(
        monday,
        start: false,
        value: DateTime.utc(2026, 10, 19, 23),
      );
      await repo.setWorkdayBoundary(
        DateTime.utc(2026, 10, 20),
        start: false,
        value: DateTime.utc(2026, 10, 21, 1),
      );
      final report = StatisticsReport.calculate(
        repo.snapshot,
        [],
        monday,
        DateTime.utc(2026, 10, 21),
        DateTime.utc(2026, 10, 21, 12),
      );
      expect(report.meanWorkdayEnd, 1440);
      expect(report.meanWorkdayStart, 540);
      expect(report.workdays.map((d) => d.endMinutes), [1380, 1500]);
    },
  );

  test(
    'all-time range starts at oldest plan, workday or local activity',
    () async {
      final old = DateTime.utc(2024, 2, 1, 12);
      await repo.createTask(
        'Older',
        start: old,
        end: old.add(const Duration(hours: 1)),
      );
      expect(
        StatisticsReport.historyStart(repo.snapshot, now, null).toUtc(),
        DateTime.utc(2024, 2, 1),
      );
      expect(
        StatisticsReport.historyStart(
          repo.snapshot,
          now,
          DateTime.utc(2023, 5, 2, 13),
        ).toUtc(),
        DateTime.utc(2023, 5, 2),
      );
    },
  );
}
