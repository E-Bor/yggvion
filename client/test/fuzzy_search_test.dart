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

  late LocalDatabase db;
  setUp(() {
    db = LocalDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

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
    'short terms stay exact and two-typo results do not duplicate exact ones',
    () async {
      await db.put(Note.create('one', 'Поездка', content: 'дом кот коттедж'));
      await db.put(Note.create('two', 'Идеи', content: 'том'));
      expect(await db.search('до', maxTypos: 2), hasLength(1));
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
