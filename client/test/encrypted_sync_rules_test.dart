import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/sync_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  test(
    'offline timers preserve overlap and converge; cancelled instances stay deleted',
    () async {
      final now = DateTime.utc(2026, 10, 22, 12);
      final repo = Repository(
        LocalDatabase(NativeDatabase.memory()),
        clock: () => now,
      );
      addTearDown(() async {
        await repo.db.close();
        repo.dispose();
      });
      await repo.initialize();
      await repo.commit([
        Task.create('task1', 'First'),
        Task.create('task2', 'Second'),
        WorkSession.create(
          'timer1',
          'task1',
          'device1',
          now.subtract(const Duration(hours: 2)),
          null,
        ),
        WorkSession.create(
          'timer2',
          'task2',
          'device2',
          now.subtract(const Duration(hours: 1)),
          null,
        ),
        const Entity(id: 'series', kind: 'series', deleted: true, data: {}),
        Task.create(
          'instance',
          'Cancelled',
          seriesId: 'series',
          occurrence: now.toIso8601String(),
        ),
        TimeBlock.create(
          'block',
          'instance',
          now,
          now.add(const Duration(hours: 1)),
          timezone: 'UTC',
          reminders: [],
        ),
      ]);
      expect(await reconcileEncryptedRecords(repo), isTrue);
      expect((await repo.db.entity('instance'))!.deleted, isTrue);
      expect((await repo.db.entity('block'))!.deleted, isTrue);
      expect(repo.snapshot.sessions.where((s) => s.running), hasLength(1));
      final closed = repo.snapshot.sessions.singleWhere(
        (s) => s.id == 'timer1',
      );
      expect(
        closed.end,
        now,
      ); // retains the actual overlap for user reconciliation
      expect(await reconcileEncryptedRecords(repo), isFalse);
      final local = closed.entity;
      final remote = local
          .change({'end': wireTime(now.add(const Duration(seconds: 1)))})
          .withVersion(local.version + 1);
      expect(concurrentTimerClosure(local, remote), isTrue);
      expect(
        concurrentTimerClosure(local, remote.withVersion(remote.version + 1)),
        isFalse,
      );
    },
  );
}
