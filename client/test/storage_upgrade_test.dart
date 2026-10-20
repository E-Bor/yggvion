import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';

void main() {
  late Directory root;
  setUpAll(tz.initializeTimeZones);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yggvion-storage-upgrade-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  for (final version in [1, 2, 3]) {
    test(
      'upgrade from v$version retires AI caches and preserves workspace',
      () async {
        final file = File(p.join(root.path, 'workspace.sqlite'));
        var db = LocalDatabase(NativeDatabase(file));
        final repo = Repository(db);
        await repo.initialize();
        final task = await repo.createTask('Стоматолог');
        final note = await repo.createNote();
        await repo.saveNote(note.id, '', '# Идеи\nВажный текст');
        await db.setMeta('ai_enabled', 'true');
        await db.setMeta('ai_model', 'old-model');
        await db.setMeta('ai_speech_model', 'old-speech');
        await db.setMeta('ai_inbox', '[{"id":"old-proposal"}]');
        await db.setMeta('ai_applied_proposal', 'true');
        await db.setMeta('calendar_view', 'week');
        // GLOB must match the literal underscore, not SQL LIKE's wildcard.
        await db.setMeta('airplane_mode', 'preserved');
        final records = (await db.entities()).map((e) => e.encoded).toList();
        final outbox = (await db.customSelect('SELECT * FROM outbox').get())
            .map((row) => row.data)
            .toList();
        await db.customStatement(
          "INSERT INTO files VALUES ('attachment', 'file.txt', '/kept/file.txt', 0)",
        );
        repo.dispose();
        await db.close();

        // Reproduce the real pre-upgrade schema, including the reverted v3 cache.
        final old = sqlite.sqlite3.open(file.path);
        if (version == 1) old.execute('DROP TABLE recovery_snapshots');
        if (version == 3) {
          old.execute(
            'CREATE TABLE semantic_vectors(id TEXT PRIMARY KEY, vector BLOB)',
          );
          old.execute(
            "INSERT INTO semantic_vectors VALUES ('task', x'00000000')",
          );
        }
        old.execute('PRAGMA user_version=$version');
        old.close();

        db = LocalDatabase(NativeDatabase(file));
        try {
          expect((await db.entities()).map((e) => e.encoded), records);
          expect(
            (await db.customSelect('SELECT * FROM outbox').get()).map(
              (row) => row.data,
            ),
            outbox,
          );
          expect((await db.entity(task.id))!.deleted, isFalse);
          expect((await db.search('Идеи')).single.id, note.id);
          expect(await db.meta('ai_enabled'), isNull);
          expect(await db.meta('ai_model'), isNull);
          expect(await db.meta('ai_speech_model'), isNull);
          expect(await db.meta('ai_inbox'), isNull);
          expect(await db.meta('ai_applied_proposal'), isNull);
          expect(await db.meta('calendar_view'), 'week');
          expect(await db.meta('airplane_mode'), 'preserved');
          expect(
            (await db.customSelect('SELECT path FROM files').getSingle())
                .read<String>('path'),
            '/kept/file.txt',
          );
          expect(
            await db.customSelect('SELECT * FROM recovery_snapshots').get(),
            isEmpty,
          );
          expect(
            await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE name='semantic_vectors'",
                )
                .get(),
            isEmpty,
          );
          expect(
            (await db.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            4,
          );
        } finally {
          await db.close();
        }
      },
    );
  }

  test(
    'a failed upgrade rolls back changes and keeps the previous version',
    () async {
      final file = File(p.join(root.path, 'failed-upgrade.sqlite'));
      var db = LocalDatabase(NativeDatabase(file));
      await db.setMeta('ai_enabled', 'true');
      await db.close();
      final old = sqlite.sqlite3.open(file.path);
      old.execute('DROP TABLE recovery_snapshots');
      // A malformed cache must fail explicitly instead of reporting a successful
      // migration after deleting only part of the legacy data.
      old.execute('CREATE VIEW semantic_vectors AS SELECT key FROM metadata');
      old.execute('PRAGMA user_version=1');
      old.close();
      db = LocalDatabase(NativeDatabase(file));
      try {
        await expectLater(
          db.entities(),
          throwsA(isA<sqlite.SqliteException>()),
        );
      } finally {
        await db.close();
      }
      final unchanged = sqlite.sqlite3.open(file.path);
      try {
        expect(
          unchanged.select('PRAGMA user_version').single['user_version'],
          1,
        );
        expect(
          unchanged
              .select("SELECT value FROM metadata WHERE key='ai_enabled'")
              .single['value'],
          'true',
        );
        expect(
          unchanged.select(
            "SELECT name FROM sqlite_master WHERE name='recovery_snapshots'",
          ),
          isEmpty,
        );
      } finally {
        unchanged.close();
      }
    },
  );

  test(
    'cache cleanup removes models and audio, preserves attachments and can repeat',
    () async {
      for (final name in [
        'local-ai/model.gguf',
        'local-ai/model.part',
        'ai-recordings/voice.wav',
        'attachments/voice.wav',
        'yggvion.sqlite',
      ]) {
        final file = File(p.join(root.path, name));
        await file.parent.create(recursive: true);
        await file.writeAsString('keep-or-remove');
      }
      await LocalDatabase.removeRetiredFiles(root);
      await LocalDatabase.removeRetiredFiles(root);
      expect(await Directory(p.join(root.path, 'local-ai')).exists(), isFalse);
      expect(
        await Directory(p.join(root.path, 'ai-recordings')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(root.path, 'attachments/voice.wav')).readAsString(),
        'keep-or-remove',
      );
      expect(
        await File(p.join(root.path, 'yggvion.sqlite')).readAsString(),
        'keep-or-remove',
      );
    },
  );

  test(
    'cache cleanup does not follow links to user files',
    () async {
      final attachments = Directory(p.join(root.path, 'attachments'));
      await attachments.create();
      final kept = File(p.join(attachments.path, 'file.txt'));
      await kept.writeAsString('important');
      await Link(p.join(root.path, 'local-ai')).create(attachments.path);
      final recordings = Directory(p.join(root.path, 'ai-recordings'));
      await recordings.create();
      await Link(p.join(recordings.path, 'linked')).create(attachments.path);
      await LocalDatabase.removeRetiredFiles(root);
      expect(await kept.readAsString(), 'important');
      expect(
        await FileSystemEntity.type(
          p.join(root.path, 'local-ai'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      expect(await recordings.exists(), isFalse);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows developer privileges'
        : false,
  );
}
