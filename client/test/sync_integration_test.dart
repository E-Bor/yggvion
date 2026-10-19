import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/domain/recurrence.dart';

// Run with YGGVION_TEST_SERVER pointing at the compiled Go server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final binary = Platform.environment['YGGVION_TEST_SERVER'];
  test(
    'two actual offline clients synchronize through Go and preserve note conflicts',
    () async {
      tz.initializeTimeZones();
      FlutterSecureStorage.setMockInitialValues({});
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final directory = await Directory.systemTemp.createTemp('yggvion-sync-');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      const pairingKey = 'integration-test-key-not-a-real-secret';
      final process = await Process.start(
        binary!,
        [],
        environment: {
          ...Platform.environment,
          'YGGVION_PAIRING_KEY': pairingKey,
          'YGGVION_DATA_DIR': directory.path,
          'YGGVION_LISTEN': '127.0.0.1:$port',
        },
      );
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      final a = Repository(LocalDatabase(NativeDatabase.memory())),
          b = Repository(LocalDatabase(NativeDatabase.memory()));
      await a.initialize();
      await b.initialize();
      final sa = SyncService(a), sb = SyncService(b);
      final probe = Dio();
      addTearDown(() async {
        sa.dispose();
        sb.dispose();
        a.onChange = null;
        b.onChange = null;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await a.db.close();
        await b.db.close();
        probe.close();
        process.kill();
        await process.exitCode;
        await directory.delete(recursive: true);
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      });
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
      await sa.pair(base, pairingKey, 'Desktop');
      await sb.pair(base, pairingKey, 'Phone');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      expect(b.conflictCount, 0);
      // No change callback means these edits are truly local until the explicit sync below.
      a.onChange = null;
      b.onChange = null;
      await a.updateSettings(30, [0], 'UTC', taskColor: 0xffb7a6e8);
      final task = await a.createTask(
        'From desktop',
        start: DateTime.now().add(const Duration(hours: 1)),
      );
      // Coalesced edits must send a newly assigned project before the older task.
      await a.saveProject('Work', 0xff80adee);
      await a.updateTask(task, projectId: a.snapshot.projects.single.id);
      await a.commit([
        for (var i = 0; i < 120; i++) Task.create(a.newId(), 'Offline task $i'),
      ]);
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      expect(b.snapshot.task(task.id)!.title, 'From desktop');
      expect(b.snapshot.taskBlocks(task.id), hasLength(1));
      expect(b.snapshot.tasks, hasLength(121));
      expect(b.snapshot.settings.taskColor, 0xffb7a6e8);
      expect(b.snapshot.taskColor(b.snapshot.task(task.id)!), 0xff80adee);
      expect(await a.db.customSelect('SELECT * FROM outbox').get(), isEmpty);
      await b.updateTask(
        b.snapshot.task(task.id)!,
        description: 'Edited from phone',
      );
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.snapshot.task(task.id)!.description, 'Edited from phone');
      // Explicit removal drops the calendar block on the other device, retaining the task.
      await b.unschedule(b.snapshot.taskBlocks(task.id).single);
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.snapshot.taskBlocks(task.id), isEmpty);
      expect(a.snapshot.task(task.id), isNotNull);
      final repeat = await a.createTask(
        'Recurring deletion',
        start: a.now().add(const Duration(hours: 2)),
      );
      await RecurrenceService(a).create(
        repeat,
        a.snapshot.taskBlocks(repeat.id).single,
        'FREQ=DAILY;COUNT=4',
      );
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final seriesId = a.snapshot.task(repeat.id)!.seriesId;
      final instances =
          a.snapshot.tasks.where((t) => t.seriesId == seriesId).toList()
            ..sort((x, y) => x.occurrence.compareTo(y.occurrence));
      expect(
        b.snapshot.tasks.where((t) => t.seriesId == seriesId),
        hasLength(4),
      );
      await RecurrenceService(a).delete(instances[2], RepeatScope.following);
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await RecurrenceService(
        b,
      ).expand(b.now(), b.now().add(const Duration(days: 200)));
      expect(
        b.snapshot.tasks.where((t) => t.seriesId == seriesId),
        hasLength(2),
      );
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      // Make both writes before either can observe the other; optimistic versions must preserve both.
      await a.saveNote('scratchpad', 'Быстрая заметка', 'Desktop draft');
      await b.saveNote('scratchpad', 'Быстрая заметка', 'Phone draft');
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final conflicted = a.conflictCount > 0 ? a : b;
      expect(conflicted.conflictCount, 1);
      final conflicts = await conflicted.conflicts();
      expect(conflicts.single['id'], 'scratchpad');
      await conflicted.resolveRecordConflict(
        'scratchpad',
        keepLocal: false,
        keepBoth: true,
      );
      await (conflicted == a ? sa : sb).sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sa.sync();
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final contents = a.snapshot.notes.map((n) => n.content).toList();
      expect(contents, contains('Desktop draft'));
      expect(contents, contains('Phone draft'));
      await a.deleteEntity(a.snapshot.task(task.id)!.entity);
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.snapshot.task(task.id), isNull);
      expect(b.snapshot.taskBlocks(task.id), isEmpty);
      await BirthdayService(a).save('Анна', DateTime(1990, 10, 19));
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.snapshot.birthdays.single.name, 'Анна');
      final birthday = b.snapshot.tasks.firstWhere((t) => t.isBirthday);
      expect(
        b.snapshot.taskBlocks(birthday.id).single.reminderAt,
        hasLength(1),
      );
      await b.status(birthday, TaskStatus.done);
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.snapshot.task(birthday.id)!.done, isTrue);
      await BirthdayService(a).delete(a.snapshot.birthdays.single);
      await sa.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sb.sync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.snapshot.birthdays, isEmpty);
      expect(b.snapshot.tasks.where((t) => t.isBirthday), isEmpty);
    },
    skip: binary == null
        ? 'Set YGGVION_TEST_SERVER to run against the real Go server'
        : false,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
