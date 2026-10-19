import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/reminders.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/recurrence.dart';

void main() {
  late Repository repo;
  late DateTime now;
  setUpAll(tzdata.initializeTimeZones);
  setUp(() async {
    now = DateTime.utc(2026, 2, 1, 12);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize(timezone: 'Europe/Moscow');
  });
  tearDown(() => repo.db.close());

  test(
    'birthdays retain yearly completion, calculate age and exact civil reminders',
    () async {
      final service = BirthdayService(repo);
      await service.save('Аня', DateTime(1990, 3, 31));
      final person = repo.snapshot.birthdays.single;
      final task = repo.snapshot.tasks.firstWhere(
        (t) => t.entity.data['birthday_year'] == 2026,
      );
      final block = repo.snapshot.taskBlocks(task.id).single;
      expect(task.title, 'Аня — день рождения · 36 лет');
      expect(repo.snapshot.unscheduled(task, now), isFalse);
      expect(block.allDay, isTrue);
      expect(block.reminderAt, [DateTime.utc(2026, 3, 31, 6)]);
      expect(
        remindersFor(repo.snapshot, now).where((r) => r.taskId == task.id),
        hasLength(1),
      );
      expect(
        remindersFor(
          repo.snapshot,
          now,
        ).where((r) => r.taskId == task.id).map((r) => r.body),
        ['Сегодня день рождения. Не забудьте поздравить!'],
      );
      await repo.status(task, TaskStatus.done);
      expect(
        remindersFor(repo.snapshot, now).where((r) => r.taskId == task.id),
        isEmpty,
      );
      await service.save('Анна', DateTime(1991, 4, 1), birthday: person);
      expect(repo.snapshot.task(task.id)!.done, isTrue);
      expect(
        repo.snapshot.task(task.id)!.title,
        'Анна — день рождения · 35 лет',
      );
      expect(repo.snapshot.tasks.where((t) => !t.done), hasLength(2));
      final before = repo.snapshot.entities.map((e) => e.encoded).toList();
      await RecurrenceService(
        repo,
      ).expand(now, now.add(const Duration(days: 90)));
      expect(repo.snapshot.entities.map((e) => e.encoded).toList(), before);
      now = DateTime.utc(2026, 10, 19);
      await repo.rollover();
      expect(repo.snapshot.blocks.every((b) => !b.historical), isTrue);
      await service.delete(repo.snapshot.birthdays.single);
      await service.expand(now, now.add(const Duration(days: 400)));
      expect(repo.snapshot.birthdays, isEmpty);
      expect(repo.snapshot.tasks, isEmpty);
      expect(repo.snapshot.blocks, isEmpty);
    },
  );

  test(
    'leap birthdays use February 28 in common years and preserve identity across timezone changes',
    () async {
      await BirthdayService(repo).save('Саша', DateTime(2000, 2, 29));
      final tasks = repo.snapshot.tasks;
      final common = tasks.firstWhere(
        (t) => t.entity.data['birthday_year'] == 2026,
      );
      final leap = tasks.firstWhere(
        (t) => t.entity.data['birthday_year'] == 2028,
      );
      final zone = tz.getLocation('Europe/Moscow');
      expect(
        tz.TZDateTime.from(
          repo.snapshot.taskBlocks(common.id).single.start,
          zone,
        ).day,
        28,
      );
      expect(
        tz.TZDateTime.from(
          repo.snapshot.taskBlocks(leap.id).single.start,
          zone,
        ).day,
        29,
      );
      await repo.updateSettings(30, [0], 'America/New_York');
      await BirthdayService(
        repo,
      ).expand(now, now.add(const Duration(days: 90)));
      expect(
        repo.snapshot.tasks.map((t) => t.id).toSet(),
        tasks.map((t) => t.id).toSet(),
      );
      expect(
        repo.snapshot.taskBlocks(common.id).single.reminderAt.last,
        DateTime.utc(2026, 2, 28, 14),
      );
      expect([1, 2, 5, 11, 21, 24, 111].map(ageLabel), [
        '1 год',
        '2 года',
        '5 лет',
        '11 лет',
        '21 год',
        '24 года',
        '111 лет',
      ]);
    },
  );

  test(
    'invalid birthdays never write and old records remain readable',
    () async {
      final count = repo.snapshot.entities.length;
      await expectLater(
        BirthdayService(repo).save('', DateTime(1990)),
        throwsArgumentError,
      );
      await expectLater(
        BirthdayService(repo).save('Имя', DateTime(2027)),
        throwsArgumentError,
      );
      expect(repo.snapshot.entities, hasLength(count));
      final task = await repo.createTask('Обычная задача');
      expect(task.isBirthday, isFalse);
      await repo.schedule(task, now, now.add(const Duration(hours: 1)));
      expect(repo.snapshot.blocks.single.reminderAt, isEmpty);
    },
  );

  test(
    'legacy early notices are ignored and all existing years are refreshed',
    () async {
      final service = BirthdayService(repo);
      await service.save('Аня', DateTime(1990, 3, 31));
      await service.expand(DateTime.utc(2035), DateTime.utc(2036));
      final ids = repo.snapshot.tasks.map((t) => t.id).toSet();
      await repo.commit([
        for (final block in repo.snapshot.blocks)
          block.entity.change({
            'reminder_at': [
              wireTime(
                block.reminderAt.single.subtract(const Duration(days: 31)),
              ),
              wireTime(
                block.reminderAt.single.subtract(const Duration(days: 7)),
              ),
              wireTime(block.reminderAt.single),
            ],
          }),
      ]);
      final reminders = remindersFor(repo.snapshot, now);
      expect(reminders, hasLength(ids.length));
      expect(reminders.every((r) => r.key.endsWith(':at:2')), isTrue);
      expect(reminders.every((r) => r.at.day == 31 && r.at.hour == 6), isTrue);
      await service.expand(now, now.add(const Duration(days: 90)));
      expect(repo.snapshot.tasks.map((t) => t.id).toSet(), ids);
      expect(
        repo.snapshot.blocks.every((b) => b.reminderAt.length == 1),
        isTrue,
      );
      expect(
        remindersFor(repo.snapshot, now).map((r) => r.deliveryKey).toSet(),
        reminders.map((r) => r.deliveryKey).toSet(),
      );
    },
  );

  test(
    'available planned time keeps past blocks, clips ongoing blocks and excludes future time',
    () async {
      final task = await repo.createTask('Работа');
      TimeBlock block(int start, int end) => TimeBlock(
        TimeBlock.create(
          repo.newId(),
          task.id,
          now.add(Duration(minutes: start)),
          now.add(Duration(minutes: end)),
          timezone: 'UTC',
        ),
      );
      final ranges = availablePlannedTime([
        block(-180, -120),
        block(-60, 60),
        block(30, 90),
        block(0, 60),
      ], now);
      expect(ranges.map((r) => r.duration), [
        const Duration(hours: 1),
        const Duration(hours: 1),
      ]);
      expect(ranges.last.end, now);
      expect(availablePlannedTime([block(0, 60)], now), isEmpty);
      expect(availablePlannedTime([block(-30, 0)], now).single.end, now);
      expect(availablePlannedTime([], now), isEmpty);
      await repo.saveSessionRanges(task.id, ranges);
      expect(repo.snapshot.sessions, hasLength(2));
      expect(repo.snapshot.spent(task.id, now), const Duration(hours: 2));
    },
  );

  test(
    'multiple manual ranges commit atomically, preserve gaps and reject future intervals',
    () async {
      final task = await repo.createTask('Работа');
      TimeRange range(int start, int end) => TimeRange(
        now.subtract(Duration(minutes: start)),
        now.subtract(Duration(minutes: end)),
      );
      await expectLater(
        repo.saveSessionRanges(task.id, [range(90, 60), range(10, -20)]),
        throwsArgumentError,
      );
      expect(repo.snapshot.sessions, isEmpty);
      await repo.saveSessionRanges(task.id, [range(90, 60), range(30, 10)]);
      expect(repo.snapshot.sessions, hasLength(2));
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 50));
      final old = repo.snapshot.sessions.first;
      await repo.saveSessionRanges(task.id, [
        range(120, 100),
        range(95, 80),
      ], replacing: old);
      expect(repo.snapshot.sessions.where((s) => s.discarded), hasLength(1));
      expect(repo.snapshot.sessions.where((s) => !s.discarded), hasLength(3));
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 55));
      await expectLater(
        repo.saveSessionRanges(task.id, []),
        throwsArgumentError,
      );
      await expectLater(
        repo.saveSessionRanges(task.id, [range(50, 40)], replacing: old),
        throwsStateError,
      );
      await repo.deleteEntity(task.entity);
      await expectLater(
        repo.saveSessionRanges(task.id, [range(50, 40)]),
        throwsStateError,
      );
    },
  );
}
