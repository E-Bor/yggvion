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
    'guest proposal reaches two clients, accepts or replans and revokes access',
    () async {
      tz.initializeTimeZones();

      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      });
      final dir = await Directory.systemTemp.createTemp('yggvion-sharing-');
      addTearDown(() => dir.delete(recursive: true));
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      const key = 'calendar-sharing-test-only-pairing-key';
      final process = await Process.start(
        binary!,
        [],
        environment: {
          ...Platform.environment,
          'YGGVION_PAIRING_KEY': key,
          'YGGVION_DATA_DIR': dir.path,
          'YGGVION_LISTEN': '127.0.0.1:$port',
          // Issuance of a real public certificate is deliberately not part of this local test.
          'YGGVION_PUBLIC_URL': 'https://calendar.example.test',
        },
      );
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      addTearDown(() async {
        process.kill();
        await process.exitCode;
      });
      final guest = Dio();
      addTearDown(guest.close);
      final base = 'http://127.0.0.1:$port';
      var ready = false;
      for (var i = 0; i < 50; i++) {
        try {
          await guest.get<Object?>('$base/health');
          ready = true;
          break;
        } on DioException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(ready, isTrue);
      final a = Repository(LocalDatabase(NativeDatabase.memory()));
      final b = Repository(LocalDatabase(NativeDatabase.memory()));
      final sa = SyncService(a, realtime: false),
          sb = SyncService(b, realtime: false);
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
      final private = await a.createTask(
        'PRIVATE title',
        description: 'PRIVATE description',
      );
      final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
      final start = DateTime.utc(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        12,
      );
      await a.schedule(private, start, start.add(const Duration(hours: 1)));
      final share = await sa.createCalendarShare(7);
      final uri = Uri.parse(share['url'] as String);
      expect(uri.scheme, 'https');
      expect(uri.query, isEmpty);
      final auth = Options(
        headers: {'Authorization': 'Bearer ${uri.fragment}'},
      );
      final calendar = (await guest.get<Map<String, dynamic>>(
        '$base/public/calendar',
        options: auth,
      )).data!;
      expect(calendar.toString(), isNot(contains('PRIVATE')));
      expect(calendar['busy'], hasLength(1));
      final requested = start.add(const Duration(hours: 2));
      final payload = {
        'nonce': 'guest-submission-one',
        'title': 'Discuss plans',
        'description': 'Guest notes',
        'start': requested.toIso8601String(),
        'end': requested.add(const Duration(minutes: 45)).toIso8601String(),
      };
      await expectLater(
        guest.post<Object?>(
          '$base/public/proposals',
          options: auth,
          data: {...payload, 'description': '[file](attachment:${'f' * 64})'},
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            400,
          ),
        ),
      );
      await guest.post<Object?>(
        '$base/public/proposals',
        options: auth,
        data: payload,
      );
      await guest.post<Object?>(
        '$base/public/proposals',
        options: auth,
        data: payload,
      );
      await sa.sync();
      await sb.sync();
      final proposal = b.snapshot.tasks.singleWhere((t) => t.isProposed);
      expect(a.snapshot.tasks.where((t) => t.isProposed), hasLength(1));
      expect(b.snapshot.blocks, hasLength(1));
      await b.acceptProposal(proposal);
      await sb.sync();
      await sa.sync();
      expect(a.snapshot.task(proposal.id)!.isProposed, isFalse);
      expect(
        a.snapshot.blocks
            .where((block) => block.taskId == proposal.id)
            .single
            .start,
        requested,
      );
      final accepted = (await guest.get<Map<String, dynamic>>(
        '$base/public/calendar',
        options: auth,
      )).data!;
      expect(accepted['busy'], hasLength(2));

      final another = start.add(const Duration(days: 1));
      await guest.post<Object?>(
        '$base/public/proposals',
        options: auth,
        data: {
          ...payload,
          'nonce': 'guest-submission-two',
          'start': another.toIso8601String(),
          'end': another.add(const Duration(hours: 2)).toIso8601String(),
        },
      );
      await sa.sync();
      final toMove = a.snapshot.tasks.singleWhere((t) => t.isProposed);
      final moved = another.add(const Duration(hours: 3));
      await a.schedule(toMove, moved, moved.add(const Duration(minutes: 30)));
      await sa.sync();
      await sb.sync();
      expect(b.snapshot.task(toMove.id)!.isProposed, isFalse);
      expect(
        b.snapshot.blocks
            .where((block) => block.taskId == toMove.id)
            .single
            .start,
        moved,
      );
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      // Simulate a pending proposal accepted by an older server. It must be
      // imported as harmless text and must not poison either client's outbox.
      var injected = false;
      final legacyId = 'guest_${'d' * 64}';
      sa.client.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            if (!injected &&
                response.requestOptions.path.endsWith('/guest-proposals')) {
              injected = true;
              (response.data['records'] as List).add({
                'id': legacyId,
                'kind': 'task',
                'version': 0,
                'deleted': false,
                'data': {
                  'title': 'Legacy proposal',
                  'description': '[file](attachment:${'f' * 64})',
                  'proposal': {
                    'start': another.toIso8601String(),
                    'end': another
                        .add(const Duration(hours: 1))
                        .toIso8601String(),
                    'timezone': 'UTC',
                  },
                },
              });
            }
            handler.next(response);
          },
        ),
      );
      await sa.sync();
      await sb.sync();
      expect(a.syncError, isNull);
      expect(b.syncError, isNull);
      expect(b.snapshot.task(legacyId)!.description, contains('attachment∶'));
      expect(await a.db.customSelect('SELECT * FROM outbox').get(), isEmpty);
      await sa.request('DELETE', '/api/v1/calendar-shares/${share['id']}');
      await expectLater(
        guest.get<Object?>('$base/public/calendar', options: auth),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            404,
          ),
        ),
      );
    },
    skip: binary == null
        ? 'Set YGGVION_TEST_SERVER to test against the real Go server'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
