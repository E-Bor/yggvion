import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/encryption.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'password survives restart and can unlock a device with cleared credentials',
    () async {
      tz.initializeTimeZones();

      final directory = await Directory.systemTemp.createTemp(
        'yggvion-password-restart-',
      );
      var repo = Repository(
        LocalDatabase(NativeDatabase(File('${directory.path}/client.db'))),
      );
      final sync = SyncService(repo, realtime: false);
      SyncService? restarted;
      addTearDown(() async {
        sync.dispose();
        restarted?.dispose();
        repo.onChange = null;
        await repo.db.close();
        repo.dispose();
        await directory.delete(recursive: true);
      });
      await repo.initialize();
      const password = 'Offline remembered phrase 42';
      await sync.setEncryptionPassword(password);
      final id = sync.encryptionKeyId!;
      sync.dispose();
      await repo.db.close();
      repo.dispose();
      repo = Repository(
        LocalDatabase(NativeDatabase(File('${directory.path}/client.db'))),
      );
      await repo.initialize();
      restarted = SyncService(repo, realtime: false);
      await restarted.initialize();
      expect(restarted.connected, isFalse);
      expect(restarted.needsEncryptionKey, isFalse);
      expect((await restarted.prepareWorkspaceKey()).id, id);
      expect(await restarted.credentials.read(key: 'password_$id'), password);
      restarted.dispose();
      await restarted.credentials.delete(key: 'password_$id');
      restarted = SyncService(repo, realtime: false);
      await restarted.initialize();
      expect(restarted.needsEncryptionKey, isTrue);
      await expectLater(
        restarted.unlockWithPassword('An incorrect phrase'),
        throwsFormatException,
      );
      expect(await restarted.credentials.read(key: 'password_$id'), isNull);
      await restarted.unlockWithPassword(password);
      expect(restarted.needsEncryptionKey, isFalse);
      expect(repo.syncError, isNull);
      expect(restarted.passwordConfigured, isTrue);
      expect(await restarted.credentials.read(key: 'password_$id'), password);
    },
  );
  test(
    'old invitations and key-only workspaces are rejected without conversion',
    () async {
      tz.initializeTimeZones();

      final repo = Repository(LocalDatabase(NativeDatabase.memory()));
      final sync = SyncService(repo, realtime: false);
      addTearDown(() async {
        sync.dispose();
        await repo.db.close();
        repo.dispose();
      });
      await repo.initialize();
      final previous = WorkspaceKey(List.filled(32, 1));
      await repo.db.setMeta('workspace_key_id', previous.id);
      await repo.db.setMeta('encrypted_server_key_id', previous.id);
      await expectLater(
        sync.setEncryptionPassword('New password phrase 42'),
        throwsStateError,
      );
      expect(await repo.db.meta('workspace_key_id'), previous.id);
      expect(
        await repo.db.meta(PasswordConfig.storageKey(previous.id)),
        isNull,
      );
      final payload = {
        'url': 'https://127.0.0.1:8443',
        'code': 'unused-code',
        'ca': null,
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      };
      for (final legacy in [
        payload,
        {...payload, 'version': 1, 'key': 'old-secret'},
      ]) {
        final link =
            'yggvion://connect#${base64Url.encode(utf8.encode(jsonEncode(legacy)))}';
        await expectLater(
          sync.pairInvitation(link, 'device'),
          throwsFormatException,
        );
      }
      expect(sync.connected, isFalse);
      expect(await repo.db.meta('server_url'), isNull);
    },
  );
}
