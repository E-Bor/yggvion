import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  late Repository repo;
  setUpAll(tz.initializeTimeZones);
  setUp(() async {
    repo = Repository(LocalDatabase(NativeDatabase.memory()));
    await repo.initialize();
  });
  tearDown(() async {
    await repo.db.close();
    repo.dispose();
  });

  test(
    'cleanup discards only blank regular notes and queues synced deletions',
    () async {
      final emptyIds = <String>[];
      final kept = <String, String>{};
      for (final content in ['', '   ', '\n\n', ' \n\t\r\n\u00a0 ']) {
        final note = await repo.createNote();
        await repo.saveNote(note.id, 'Удаляемая заметка', content);
        emptyIds.add(note.id);
      }
      for (final content in [
        '0',
        '.',
        '🌱',
        '  Текст\n  ',
        '```\n```',
        '![](attachment:example)',
      ]) {
        final note = await repo.createNote();
        await repo.saveNote(note.id, note.title, content);
        kept[note.id] = content;
      }
      final task = await repo.createTask('Задача');
      await repo.discardEmptyNotes([
        ...repo.snapshot.notes.map((note) => note.id),
        task.id,
        'missing',
      ]);
      expect(
        repo.snapshot.notes.map((note) => note.id),
        unorderedEquals(['scratchpad', 'reference', ...kept.keys]),
      );
      for (final entry in kept.entries) {
        expect(Note((await repo.db.entity(entry.key))!).content, entry.value);
      }
      expect((await repo.db.entity(task.id))!.deleted, isFalse);
      expect(await repo.db.search('Удаляемая'), isEmpty);
      final outbox = await repo.db
          .customSelect('SELECT payload FROM outbox')
          .get();
      final deleted = outbox
          .map(
            (row) => Entity.fromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
            ),
          )
          .where((entity) => entity.deleted)
          .map((entity) => entity.id);
      expect(deleted, unorderedEquals(emptyIds));
      await repo.discardEmptyNotes(emptyIds);
      expect(repo.snapshot.notes, hasLength(kept.length + 2));
    },
  );

  test(
    'cleanup waits for the last keystroke and late saves cannot resurrect blank notes',
    () async {
      final note = await repo.createNote();
      final gate = Completer<void>();
      final blocker = repo.serial(() => gate.future);
      final whitespace = repo.saveNote(note.id, note.title, ' \n');
      final meaningful = repo.saveNote(
        note.id,
        note.title,
        ' \nПоследний символ!  ',
      );
      final cleanup = repo.discardEmptyNotes([note.id]);
      gate.complete();
      await Future.wait([blocker, whitespace, meaningful, cleanup]);
      expect(
        repo.snapshot.notes.singleWhere((n) => n.id == note.id).content,
        ' \nПоследний символ!  ',
      );

      final clear = repo.saveNote(note.id, note.title, '\n   \n');
      final discard = repo.discardEmptyNotes([note.id]);
      final lateSave = repo.saveNote(note.id, note.title, '\n   \n');
      final newNote = repo.createNote();
      await Future.wait([clear, discard, lateSave]);
      final created = await newNote;
      expect((await repo.db.entity(note.id))!.deleted, isTrue);
      expect(repo.snapshot.notes.any((n) => n.id == note.id), isFalse);
      expect(repo.snapshot.notes.any((n) => n.id == created.id), isTrue);
    },
  );
}
