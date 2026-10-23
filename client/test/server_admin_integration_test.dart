import 'dart:convert';
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
    'private TLS, single-use invitation, backup restore and stale offline queue recovery',
    () async {
      tz.initializeTimeZones();

      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final dir = await Directory.systemTemp.createTemp('yggvion-admin-');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final bootstrap = await Process.run(binary!, [
        'bootstrap',
        '--data-dir',
        dir.path,
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
      ]);
      expect(bootstrap.exitCode, 0, reason: '${bootstrap.stderr}');
      final identity =
          jsonDecode('${bootstrap.stdout}') as Map<String, dynamic>;
      final process = await Process.start(
        binary,
        [],
        environment: {...Platform.environment, 'YGGVION_DATA_DIR': dir.path},
      );
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      final a = Repository(LocalDatabase(NativeDatabase.memory())),
          b = Repository(LocalDatabase(NativeDatabase.memory())),
          c = Repository(LocalDatabase(NativeDatabase.memory()));
      await a.initialize();
      await b.initialize();
      await c.initialize();
      final sa = SyncService(a, realtime: false),
          sb = SyncService(b, realtime: false),
          sc = SyncService(c, realtime: false);
      addTearDown(() async {
        sa.dispose();
        sb.dispose();
        sc.dispose();
        await a.db.close();
        await b.db.close();
        await c.db.close();
        a.dispose();
        b.dispose();
        c.dispose();
        process.kill();
        await process.exitCode;
        await dir.delete(recursive: true);
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      });
      for (var i = 0; i < 50; i++) {
        try {
          final connection = await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(milliseconds: 100),
          );
          connection.destroy();
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final url = 'https://127.0.0.1:$port';
      // System trust alone must reject the private CA.
      final untrusted = Dio();
      await expectLater(
        untrusted.get<Object?>('$url/health'),
        throwsA(isA<DioException>()),
      );
      untrusted.close();
      await sa.setEncryptionPassword('Integration password 42');
      await sa.pair(
        url,
        identity['code'] as String,
        'Mac',
        privateCA: identity['private_ca'] as String,
      );
      expect(a.syncError, isNull);
      // The empty workspace backup already carries its password parameters.
      final emptyBackup = await Process.run(
        binary,
        ['backup'],
        environment: {...Platform.environment, 'YGGVION_DATA_DIR': dir.path},
      );
      expect(emptyBackup.exitCode, 0, reason: '${emptyBackup.stderr}');
      final invite = await sa.createInvitation();
      await sb.pairInvitation(invite, 'iPhone');
      await sb.unlockWithPassword('Integration password 42');
      expect(b.syncError, isNull);
      await expectLater(sb.pairInvitation(invite, 'replay'), throwsStateError);
      final task = await a.createTask('Before backup');
      await a.toggleTimer(task);
      final oldSessionId = a.snapshot.sessions.single.id;
      await sa.sync();
      await sb.sync();
      await sa.request('POST', '/api/v1/backups');
      Future<Map<String, dynamic>> waitJob() async {
        for (var i = 0; i < 100; i++) {
          final result = await sa.request('GET', '/api/v1/backups');
          if ((result['status'] as Map)['running'] != true) {
            expect((result['status'] as Map)['error'], isNull);
            return result;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        throw StateError('job timed out');
      }

      final backups = await waitJob();
      final entries = (backups['backups'] as List).cast<Map>();
      final id = entries.singleWhere((e) => e['reason'] == 'manual')['id'];
      final download = await sa.client.get<List<int>>(
        '$url/api/v1/backups/$id/download',
        options: Options(
          headers: sa.authHeaders,
          responseType: ResponseType.bytes,
        ),
      );
      final archive = download.data!;
      // The outer archive is readable gzip/tar. Private records remain E2EE.
      final contents = utf8.decode(gzip.decode(archive), allowMalformed: true);
      expect(contents, contains('snapshot.json'));
      expect(contents, contains('snapshot.sha256'));
      expect(contents, isNot(contains('Before backup')));
      expect(contents, isNot(contains('Integration password 42')));
      expect(await File('${dir.path}/backups/recovery.key').exists(), isFalse);
      await sa.client.post<Object?>(
        '$url/api/v1/backups/import',
        data: Stream<List<int>>.value(archive),
        options: Options(
          headers: {
            ...sa.authHeaders,
            'Content-Type': 'application/octet-stream',
            'Content-Length': archive.length,
          },
        ),
      );
      final imported = await waitJob();
      final importedId = (imported['backups'] as List).cast<Map>().singleWhere(
        (e) => e['reason'] == 'import',
      )['id'];
      final emptyId = entries.singleWhere(
        (e) => e['reason'] == 'before_update',
      )['id'];
      await a.updateTask(a.snapshot.task(task.id)!, title: 'After backup');
      await sa.sync();
      // No SSE or onChange callbacks: the second device really remains offline.
      await b.updateTask(
        b.snapshot.task(task.id)!,
        title: 'Offline edit that must not overwrite restore',
      );
      await sa.request(
        'POST',
        '/api/v1/backups/$importedId/restore',
        data: {'confirm': 'restore'},
      );
      await waitJob();
      final restoredState = await sa.request('GET', '/api/v1/state');
      expect(restoredState['snapshot_cursor'], greaterThan(0));
      // A newly connected device also closes a timer from the archive, even
      // without a previously stored generation. Later live timers must survive.
      await sc.pairInvitation(await sa.createInvitation(), 'Fresh device');
      await sc.unlockWithPassword('Integration password 42');
      expect(c.syncError, isNull);
      expect(
        c.snapshot.sessions.singleWhere((s) => s.id == oldSessionId).end,
        DateTime.parse(restoredState['snapshot_created'] as String),
      );
      final liveTask = await c.createTask('Started after restore');
      await c.toggleTimer(liveTask);
      await sc.sync();
      expect(c.syncError, isNull);
      final liveSessionId = c.snapshot.sessions
          .singleWhere((s) => s.running)
          .id;
      var interruptDownload = true;
      final interruption = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/api/v1/changes') && interruptDownload) {
            interruptDownload = false;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: const SocketException('Interrupted snapshot download'),
              ),
            );
          } else {
            handler.next(options);
          }
        },
      );
      sb.client.interceptors.add(interruption);
      await sb.sync();
      expect(b.syncError, isNotNull);
      expect(
        b.snapshot.task(task.id)!.title,
        'Offline edit that must not overwrite restore',
      );
      expect(await b.db.customSelect('SELECT * FROM outbox').get(), isNotEmpty);
      expect(
        await b.db.customSelect('SELECT * FROM recovery_snapshots').get(),
        isEmpty,
      );
      sb.client.interceptors.remove(interruption);
      await sb.sync();
      expect(b.syncError, isNull);
      expect(b.snapshot.task(task.id)!.title, 'Before backup');
      expect(
        b.snapshot.sessions.singleWhere((s) => s.id == liveSessionId).running,
        isTrue,
      );
      final quarantine = await b.db
          .customSelect('SELECT payload FROM recovery_snapshots')
          .get();
      expect(quarantine, hasLength(1));
      expect(
        quarantine.single.read<String>('payload'),
        contains('Offline edit that must not overwrite restore'),
      );
      expect(await b.db.customSelect('SELECT * FROM outbox').get(), isEmpty);
      await sa.sync();
      expect(a.snapshot.task(task.id)!.title, 'Before backup');
      final devices = await sa.devices();
      expect(devices, hasLength(3));
      await sa.request(
        'POST',
        '/api/v1/backups/$emptyId/restore',
        data: {'confirm': 'restore'},
      );
      await waitJob();
      await sb.sync();
      await sa.sync();
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      expect(a.snapshot.tasks, isEmpty);
      expect(b.snapshot.tasks, isEmpty);
      expect(a.snapshot.notes.where((n) => n.pinned.isNotEmpty), hasLength(2));
      expect(b.snapshot.settings.defaultMinutes, 30);
      expect(await sa.devices(), hasLength(3));
    },
    skip: binary == null
        ? 'Set YGGVION_TEST_SERVER to run real TLS/restore integration'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
