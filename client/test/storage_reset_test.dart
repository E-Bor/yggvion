import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/encryption.dart';
import 'package:yggvion/data/local_credentials.dart';
import 'package:yggvion/data/local_backup.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/storage_reset.dart';
import 'package:yggvion/data/sync.dart';

class _BlockedAdapter implements HttpClientAdapter {
  final requested = Completer<void>();
  final response = Completer<ResponseBody>();
  RequestOptions? request;
  bool forceClosed = false;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) {
    calls++;
    request = options;
    if (!requested.isCompleted) requested.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {
    forceClosed = forceClosed || force;
    if (request != null && !response.isCompleted) {
      response.completeError(
        DioException(requestOptions: request!, type: DioExceptionType.cancel),
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  late Directory sandbox;
  late Directory profile;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('yggvion-reset-test-');
    profile = await Directory('${sandbox.path}/profile').create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => profile.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await sandbox.delete(recursive: true);
  });

  test(
    'reset removes legacy credentials and data and allows a fresh password',
    () async {
      final repo = Repository(await LocalDatabase.open());
      final sync = SyncService(repo, realtime: false);
      await repo.initialize();
      final note = await repo.createNote();
      await repo.saveNote(note.id, 'Private title', 'Private body');
      await repo.createTask('Private task');
      await repo.db.setMeta('workspace_key_id', 'old-unsupported-key');
      await repo.db.setMeta('calendar_view', 'week');
      await repo.db.setMeta('server_url', 'https://server.example.test');
      final credentials = LocalCredentials(repo.db);
      await credentials.write(
        key: 'password_old-unsupported-key',
        value: 'old secret',
      );
      await credentials.write(key: 'server_token', value: 'test-token');
      await repo.db.beginActivity(DateTime.now());
      final originalDevice = repo.deviceId;
      await expectLater(sync.prepareWorkspaceKey(), throwsStateError);
      for (final dir in [
        'attachments',
        'backups',
        'local-ai',
        'ai-recordings',
      ]) {
        await Directory('${profile.path}/$dir').create();
        await File('${profile.path}/$dir/private.bin').writeAsString('private');
      }
      final exported = File('${sandbox.path}/exported.ygglocal');
      await exported.writeAsString('user export');
      await sync.shutdown();
      await repo.close();
      repo.dispose();
      await StorageReset.clear(profile);
      for (final name in StorageReset.ownedNames) {
        expect(
          await FileSystemEntity.type('${profile.path}/$name'),
          FileSystemEntityType.notFound,
        );
      }
      expect(await exported.readAsString(), 'user export');
      expect(
        await File('${profile.path}/${StorageReset.markerName}').exists(),
        isFalse,
      );

      final fresh = Repository(await LocalDatabase.open());
      final freshSync = SyncService(fresh, realtime: false);
      try {
        await fresh.initialize();
        expect(fresh.snapshot.tasks, isEmpty);
        expect(fresh.snapshot.note(note.id), isNull);
        expect(fresh.deviceId, isNot(originalDevice));
        expect(fresh.calendarView.name, 'day');
        expect(await fresh.db.meta('server_url'), isNull);
        expect(await fresh.db.meta('workspace_key_id'), isNull);
        expect(
          await LocalCredentials(fresh.db).read(key: 'server_token'),
          isNull,
        );
        expect(
          await fresh.db.customSelect('SELECT * FROM app_activity').get(),
          isEmpty,
        );
        expect(
          await fresh.db
              .customSelect(
                "SELECT * FROM metadata WHERE key LIKE 'credential_%'",
              )
              .get(),
          isEmpty,
        );
        await expectLater(
          freshSync.prepareWorkspaceKey(),
          throwsA(isA<PasswordRequired>()),
        );
        await freshSync.setEncryptionPassword('Fresh remembered password 42');
        expect(freshSync.passwordConfigured, isTrue);
        expect(freshSync.needsEncryptionKey, isFalse);
      } finally {
        await freshSync.shutdown();
        await fresh.close();
        fresh.dispose();
      }
    },
  );

  test('startup completes a previously confirmed interrupted reset', () async {
    final db = LocalDatabase(
      NativeDatabase(File('${profile.path}/yggvion.sqlite')),
    );
    await db.setMeta('credential_server_token', 'old token');
    await db.close();
    await Directory('${profile.path}/backups').create();
    await File(
      '${profile.path}/backups/old.ygglocal',
    ).writeAsString('old copy');
    await StorageReset.finishPending(profile);
    expect(await File('${profile.path}/backups/old.ygglocal').exists(), isTrue);
    await File(
      '${profile.path}/${StorageReset.markerName}',
    ).writeAsString('confirmed');
    // Simulate termination after removing the main file, before removing backups.
    await File('${profile.path}/yggvion.sqlite').delete();
    final fresh = await LocalDatabase.open();
    try {
      expect(await fresh.meta('credential_server_token'), isNull);
      expect(await Directory('${profile.path}/backups').exists(), isFalse);
      expect(
        await File('${profile.path}/${StorageReset.markerName}').exists(),
        isFalse,
      );
    } finally {
      await fresh.close();
    }
  });

  test(
    'reset does not follow links or erase unrelated files',
    () async {
      final outside = await Directory('${sandbox.path}/outside').create();
      final keep = File('${outside.path}/keep.txt');
      await keep.writeAsString('keep');
      await Link('${profile.path}/attachments').create(outside.path);
      await Directory('${profile.path}/backups').create();
      await Link('${profile.path}/backups/linked').create(outside.path);
      await File('${profile.path}/unrelated.txt').writeAsString('unrelated');
      await StorageReset.clear(profile);
      expect(await keep.readAsString(), 'keep');
      expect(
        await File('${profile.path}/unrelated.txt').readAsString(),
        'unrelated',
      );
      expect(await Link('${profile.path}/attachments').exists(), isFalse);
      await Link(
        '${profile.path}/${StorageReset.markerName}',
      ).create(keep.path);
      await expectLater(
        StorageReset.clear(profile),
        throwsA(isA<FileSystemException>()),
      );
      expect(await keep.readAsString(), 'keep');
      await Link('${profile.path}/${StorageReset.markerName}').delete();
      final linkedRoot = Link('${sandbox.path}/linked-root');
      await linkedRoot.create(outside.path);
      await expectLater(
        StorageReset.clear(Directory(linkedRoot.path)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await keep.readAsString(), 'keep');
    },
    skip: Platform.isWindows
        ? 'Windows symlinks need elevated privileges'
        : false,
  );

  test(
    'closing drains queued writes and rejects late imports before touching files',
    () async {
      final repo = Repository(await LocalDatabase.open());
      await repo.initialize();
      final gate = Completer<void>();
      final queued = repo.serial(() async {
        await gate.future;
        await repo.db.setMeta('queued-write', 'completed');
      });
      final closing = repo.close();
      final source = File('${sandbox.path}/source.txt');
      await source.writeAsString('must not be imported');
      await expectLater(repo.attachFile(source.path), throwsStateError);
      await expectLater(repo.createTask('late task'), throwsStateError);
      gate.complete();
      await queued;
      await closing;
      repo.dispose();
      final reopened = await LocalDatabase.open();
      try {
        expect(await reopened.meta('queued-write'), 'completed');
        expect(
          await Directory('${profile.path}/attachments').exists(),
          isFalse,
        );
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'reset stops an active sync request without deleting server data',
    () async {
      final repo = Repository(LocalDatabase(NativeDatabase.memory()));
      await repo.initialize();
      await repo.db.setMeta('server_url', 'https://server.example.test');
      await LocalCredentials(
        repo.db,
      ).write(key: 'server_token', value: 'test-token');
      final adapter = _BlockedAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final sync = SyncService(repo, client: dio, realtime: false);
      try {
        await sync.initialize();
        await adapter.requested.future;
        await sync.shutdown().timeout(const Duration(seconds: 2));
        expect(adapter.forceClosed, isTrue);
        expect(adapter.calls, 1);
        expect(adapter.request!.method, 'GET');
        expect(adapter.request!.path, endsWith('/api/v1/state'));
        expect(sync.connected, isFalse);
        await sync.sync();
        expect(adapter.calls, 1);
        expect(
          await LocalCredentials(repo.db).read(key: 'server_token'),
          'test-token',
        );
      } finally {
        await sync.shutdown();
        await repo.close();
        repo.dispose();
      }
    },
  );

  test(
    'reset waits for an in-flight backup before erasing its files',
    () async {
      final repo = Repository(await LocalDatabase.open());
      await repo.initialize();
      final sync = SyncService(repo, realtime: false);
      await sync.setEncryptionPassword('Backup reset test phrase 42');
      final backups = LocalBackupService(
        repo,
        directory: Directory('${profile.path}/backups'),
      );
      final gate = Completer<void>();
      final queued = repo.serial(() => gate.future);
      final creating = backups.create();
      var stopped = false;
      final stopping = backups.stop().then((_) => stopped = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(backups.busy, isTrue);
      expect(stopped, isFalse);
      gate.complete();
      await queued;
      await creating;
      await stopping;
      expect(stopped, isTrue);
      await sync.shutdown();
      await repo.close();
      repo.dispose();
      await StorageReset.clear(profile);
      await backups.runIfDue();
      expect(await Directory('${profile.path}/backups').exists(), isFalse);
      backups.dispose();
    },
  );
}
