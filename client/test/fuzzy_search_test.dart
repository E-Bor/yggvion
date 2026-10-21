import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/fuzzy_search.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  test('bounded distance supports Unicode and all four typo kinds', () {
    for (final value in [
      'стаматолог',
      'стомматолог',
      'стомтолог',
      'стмоатолог',
    ]) {
      expect(typoDistance(value, 'стоматолог', 1), 1, reason: value);
    }
    expect(typoDistance('стаматалог', 'стоматолог', 2), 2);
    expect(typoDistance('стаматалог', 'стоматолог', 1), greaterThan(1));
    expect(typoDistance('ёлка', 'елка', 1), 0);
    expect(typoDistance('😀кот', '😃кот', 1), 1);
    expect(typoDistance('', 'a', 1), 1);
    expect(typoDistance('a', '', 1), 1);
  });

  test(
    'prefix distance allows edits without charging for the remaining suffix',
    () {
      for (final (query, word, distance) in [
        ('дру', 'друг', 0),
        ('дну', 'друг', 1),
        ('стам', 'стоматолог', 1),
        ('стоммат', 'стоматолог', 1),
        ('стмат', 'стоматолог', 1),
        ('стмо', 'стоматолог', 1),
        ('стаматал', 'стоматолог', 2),
        ('други', 'друг', 1),
        ('днх', 'друг', 2),
        ('ёлк', 'елка', 0),
        ('😃ко', '😀кот', 1),
        ('', 'друг', 0),
      ]) {
        expect(
          typoDistance(query, word, distance, prefix: true),
          distance,
          reason: '$query → $word',
        );
        if (distance > 0) {
          expect(
            typoDistance(query, word, distance - 1, prefix: true),
            greaterThan(distance - 1),
            reason: '$query → $word with a smaller tolerance',
          );
        }
      }
      expect(
        typoDistance('матол', 'стоматолог', 1, prefix: true),
        greaterThan(1),
      );
    },
  );

  late LocalDatabase db;
  setUp(() {
    db = LocalDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  test('mistyped prefixes match before the whole word is entered', () async {
    await db.put(Task.create('friend', 'Друг'));
    await db.put(Note.create('note', '', content: '# Дружеская встреча'));
    await db.put(
      Task.create('dentist', 'Запись', description: 'Стоматолог завтра'),
    );
    await db.put(
      Note.create(
        'long',
        '',
        content: 'стоматолог${List.filled(80, 'а').join()}',
      ),
    );
    await db.put(Task.create('unrelated', 'Преддруг'));

    // The user's example: the untyped final letter is not a second error.
    expect(await db.search('ДНу', maxTypos: 0), isEmpty);
    expect(
      (await db.search('ДНу', maxTypos: 1)).map((e) => e.id),
      unorderedEquals(['friend', 'note']),
    );
    for (final query in ['дрру', 'дуг', 'рду', 'хру']) {
      expect(
        (await db.search(query, maxTypos: 1)).map((e) => e.id),
        contains('friend'),
        reason: query,
      );
    }
    // All typed fragments must match, independently of their order in the text.
    expect((await db.search('встрч дну', maxTypos: 1)).single.id, 'note');
    expect(await db.search('днх', maxTypos: 1), isEmpty);
    expect(
      (await db.search('днх', maxTypos: 2)).map((e) => e.id),
      containsAll(['friend', 'note']),
    );
    expect((await db.search('ззз', maxTypos: 2)).single.id, 'dentist');
    expect(await db.search('ффф', maxTypos: 2), isEmpty);
    expect(
      (await db.search('стам', maxTypos: 1)).map((e) => e.id),
      unorderedEquals(['dentist', 'long']),
    );
    expect(await db.search('матол', maxTypos: 1), isEmpty);

    await db.put(Note.create('exact', '', content: 'Днутекст'));
    final results = await db.search('дну', maxTypos: 2);
    expect(results.first.id, 'exact');
    expect(results.map((e) => e.id), containsAll(['friend', 'note']));
    expect(results.map((e) => e.id).toSet(), hasLength(results.length));
  });

  test(
    'search covers titles, descriptions, notes and ranks exact matches first',
    () async {
      await db.put(
        Task.create('dentist', 'Стоматолог', description: 'Проверить пломбу'),
      );
      await db.put(
        Note.create('note', 'Архив', content: '# Стаматолог\nЗаметка'),
      );
      await db.put(
        Task.create('future', 'Встреча', description: 'Стоматолог завтра'),
      );
      expect((await db.search('стаматолог')).map((e) => e.id), ['note']);
      expect(
        (await db.search('стаматолог', maxTypos: 1)).map((e) => e.id),
        containsAllInOrder(['note', 'dentist']),
      );
      expect(
        (await db.search('стаматалог', maxTypos: 1)).map((e) => e.id),
        isNot(contains('dentist')),
      );
      expect(
        (await db.search('стаматалог', maxTypos: 2)).map((e) => e.id),
        containsAll(['dentist', 'future']),
      );
      expect((await db.search('пломбк', maxTypos: 1)).single.id, 'dentist');
      expect(
        (await db.search('стом')).map((e) => e.id),
        containsAll(['dentist', 'future']),
      );
      expect(await db.search(' \n.*"'), isEmpty);
      expect(await db.search('стоматолог отсутствует', maxTypos: 2), isEmpty);
    },
  );

  test(
    'updates and deletions immediately update fuzzy results; multi-word query is AND',
    () async {
      final task = Task.create('task', 'Встреча стоматолог');
      await db.put(task);
      await db.put(Note.create('other', 'Заметка', content: 'Только встреча'));
      expect(
        (await db.search('встрча стаматолог', maxTypos: 1)).single.id,
        'task',
      );
      await db.put(task.change({'title': 'Работа'}));
      expect(await db.search('стаматолог', maxTypos: 2), isEmpty);
      await db.put(task);
      await db.put(task.tombstone());
      expect(await db.search('стаматолог', maxTypos: 2), isEmpty);
      await db.put(
        Entity(id: 'series', kind: 'series', data: {'title': 'Стоматолог'}),
      );
      expect(await db.search('стаматолог', maxTypos: 2), isEmpty);
      await expectLater(db.search('abc', maxTypos: 3), throwsArgumentError);
      await expectLater(db.search('abc', maxTypos: -1), throwsArgumentError);
    },
  );

  test(
    'one letter stays exact and two letters allow at most one typo',
    () async {
      await db.put(Note.create('one', 'Поездка', content: 'дом кот коттедж'));
      await db.put(Note.create('two', 'Идеи', content: 'том'));
      expect(await db.search('д', maxTypos: 2), hasLength(1));
      expect(await db.search('х', maxTypos: 2), isEmpty);
      expect(await db.search('до', maxTypos: 0), hasLength(1));
      expect(await db.search('до', maxTypos: 2), hasLength(2));
      expect(await db.search('хх', maxTypos: 2), isEmpty);
      expect(await db.search('дом', maxTypos: 2), hasLength(2));
    },
  );

  test(
    'synced search setting defaults to one and survives unrelated setting changes',
    () async {
      final repo = Repository(db);
      await repo.initialize();
      expect(repo.snapshot.settings.searchTypos, 1);
      await repo.updateSettings(30, [0], 'UTC', searchTypos: 2);
      await repo.updateSettings(60, [15], 'UTC');
      expect(repo.snapshot.settings.searchTypos, 2);
      final roundtrip = AppSettings(
        Entity.fromJson(repo.snapshot.settings.entity.toJson()),
      );
      expect(roundtrip.searchTypos, 2);
      await expectLater(
        repo.updateSettings(30, [0], 'UTC', searchTypos: 3),
        throwsArgumentError,
      );
      expect(repo.snapshot.settings.searchTypos, 2);
      repo.dispose();
    },
  );

  test(
    'v4 upgrade builds vocabulary for existing notes without reimporting them',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yggvion-search-upgrade-',
      );
      final file = File('${directory.path}/test.sqlite');
      var database = LocalDatabase(NativeDatabase(file));
      try {
        await database.put(
          Note.create('existing', 'Важное', content: 'Стоматолог'),
        );
        await database.close();
        final old = sqlite.sqlite3.open(file.path);
        old.execute('DROP TABLE search_terms');
        old.execute('DROP TABLE app_activity');
        old.execute('PRAGMA user_version=4');
        old.close();
        database = LocalDatabase(NativeDatabase(file));
        expect(
          (await database.search('стаматолог', maxTypos: 1)).single.id,
          'existing',
        );
        expect(
          await database.activity(DateTime.utc(2026), DateTime.utc(2027)),
          isEmpty,
        );
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
