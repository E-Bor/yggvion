import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  late Repository repo;
  late DateTime now;
  setUpAll(tz.initializeTimeZones);
  setUp(() async {
    now = DateTime.utc(2026, 10, 23, 12);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize();
  });
  tearDown(() async {
    await repo.db.close();
    repo.dispose();
  });

  test(
    'pause survives reopening, excludes the gap and stop keeps the fact',
    () async {
      final task = await repo.createTask('Подготовить встречу');
      await repo.toggleCalendarTimer(task);
      expect(repo.trackedTask?.id, task.id);
      now = now.add(const Duration(minutes: 10));
      await repo.setTimerRunning(task, false);
      final firstEnd = repo.snapshot.sessions.single.end;
      now = now.add(const Duration(minutes: 20));
      await repo.setTimerRunning(task, false);
      expect(repo.snapshot.sessions.single.end, firstEnd);
      await repo.initialize();
      expect(repo.trackedTask?.id, task.id);
      expect(repo.activeTimerTask, isNull);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 10));
      await repo.setTimerRunning(task, true);
      now = now.add(const Duration(minutes: 25));
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 35));
      expect(repo.snapshot.estimate(task.id), const Duration(minutes: 30));
      await repo.stopTracking(task);
      expect(repo.trackedTask, isNull);
      expect(repo.snapshot.task(task.id)!.status, TaskStatus.inProgress);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 35));
      await repo.initialize();
      expect(repo.trackedTask, isNull);
      expect(repo.lastCalendarTask?.id, task.id);
    },
  );

  test(
    'explicit actions are idempotent and stale stop leaves the new task running',
    () async {
      final a = await repo.createTask('Первая'),
          b = await repo.createTask('Вторая');
      await Future.wait(List.generate(3, (_) => repo.setTimerRunning(a, true)));
      expect(repo.snapshot.sessions, hasLength(1));
      now = now.add(const Duration(minutes: 5));
      await repo.setTimerRunning(b, true);
      await repo.setTimerRunning(a, false);
      await repo.stopTracking(a);
      expect(repo.activeTimerTask?.id, b.id);
      expect(repo.trackedTask?.id, b.id);
      expect(repo.snapshot.spent(a.id, now), const Duration(minutes: 5));
      await repo.status(repo.snapshot.task(b.id)!, TaskStatus.done);
      expect(repo.trackedTask, isNull);
      await expectLater(repo.setTimerRunning(b, true), throwsStateError);
      expect(repo.activeTimerTask, isNull);
      await repo.setTimerRunning(a, true);
      await repo.setTimerRunning(a, false);
      await repo.deleteEntity(repo.snapshot.task(a.id)!.entity);
      expect(repo.trackedTask, isNull);
      await expectLater(repo.setTimerRunning(a, true), throwsStateError);
    },
  );

  test(
    'incoming tracking can be paused locally without counting overlapping time twice',
    () async {
      final task = await repo.createTask('Совместный таймер');
      final start = now.subtract(const Duration(minutes: 20));
      await repo.db.put(
        WorkSession.create('remote', task.id, 'other-device', start, null),
      );
      await repo.db.put(
        WorkSession.create(
          'overlap',
          task.id,
          repo.deviceId,
          start.add(const Duration(minutes: 10)),
          now,
        ),
      );
      await repo.reload();
      expect(repo.trackedTask?.id, task.id);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 20));
      await repo.setTimerRunning(task, false);
      final incoming = repo.snapshot.sessions.singleWhere(
        (s) => s.id == 'remote',
      );
      expect(incoming.end, now);
      expect(incoming.deviceId, 'other-device');
      expect(repo.trackedTask?.id, task.id);
      expect(repo.activeTimerTask, isNull);
    },
  );
}
