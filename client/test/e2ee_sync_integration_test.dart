import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/domain/workday.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final binary = Platform.environment['YGGVION_TEST_SERVER'];
  test(
    'independent devices use passwords, exchange ciphertext, retry and recover',
    () async {
      tz.initializeTimeZones();
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final dir = await Directory.systemTemp.createTemp('yggvion-e2ee-');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      const bootstrap = 'test-only-bootstrap-key-e2ee-integration';
      final process = await Process.start(
        binary!,
        [],
        environment: {
          ...Platform.environment,
          'YGGVION_PAIRING_KEY': bootstrap,
          'YGGVION_DATA_DIR': '${dir.path}/server',
          'YGGVION_LISTEN': '127.0.0.1:$port',
          'YGGVION_PUBLIC_URL': 'https://calendar.example.test',
        },
      );
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      final base = 'http://127.0.0.1:$port', probe = Dio();
      final a = Repository(LocalDatabase(NativeDatabase.memory())),
          b = Repository(LocalDatabase(NativeDatabase.memory()));

      final sa = SyncService(a, realtime: false),
          sb = SyncService(b, realtime: false);
      var devicePath = '${dir.path}/a';
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (_) async => devicePath);
      addTearDown(() async {
        sa.dispose();
        sb.dispose();
        a.onChange = null;
        b.onChange = null;
        await a.db.close();
        await b.db.close();
        a.dispose();
        b.dispose();
        probe.close();
        process.kill();
        await process.exitCode;
        await dir.delete(recursive: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathChannel, null);
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      });
      for (var i = 0; i < 100; i++) {
        try {
          await probe.get<Object?>('$base/health');
          break;
        } on DioException {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      await a.initialize();
      await b.initialize();
      const password = 'Private integration password 42';
      await sa.setEncryptionPassword(password);
      expect(
        await sa.credentials.read(key: 'password_${sa.encryptionKeyId}'),
        password,
      );
      await sa.pair(base, bootstrap, 'Mac');
      expect(a.syncError, isNull);
      a.onChange = null;
      b.onChange = null;
      await a.updateSettings(30, [0], 'UTC');
      final workday = DateTime.utc(2026, 10, 19);
      await a.setWorkdayBoundary(
        workday,
        start: true,
        value: workday.add(const Duration(hours: 10)),
      );
      final note = await a.createNote();
      final file = File('${dir.path}/private-file.txt');
      await file.writeAsString('PRIVATE_FILE_CONTENT');
      final link = await a.attachFile(file.path);
      await a.saveNote(
        note.id,
        'PRIVATE_NOTE_TITLE',
        'PRIVATE_NOTE_BODY\n$link',
      );
      await sa.sync();
      expect(a.syncError, isNull);
      final wire = await sa.request('GET', '/api/v1/changes');
      expect(jsonEncode(wire), isNot(contains('PRIVATE_')));
      expect(jsonEncode(wire), isNot(contains(note.id)));
      final records = (wire['records'] as List).cast<Map>();
      expect(records.every((r) => (r['data'] as Map)['e2ee'] == 1), isTrue);
      final fileIds = records
          .expand((r) => ((r['data'] as Map)['files'] as List))
          .toSet();
      expect(fileIds, hasLength(1));
      final bytes = (await sa.client.get<List<int>>(
        '$base/api/v1/attachments/${fileIds.single}',
        options: Options(
          headers: sa.authHeaders,
          responseType: ResponseType.bytes,
        ),
      )).data!;
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('PRIVATE_FILE_CONTENT')),
      );
      await sb.pair(base, bootstrap, 'No key');
      expect(b.syncError, contains('Введите пароль'));
      expect(await b.db.customSelect('SELECT * FROM outbox').get(), isNotEmpty);
      final invite = await sa.createInvitation();
      final invitation =
          jsonDecode(utf8.decode(base64Url.decode(Uri.parse(invite).fragment)))
              as Map;
      expect(invitation.containsKey('wrapping_key'), isFalse);
      expect(invitation.values, isNot(contains(password)));
      devicePath = '${dir.path}/b';
      await sb.disconnect();
      await sb.pairInvitation(invite, 'Phone');
      expect(b.syncError, contains('Введите пароль'));
      await expectLater(
        sb.unlockWithPassword('Wrong test password'),
        throwsFormatException,
      );
      expect(b.snapshot.note(note.id), isNull);
      await sb.unlockWithPassword(password);
      expect(b.syncError, isNull);
      expect(b.snapshot.note(note.id)!.title, 'PRIVATE_NOTE_TITLE');
      expect(
        WorkdaySchedule(
          b.snapshot,
        ).forDate(workday)!.record!.start!.toUtc().hour,
        10,
      );
      await b.setWorkdayBoundary(
        workday,
        start: false,
        value: workday.add(const Duration(hours: 25)),
      );
      await sb.sync();
      await sa.sync();
      expect(a.syncError, isNull);
      expect(
        WorkdaySchedule(a.snapshot).forDate(workday)!.record!.end!.toUtc(),
        DateTime.utc(2026, 10, 20, 1),
      );
      final files = await b.db.customSelect('SELECT * FROM files').get();
      expect(
        await File(files.single.read<String>('path')).readAsString(),
        'PRIVATE_FILE_CONTENT',
      );
      expect(
        await sb.credentials.read(key: 'password_${sb.encryptionKeyId}'),
        password,
      );
      await expectLater(sb.pairInvitation(invite, 'replay'), throwsStateError);
      // Lose one successful mutation response. The retry must reuse the exact
      // ciphertext so the server's operation fingerprint remains idempotent.
      await b.saveNoteContent(note.id, 'OFFLINE_EDIT\n$link');
      var dropped = false;
      final interceptor = InterceptorsWrapper(
        onResponse: (response, handler) {
          if (!dropped && response.requestOptions.path.endsWith('/sync')) {
            dropped = true;
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            handler.next(response);
          }
        },
      );
      sb.client.interceptors.add(interceptor);
      await sb.sync();
      expect(b.syncError, isNotNull);
      sb.client.interceptors.remove(interceptor);
      await sb.sync();
      expect(b.syncError, isNull);
      await sa.sync();
      expect(a.syncError, isNull);
      expect(a.snapshot.note(note.id)!.content, 'OFFLINE_EDIT\n$link');
      // B stays offline while the same note changes repeatedly on A. Only the
      // latest version remains on the server; B must catch up from its old cursor.
      final compactedNote = await a.createNote();
      await a.saveNote(compactedNote.id, 'Compacted note', 'v1');
      await sa.sync();
      await sb.sync();
      for (final text in ['v2', 'v3', 'v4']) {
        await a.saveNoteContent(compactedNote.id, text);
        await sa.sync();
        expect(a.syncError, isNull);
      }
      await b.saveNoteContent(note.id, 'OFFLINE_EDIT\n$link');
      await sb.sync();
      expect(b.syncError, isNull);
      expect(b.snapshot.note(compactedNote.id)!.content, 'v4');
      await a.deleteEntity((await a.db.entity(compactedNote.id))!);
      await sa.sync();
      await sb.sync();
      expect(b.snapshot.note(compactedNote.id), isNull);
      expect(b.syncError, isNull);
      // A lost rotation response is recovered from remembered credentials.
      // Another device retains edits made offline and uses the new password.
      const nextPassword = 'Changed private password 43';
      final timerTask = await a.createTask('Timer during password change');
      await a.toggleCalendarTimer(timerTask);
      final runningSessionId = a.snapshot.sessions.single.id;
      await sa.sync();
      await sb.sync();
      final offlineNote = await a.createNote();
      await a.saveNote(offlineNote.id, 'Offline during rekey', 'Unsynced text');
      final beforeRotation = await sa.request('GET', '/api/v1/changes');
      var lostRotation = false;
      final rotationObserver = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.data is Map) {
            expect(jsonEncode(options.data), isNot(contains(nextPassword)));
            expect(jsonEncode(options.data), isNot(contains(password)));
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          if (!lostRotation &&
              response.requestOptions.path.endsWith('/encryption/password')) {
            lostRotation = true;
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            handler.next(response);
          }
        },
      );
      sb.client.interceptors.add(rotationObserver);
      await expectLater(
        sb.setEncryptionPassword(nextPassword, currentPassword: password),
        throwsA(
          isA<DioException>().having(
            (e) =>
                '${e.requestOptions.path}: ${e.response?.statusCode} ${e.response?.data}',
            'lost response on password endpoint',
            endsWith('/encryption/password: null null'),
          ),
        ),
      );
      expect(lostRotation, isTrue);
      sb.client.interceptors.remove(rotationObserver);
      await sb.sync();
      expect(b.syncError, isNull);
      await sa.sync();
      expect(a.syncError, contains('Введите пароль'));
      expect(a.snapshot.note(offlineNote.id)!.content, 'Unsynced text');
      final state = await sb.request('GET', '/api/v1/state');
      expect((state['password_config'] as Map)['v'], 2);
      expect(
        jsonEncode(await sb.request('GET', '/api/v1/changes')),
        isNot(jsonEncode(beforeRotation)),
      );
      await expectLater(sa.unlockWithPassword(password), throwsFormatException);
      await sa.unlockWithPassword(nextPassword);
      expect(a.syncError, isNull);
      expect(a.snapshot.note(offlineNote.id)!.content, 'Unsynced text');
      expect(await a.db.customSelect('SELECT * FROM conflicts').get(), isEmpty);
      await sb.sync();
      expect(b.snapshot.note(offlineNote.id)!.content, 'Unsynced text');
      for (final repository in [a, b]) {
        expect(repository.snapshot.sessions.single.id, runningSessionId);
        expect(repository.snapshot.sessions.single.running, isTrue);
      }
      await expectLater(
        sa.setEncryptionPassword(
          'Another password for testing',
          currentPassword: password,
        ),
        throwsFormatException,
      );

      final c = Repository(LocalDatabase(NativeDatabase.memory()));
      final sc = SyncService(c, realtime: false);
      try {
        await c.initialize();
        await sc.pairInvitation(await sa.createInvitation(), 'Fresh device');
        expect(c.syncError, contains('Введите пароль'));
        await expectLater(
          sc.unlockWithPassword(password),
          throwsFormatException,
        );
        await sc.unlockWithPassword(nextPassword);
        expect(c.syncError, isNull);
        expect(c.snapshot.note(note.id)!.content, 'OFFLINE_EDIT\n$link');
        final downloaded = await c.db.customSelect('SELECT * FROM files').get();
        expect(
          await File(downloaded.single.read<String>('path')).readAsString(),
          'PRIVATE_FILE_CONTENT',
        );
        expect(c.snapshot.sessions.single.running, isTrue);
      } finally {
        sc.dispose();
        c.onChange = null;
        await c.db.close();
        c.dispose();
      }
      // Ciphertext/base64 expands records; a large queue must be split below
      // the server's 8 MiB HTTP limit instead of blocking sync indefinitely.
      for (var i = 0; i < 8; i++) {
        final large = await a.createNote();
        await a.saveNote(large.id, 'BATCH_$i', 'content ' * 115000);
      }
      var batches = 0;
      final batchObserver = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/sync')) {
            batches++;
            expect(
              utf8.encode(jsonEncode(options.data)).length,
              lessThan(8 * 1024 * 1024),
            );
          }
          handler.next(options);
        },
      );
      sa.client.interceptors.add(batchObserver);
      await sa.sync();
      sa.client.interceptors.remove(batchObserver);
      expect(a.syncError, isNull);
      expect(batches, greaterThanOrEqualTo(2));
      expect(await a.db.customSelect('SELECT * FROM outbox').get(), isEmpty);

      // Sharing publishes just availability. A guest proposal remains in its
      // separate plaintext inbox until a device adopts/encrypts it.
      final now = DateTime.now().toUtc();
      final start = DateTime.utc(now.year, now.month, now.day + 1, 12);
      final end = start.add(const Duration(hours: 1));
      final privateTask = await a.createTask(
        'PRIVATE_APPOINTMENT',
        start: start,
        end: end,
      );
      final share = await sa.createCalendarShare(7);
      final guestAuth = Options(
        headers: {
          'Authorization':
              'Bearer ${Uri.parse(share['url'] as String).fragment}',
        },
      );
      final publicView = (await probe.get<Map<String, dynamic>>(
        '$base/public/calendar',
        options: guestAuth,
      )).data!;
      expect(jsonEncode(publicView), isNot(contains('PRIVATE_')));
      expect(jsonEncode(publicView), isNot(contains(privateTask.id)));
      expect(publicView['busy'], hasLength(2));
      final proposedStart = end.add(const Duration(hours: 1));
      final proposedEnd = proposedStart.add(const Duration(minutes: 30));
      await probe.post<Object?>(
        '$base/public/proposals',
        options: guestAuth,
        data: {
          'nonce': 'test-guest-proposal',
          'title': 'GUEST_TITLE',
          'description': 'Guest description',
          'start': proposedStart.toIso8601String(),
          'end': proposedEnd.toIso8601String(),
        },
      );
      expect(
        (await sa.request('GET', '/api/v1/guest-proposals'))['records'],
        hasLength(1),
      );
      await sa.sync();
      expect(a.syncError, isNull);
      final proposed = a.snapshot.tasks.singleWhere(
        (t) => t.title == 'GUEST_TITLE',
      );
      expect(proposed.isProposed, isTrue);
      expect(
        (await sa.request('GET', '/api/v1/guest-proposals'))['records'],
        isEmpty,
      );
      expect(
        jsonEncode(await sa.request('GET', '/api/v1/changes')),
        isNot(contains('GUEST_TITLE')),
      );
      await a.schedule(
        proposed,
        proposedStart,
        proposedEnd,
        acceptProposedTime: true,
      );
      await sa.sync();
      expect(a.syncError, isNull);
      expect(
        (await probe.get<Map<String, dynamic>>(
          '$base/public/calendar',
          options: guestAuth,
        )).data!['busy'],
        hasLength(3),
      );
      await sb.sync();
      expect(b.syncError, isNull);
      expect(b.snapshot.task(proposed.id)!.isProposed, isFalse);

      // A compromised relay cannot ask an already pinned client to downgrade.
      final downgrade = InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.requestOptions.path.endsWith('/state')) {
            (response.data as Map)['encryption_key_id'] = '';
          }
          handler.next(response);
        },
      );
      sa.client.interceptors.add(downgrade);
      await sa.sync();
      expect(a.syncError, contains('потерял настройки шифрования'));
      sa.client.interceptors.remove(downgrade);
    },
    skip: binary == null ? 'Set YGGVION_TEST_SERVER for real E2EE sync' : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
