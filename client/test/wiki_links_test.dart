import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/note_links.dart';

void main() {
  setUpAll(tz.initializeTimeZones);

  test(
    'wiki completion respects the caret, closing brackets, escapes and code',
    () {
      const text = 'До [[Материалы]] после';
      final caret = text.indexOf('Материалы') + 3;
      final query = WikiQuery.at(text, caret)!;
      expect(query.query, 'Мат');
      expect(
        text.replaceRange(query.start, query.end, '[[План]]'),
        'До [[План]] после',
      );
      expect(WikiQuery.at('[[', 2)?.query, '');
      expect(WikiQuery.at('[[Мат', 5)?.query, 'Мат');
      for (final literal in [
        r'\[[Мат',
        '[[Мат]]',
        '[[Мат\n',
        '```text\n[[Мат',
        '~~~\n[[Мат',
        '    [[Мат',
      ]) {
        expect(WikiQuery.at(literal, literal.length), isNull, reason: literal);
      }
      expect(WikiQuery.at('`[[Мат]]`', 6), isNull);
      expect(WikiQuery.at('`код [[', 7), isNull);
      expect(WikiQuery.at('``код [[', 8), isNull);
      expect(WikiQuery.at('[[Мат', -1), isNull);
      expect(WikiQuery.at('[[Мат', 999), isNull);
    },
  );

  test('wiki links escape labels and leave code examples untouched', () {
    const target = r'План [Q4] | C:\notes';
    final encoded = WikiLink.format(target, label: 'Нажать [здесь]');
    final decoded = WikiLink.inMarkdown(encoded).single;
    expect(decoded.target, target);
    expect(decoded.label, 'Нажать [здесь]');
    final text =
        '[[Один]]\n\n`[[Код]]`\n\n```\n[[Пример]]\n```\n\n'
        r'\[[Литерал]]'
        '\n\n    [[Отступ]]\n\n[[Два|Алиас]]';
    expect(WikiLink.inMarkdown(text).map((link) => link.target), [
      'Один',
      'Два',
    ]);
  });

  test(
    'folder paths disambiguate names and searching filters titles and folders',
    () {
      final snapshot = Snapshot([
        Entity(id: 'work', kind: 'note_folder', data: {'title': 'Работа'}),
        Entity(id: 'life', kind: 'note_folder', data: {'title': 'Личное'}),
        Note.create('a', 'План').change({'folder_id': 'work'}),
        Note.create('b', 'План').change({'folder_id': 'life'}),
        Note.create('c', 'Идеи', content: '# Не название'),
      ]);
      final index = WikiNoteIndex(snapshot);
      expect(index.resolve('план'), isNull);
      expect(index.resolve('работа/План')?.id, 'a');
      expect(index.linkFor(snapshot.note('a')!), '[[Работа/План]]');
      expect(index.linkFor(snapshot.note('c')!), '[[Идеи]]');
      expect(index.search('пл раб').map((note) => note.id), ['a']);
      expect(index.search('нет совпадения'), isEmpty);
      expect(index.resolve('note:a')?.id, 'a');
    },
  );

  test(
    'renaming and moving preserve wiki links in notes and event descriptions',
    () async {
      final repo = Repository(LocalDatabase(NativeDatabase.memory()));
      await repo.initialize();
      addTearDown(repo.db.close);
      await repo.saveNoteFolder('Работа');
      await repo.saveNoteFolder('Личное');
      final work = repo.snapshot.noteFolders.first;
      final life = repo.snapshot.noteFolders.last;
      final a = await repo.createNote(folderId: work.id);
      await repo.saveNoteContent(a.id, '# План\nСодержание');
      final source = await repo.createNote();
      await repo.saveNote(
        source.id,
        'Ссылки',
        '[[План]] и [[План|Читать]]\n\n`[[План]]`\n\n[Старая](note:${a.id})',
      );
      await repo.createTask('Встреча', description: 'См. [[План]]');
      await repo.saveNoteContent(a.id, '# Материалы\nСодержание');
      expect(
        repo.snapshot.note(source.id)!.content,
        '[[Материалы]] и [[Материалы|Читать]]\n\n`[[План]]`\n\n[Старая](note:${a.id})',
      );
      expect(repo.snapshot.tasks.single.description, 'См. [[Материалы]]');
      final b = await repo.createNote(folderId: life.id);
      await repo.saveNote(b.id, 'Материалы', 'Другой документ');
      expect(
        repo.snapshot.tasks.single.description,
        'См. [[Работа/Материалы]]',
      );
      await repo.saveNoteFolder('Офис', folder: work);
      expect(repo.snapshot.tasks.single.description, 'См. [[Офис/Материалы]]');
      await repo.moveNote(a.id, life.id);
      final link = WikiLink.inMarkdown(
        repo.snapshot.tasks.single.description,
      ).single;
      expect(WikiNoteIndex(repo.snapshot).resolve(link.target)?.id, a.id);
      expect(link.label, 'Материалы');
      await repo.renameNote(a.id, 'Новое название');
      expect(WikiNoteIndex(repo.snapshot).resolve(link.target)?.id, a.id);
      await repo.deleteNoteFolder(life);
      expect(WikiNoteIndex(repo.snapshot).resolve(link.target)?.id, a.id);
      await expectLater(
        repo.createNote(folderId: 'deleted-folder'),
        throwsArgumentError,
      );
      expect(
        repo.snapshot.notes.where((n) => n.folderId == 'deleted-folder'),
        isEmpty,
      );
    },
  );
}
