import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/domain/fuzzy_search.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  group('indexed search', () {
    late LocalDatabase db;
    setUp(() => db = LocalDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('one character searches immediately with no typo expansion', () async {
      await db.put(Task.create('event-body', 'Планы', description: 'Друг'));
      await db.put(Task.create('event-title', 'Друг'));
      await db.put(Note.create('note-body', '', content: '# Идеи\nДруг'));
      await db.put(
        Note.create('note-title', '', content: '\n  # Друг\nВстреча'),
      );
      await db.put(Note.create('unrelated', '', content: '# Окно\nЗаметки'));
      for (final tolerance in [0, 1, 2]) {
        expect((await db.search('Д', maxTypos: tolerance)).map((e) => e.id), [
          'note-title',
          'note-body',
          'event-title',
          'event-body',
        ]);
        expect(await db.search('х', maxTypos: tolerance), isEmpty);
      }
      expect(
        await db.search('note', maxTypos: 0),
        isEmpty,
        reason: 'the indexed category is not searchable document content',
      );
    });

    test(
      'location outranks accuracy; exact hits lead within each group',
      () async {
        final records = [
          Task.create('event-body-exact', 'Планы', description: 'Днутекст'),
          Task.create('event-title-fuzzy', 'Друг'),
          Task.create('event-title-exact', 'Днутекст'),
          Note.create('note-body-fuzzy', '', content: '# Идеи\nДруг'),
          Note.create('note-body-exact', '', content: '# Вопросы\nДнутекст'),
          Note.create('note-title-fuzzy', '', content: '# Друг'),
          Note.create('note-title-exact', '', content: '# Днутекст'),
        ];
        for (final record in records) {
          await db.put(record);
        }
        expect((await db.search('дну', maxTypos: 1)).map((e) => e.id), [
          'note-title-exact',
          'note-title-fuzzy',
          'note-body-exact',
          'note-body-fuzzy',
          'event-title-exact',
          'event-title-fuzzy',
          'event-body-exact',
        ]);
      },
    );

    test(
      'visible note titles, legacy titles and mixed-field queries rank correctly',
      () async {
        await db.put(
          Note.create('legacy', 'Друг', content: '# Архив\nВстреча'),
        );
        await db.put(Note.create('mixed', '', content: '# Друг\nВстреча'));
        await db.put(Note.create('title', '', content: '# Друг встреча'));
        await db.put(
          Note.create(
            'pinned',
            'Под рукой',
            pinned: 'reference',
            content: '# Друг встреча',
          ),
        );
        expect(
          (await db.search('дру встр', maxTypos: 0)).map((e) => e.id).first,
          'title',
        );
        final result = await db.search('дру', maxTypos: 0);
        expect(result.take(3).map((e) => e.id).toSet(), {
          'mixed',
          'title',
          'legacy',
        });
        expect(result.skip(3).map((e) => e.id).toSet(), {'pinned'});
        expect(
          (await db.search('д встрч', maxTypos: 1)).map((e) => e.id),
          contains('title'),
        );
      },
    );

    test(
      'priorities are applied before the result limit, including fuzzy titles',
      () async {
        await db.transaction(() async {
          for (var i = 0; i < 140; i++) {
            await db.put(Task.create('event-$i', 'Днутекст'));
            await db.put(
              Note.create('body-$i', '', content: '# Идеи $i\nДнутекст'),
            );
          }
          await db.put(Note.create('important', '', content: '# Друг'));
        });
        final results = await db.search('дну', maxTypos: 1);
        expect(results, hasLength(100));
        expect(results.first.id, 'important');
        expect(results.every((e) => e.kind == 'note'), isTrue);
        expect(results.map((e) => e.id).toSet(), hasLength(100));
      },
    );

    test(
      'one corrected prefix covers more than 64 different completions',
      () async {
        await db.transaction(() async {
          for (var i = 0; i < 120; i++) {
            await db.put(Note.create('note-$i', '', content: '# Дружеская$i'));
          }
        });
        expect(await db.search('дну', maxTypos: 1), hasLength(100));
      },
    );

    test(
      'cached vocabulary follows edits, deletion, rollback and workspace replacement',
      () async {
        final first = Note.create('first', '', content: '# Друг');
        final second = Note.create('second', '', content: '# Друг');
        await db.put(first);
        await db.put(second);
        final concurrent = await Future.wait([
          db.search('дну', maxTypos: 1),
          db.search('дру', maxTypos: 1),
        ]);
        expect(concurrent.every((r) => r.length == 2), isTrue);
        await db.put(first.change({'content': '# Идеи\nДруг'}));
        expect((await db.search('дну', maxTypos: 1)).map((e) => e.id), [
          'second',
          'first',
        ]);
        await db.put(second.tombstone());
        expect((await db.search('дну', maxTypos: 1)).single.id, 'first');
        await expectLater(
          db.transaction(() async {
            await db.put(first.change({'content': '# Стоматолог'}));
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(await db.search('стам', maxTypos: 1), isEmpty);
        expect((await db.search('дну', maxTypos: 1)).single.id, 'first');
        await db.transaction(() async {
          await db.clearSearchIndex();
          await db.customStatement('DELETE FROM records');
          await db.put(Note.create('replacement', '', content: '# Стоматолог'));
        });
        expect(await db.search('дну', maxTypos: 1), isEmpty);
        expect((await db.search('стам', maxTypos: 1)).single.id, 'replacement');
      },
    );

    test(
      'prefix-tree retrieval agrees with edit distance on branched vocabulary',
      () async {
        final vocabulary = [
          'друг',
          'дружеский',
          'дружба',
          'дрова',
          'встреча',
          'стоматолог',
          'стома',
          'заметка',
          'задача',
          'запись',
          'ёлка',
          'елочка',
          'cat',
          'caterpillar',
          'cot',
          'copy',
          'cut',
          'dog',
          'ab',
          'abc',
          'acb',
        ];
        for (final word in vocabulary.reversed) {
          await db.put(Note.create(word, '', content: '# $word'));
        }
        for (final query in [
          'д',
          'дн',
          'дну',
          'днх',
          'рду',
          'дуг',
          'встрч',
          'стам',
          'стмат',
          'стмо',
          'стаматал',
          'ёлк',
          'ct',
          'cta',
          'co',
          'cpt',
          'acb',
          'abcc',
          'qzz',
        ]) {
          for (final tolerance in [0, 1, 2]) {
            final limit = wordTypoLimit(query, tolerance);
            final expected = vocabulary
                .where(
                  (word) =>
                      typoDistance(query, word, limit, prefix: true) <= limit,
                )
                .toSet();
            final actual = (await db.search(
              query,
              maxTypos: tolerance,
            )).map((e) => e.id).toSet();
            expect(actual, expected, reason: '$query / $tolerance');
          }
        }
      },
    );
  });

  test(
    'v5 upgrade rebuilds title and body columns while preserving records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yggvion-search-v5-',
      );
      final file = File('${directory.path}/legacy.sqlite');
      var database = LocalDatabase(NativeDatabase(file));
      final records = [
        Note.create('body', '', content: '# Идеи\nДруг'),
        Note.create('title', '', content: '# Друг'),
        Task.create('event', 'Друг'),
      ];
      try {
        for (final record in records) {
          await database.put(record);
        }
        await database.setMeta('sync_cursor', '123');
        await database.close();
        final old = sqlite.sqlite3.open(file.path);
        old.execute('DROP TABLE search_terms');
        old.execute('DROP TABLE search_index');
        old.execute(
          "CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED, content, tokenize='unicode61')",
        );
        old.execute(
          "CREATE VIRTUAL TABLE search_terms USING fts5vocab(search_index, 'row')",
        );
        for (final record in records) {
          old.execute('INSERT INTO search_index(id,content) VALUES(?,?)', [
            record.id,
            record.searchable,
          ]);
        }
        old.execute('PRAGMA user_version=5');
        old.close();
        database = LocalDatabase(NativeDatabase(file));
        expect((await database.search('дну', maxTypos: 1)).map((e) => e.id), [
          'title',
          'body',
          'event',
        ]);
        expect(
          (await database.entities()).map((e) => e.encoded),
          records.map((e) => e.encoded),
        );
        expect(await database.meta('sync_cursor'), '123');
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
