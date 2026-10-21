import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/server_metrics.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'optional titles prefer explicit name then first heading outside code',
    () {
      Note make(String title, String text) =>
          Note(Note.create('n', title, content: text));
      expect(make('Name', '# Heading').displayLabel, 'Name');
      expect(
        make('', 'introduction\n\n## Heading\nbody').displayLabel,
        'Heading',
      );
      expect(
        make('Новая заметка', '```\n# code\n```\n# Actual').displayLabel,
        'Actual',
      );
      expect(make('', 'Heading\n======').displayLabel, 'Heading');
      expect(make('', 'plain text\nbody').displayLabel, 'plain text');
    },
  );
  test(
    'move reorder folder deletion and named empty note preserve content',
    () async {
      final repo = Repository(LocalDatabase(NativeDatabase.memory()));
      await repo.initialize();
      addTearDown(repo.db.close);
      await repo.saveNoteFolder('Work');
      await repo.saveNoteFolder('Life');
      final folder = repo.snapshot.noteFolders.first;
      final a = await repo.createNote(),
          b = await repo.createNote(),
          c = await repo.createNote();
      await repo.saveNoteContent(a.id, 'A');
      await repo.saveNoteContent(b.id, 'B');
      await repo.renameNote(c.id, 'Named empty');
      await repo.moveNote(b.id, '', beforeId: a.id);
      expect(repo.snapshot.notesInFolder('').map((n) => n.id), [
        b.id,
        a.id,
        c.id,
      ]);
      await repo.moveNote(a.id, folder.id);
      await repo.moveNote(b.id, folder.id, beforeId: a.id);
      expect(repo.snapshot.notesInFolder(folder.id).map((n) => n.id), [
        b.id,
        a.id,
      ]);
      await repo.deleteNoteFolder(folder);
      expect(
        repo.snapshot.notesInFolder('').map((n) => n.id),
        containsAll([a.id, b.id, c.id]),
      );
      await repo.discardEmptyNotes([c.id]);
      expect(repo.snapshot.note(c.id), isNotNull);
      await repo.renameNote(c.id, '');
      await repo.discardEmptyNotes([c.id]);
      expect(repo.snapshot.note(c.id), isNull);
      await expectLater(
        repo.moveNote(a.id, 'removed-folder'),
        throwsArgumentError,
      );
      // Concurrent title and body writes must not overwrite each other.
      await Future.wait([
        repo.renameNote(a.id, 'Changed'),
        repo.saveNoteContent(a.id, 'Changed body'),
      ]);
      expect(repo.snapshot.note(a.id)!.title, 'Changed');
      expect(repo.snapshot.note(a.id)!.content, 'Changed body');
    },
  );
  test(
    'server metric payload is validated including unavailable CPU sample',
    () {
      final payload = <String, dynamic>{
        'sampled_at': '2026-10-21T10:00:00Z',
        'cpu_percent': 12.5,
        'memory_total_bytes': 1000,
        'memory_used_bytes': 400,
        'process_memory_bytes': 100,
        'disk_total_bytes': 2000,
        'disk_available_bytes': 1500,
        'uptime_seconds': 50,
      };
      expect(ServerMetrics.fromJson(payload).cpuPercent, 12.5);
      expect(
        ServerMetrics.fromJson({...payload, 'cpu_percent': null}).cpuPercent,
        isNull,
      );
      for (final bad in [
        {'cpu_percent': 101},
        {'disk_available_bytes': 3000},
        {'memory_used_bytes': -1},
      ]) {
        expect(
          () => ServerMetrics.fromJson({...payload, ...bad}),
          throwsFormatException,
        );
      }
    },
  );
}
