import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/attachments.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  late Directory dir;
  late Repository repo;
  late SyncService sync;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yggvion-attachment-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    repo = Repository(
      LocalDatabase(NativeDatabase.memory()),
      clock: () => DateTime.utc(2026, 10, 26, 12),
    );
    await repo.initialize();
    sync = SyncService(repo, realtime: false);
    repo.onChange = null;
  });
  tearDown(() async {
    sync.dispose();
    await repo.db.close();
    repo.dispose();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'catalog counts note and event references and only removes unused files',
    () async {
      final source = File('${dir.path}/config.txt');
      await source.writeAsString('important configuration');
      final link = await repo.attachFile(source.path);
      final note = await repo.createNote();
      await repo.saveNote(note.id, '', link);
      final task = await repo.createTask('Событие', description: link);
      var entry = (await repo.attachmentInventory()).single;
      expect(entry.name, 'config.txt');
      expect(entry.addedAt, DateTime.utc(2026, 10, 26, 12));
      expect(entry.size, await source.length());
      expect(entry.references, 2);
      expect(await sync.deleteUnusedAttachments({entry.id}), 0);
      expect(await File(entry.path!).exists(), isTrue);
      await repo.saveNote(note.id, '', 'Без файла');
      expect((await repo.attachmentInventory()).single.references, 1);
      await repo.commit([task.entity.tombstone()]);
      expect((await repo.attachmentInventory()).single.unused, isTrue);
      expect(await sync.deleteUnusedAttachments({entry.id}), 1);
      expect(await File(entry.path!).exists(), isFalse);
      expect(await repo.attachmentInventory(), isEmpty);
      // Pasting the same content again revives its catalog after a new link is saved.
      final again = await repo.attachFile(source.path);
      await repo.saveNote(note.id, '', again);
      entry = (await repo.attachmentInventory()).single;
      expect(entry.references, 1);
      expect(await File(entry.path!).readAsString(), 'important configuration');
    },
  );

  test('unresolved conflict protects an otherwise unused attachment', () async {
    final source = File('${dir.path}/conflict.txt');
    await source.writeAsString('conflicting content');
    final link = await repo.attachFile(source.path);
    final note = await repo.createNote();
    await repo.saveNote(note.id, '', 'Current version without a link');
    final local = repo.snapshot.note(note.id)!.entity;
    final remote = local.change({'content': link});
    await repo.db.customStatement(
      'INSERT INTO conflicts(id,local,remote) VALUES(?,?,?)',
      [note.id, local.encoded, remote.encoded],
    );
    final entry = (await repo.attachmentInventory()).single;
    expect(entry.references, 1);
    expect(await sync.deleteUnusedAttachments({entry.id}), 0);
    expect(await File(entry.path!).exists(), isTrue);
  });

  test(
    'catalog date survives reopening and is not replaced by download mtime',
    () async {
      final source = File('${dir.path}/picture.png');
      await source.writeAsString('image bytes');
      await repo.attachFile(source.path);
      final entry = (await repo.attachmentInventory()).single;
      await File(entry.path!).setLastModified(DateTime.utc(2028));
      expect((await repo.attachmentInventory()).single.addedAt, entry.addedAt);
      final record = (await repo.db.entity('attachment-${entry.id}'))!;
      await repo.commit([
        record.change({'added_at': null}),
      ]);
      // Existing catalogs did not record a date; don't invent one from a cache.
      expect((await repo.attachmentInventory()).single.addedAt, isNull);
    },
  );
}
