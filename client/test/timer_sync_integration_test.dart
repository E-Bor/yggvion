import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final binary = Platform.environment['YGGVION_TEST_SERVER'];

  test(
    'two devices pause, resume and stop tracking, retaining an offline stop time',
    () async {
      tz.initializeTimeZones();

      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      });
      final directory = await Directory.systemTemp.createTemp('yggvion-timer-');
      addTearDown(() => directory.delete(recursive: true));
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      const key = 'timer-integration-key-not-a-real-secret';
      final process = await Process.start(
        binary!,
        [],
        environment: {
          ...Platform.environment,
          'YGGVION_PAIRING_KEY': key,
          'YGGVION_DATA_DIR': directory.path,
          'YGGVION_LISTEN': '127.0.0.1:$port',
        },
      );
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      addTearDown(() async {
        process.kill();
        await process.exitCode;
      });
      final probe = Dio();
      addTearDown(probe.close);
      final base = 'http://127.0.0.1:$port';
      var ready = false;
      for (var i = 0; i < 50; i++) {
        try {
          await probe.get<Object?>('$base/health');
          ready = true;
          break;
        } on DioException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(ready, isTrue);

      var now = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      final a = Repository(
        LocalDatabase(NativeDatabase.memory()),
        clock: () => now,
      );
      final b = Repository(
        LocalDatabase(NativeDatabase.memory()),
        clock: () => now,
      );
      final sa = SyncService(a, realtime: false);
      final sb = SyncService(b, realtime: false);
      addTearDown(() async {
        sa.dispose();
        sb.dispose();
        await a.db.close();
        await b.db.close();
        a.dispose();
        b.dispose();
      });
      await a.initialize();
      await b.initialize();
      await sa.setEncryptionPassword('Integration password 42');
      await sa.pair(base, key, 'Desktop');
      await sb.pair(base, key, 'Phone');
      await sb.unlockWithPassword('Integration password 42');
      // These clients synchronize only when requested: no SSE or callbacks.
      expect(a.onChange, isNull);
      expect(b.onChange, isNull);
      final task = await a.createTask('Shared timer');
      await a.toggleCalendarTimer(task);
      final original = a.snapshot.sessions.single;
      await sa.sync();
      await sb.sync();
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      expect(b.lastCalendarTask, isNull);
      expect(b.globalTimerTask!.id, task.id);

      // The starting device does not need to be online when another stops it.
      now = now.add(const Duration(minutes: 25));
      final stoppedAt = now;
      expect(b.trackedTask?.id, task.id);
      await b.setTimerRunning(b.trackedTask!, false);
      expect(b.trackedTask?.id, task.id);
      expect(b.activeTimerTask, isNull);
      expect(b.snapshot.sessions.single.end, stoppedAt);
      expect(a.snapshot.sessions.single.running, isTrue);
      await sb.sync();
      await sa.sync();
      expect(a.snapshot.sessions.single.id, original.id);
      expect(a.snapshot.sessions.single.end, stoppedAt);
      expect(a.snapshot.sessions.single.deviceId, a.deviceId);
      expect(a.snapshot.spent(task.id, now), const Duration(minutes: 25));
      expect(b.snapshot.spent(task.id, now), const Duration(minutes: 25));

      // Resume on the phone after a break, then stop locally on the desktop.
      now = now.add(const Duration(minutes: 10));
      final resumedAt = now;
      await b.setTimerRunning(b.trackedTask!, true);
      await sb.sync();
      await sa.sync();
      final resumed = a.snapshot.sessions.singleWhere((s) => s.running);
      expect(resumed.id, isNot(original.id));
      expect(resumed.deviceId, b.deviceId);
      expect(resumed.start, resumedAt);

      now = now.add(const Duration(minutes: 15));
      final offlineStop = now;
      await a.stopTracking(a.trackedTask!);
      expect(a.trackedTask, isNull);
      now = now.add(const Duration(minutes: 20));
      // Reconnecting later must retain the time of the tap, not the sync time.
      await sa.sync();
      await sb.sync();
      await sa.sync();
      for (final repo in [a, b]) {
        expect(repo.syncError, isNull);
        expect(repo.conflictCount, 0);
        expect(repo.snapshot.sessions, hasLength(2));
        expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
        expect(
          repo.snapshot.sessions.singleWhere((s) => s.id == resumed.id).end,
          offlineStop,
        );
        expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 40));
        expect(
          await repo.db.customSelect('SELECT * FROM outbox').get(),
          isEmpty,
        );
      }

      // The phone starts a new timer and then stops receiving updates, as when
      // iOS suspends it. Switching tasks on the desktop must close the same
      // session; the old lock-screen clock must never become extra time.
      final nextTask = await a.createTask('Next task');
      await sa.sync();
      await sb.sync();
      await b.toggleCalendarTimer(b.snapshot.task(task.id)!);
      final phoneSession = b.snapshot.sessions.singleWhere((s) => s.running);
      await sb.sync();
      await sa.sync();
      now = now.add(const Duration(minutes: 12));
      final switchedAt = now;
      await a.toggleCalendarTimer(nextTask);
      await sa.sync();
      now = now.add(const Duration(minutes: 35));
      expect(b.activeTimerTask?.id, task.id); // Still the stale local snapshot.
      expect(
        b.snapshot.sessions.singleWhere((s) => s.running).id,
        phoneSession.id,
      );

      await sb.sync(); // The phone wakes and receives the desktop's closure.
      await sa.sync();
      await sb.sync();
      for (final repo in [a, b]) {
        expect(repo.syncError, isNull);
        expect(repo.conflictCount, 0);
        expect(repo.activeTimerTask?.id, nextTask.id);
        expect(repo.snapshot.sessions, hasLength(4));
        expect(repo.snapshot.sessions.where((s) => s.running), hasLength(1));
        expect(
          repo.snapshot.sessions
              .singleWhere((s) => s.id == phoneSession.id)
              .end,
          switchedAt,
        );
        expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 52));
        expect(
          repo.snapshot.spent(nextTask.id, now),
          const Duration(minutes: 35),
        );
        expect(
          await repo.db.customSelect('SELECT * FROM outbox').get(),
          isEmpty,
        );
      }
    },
    skip: binary == null
        ? 'Set YGGVION_TEST_SERVER to run against the real Go server'
        : false,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
