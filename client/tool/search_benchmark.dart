// Run explicitly: flutter test --no-pub tool/search_benchmark.dart --reporter expanded
// Uses synthetic data in a temporary database, never the user's workspace.
import 'dart:io';
import 'dart:math' as math;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  test(
    'search latency on 50,000 notes and events',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yggvion-search-bench-',
      );
      final file = File('${directory.path}/benchmark.sqlite');
      final raw = sqlite.sqlite3.open(file.path);
      // An actual v5-shaped database also exercises rebuilding the old index.
      for (final statement in [
        'CREATE TABLE records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)',
        'CREATE INDEX records_kind ON records(kind,deleted)',
        'CREATE TABLE outbox(id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, ordinal INTEGER NOT NULL)',
        'CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        'CREATE TABLE conflicts(id TEXT PRIMARY KEY, local TEXT NOT NULL, remote TEXT NOT NULL)',
        'CREATE TABLE files(id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0)',
        'CREATE TABLE recovery_snapshots(id TEXT PRIMARY KEY, created TEXT NOT NULL, payload TEXT NOT NULL)',
        "CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED, content, tokenize='unicode61')",
        "CREATE VIRTUAL TABLE search_terms USING fts5vocab(search_index, 'row')",
        'CREATE TABLE app_activity(id INTEGER PRIMARY KEY, start INTEGER NOT NULL, end INTEGER NOT NULL)',
        'CREATE INDEX app_activity_end ON app_activity(end)',
        'PRAGMA user_version=5',
      ]) {
        raw.execute(statement);
      }
      final record = raw.prepare('INSERT INTO records VALUES(?,?,?,0)');
      final index = raw.prepare(
        'INSERT INTO search_index(id,content) VALUES(?,?)',
      );
      final random = math.Random(42);
      String word() => String.fromCharCodes(
        List.generate(10, (_) => 97 + random.nextInt(26)),
      );
      const topics = [
        'Проект',
        'Стоматолог',
        'Друг',
        'Путешествие',
        'Разработка',
        'Покупки',
      ];
      raw.execute('BEGIN');
      for (var i = 0; i < 50000; i++) {
        final title = '${topics[(i ~/ 2) % topics.length]} ${word()}';
        final content =
            '${topics[((i ~/ 2) + 1) % topics.length]} ${word()} ${word()}\n'
                'Обсудить планы, подготовить материалы и сверить расписание. '
                'Важные детали встречи, список вопросов и ссылки на документы.\n' *
            4;
        final entity = i.isEven
            ? Note.create('item-$i', '', content: '# $title\n$content')
            : Task.create('item-$i', title, description: content);
        record.execute([entity.id, entity.kind, entity.encoded]);
        index.execute([entity.id, entity.searchable]);
      }
      raw.execute('COMMIT');
      record.close();
      index.close();
      raw.close();
      final db = LocalDatabase(NativeDatabase.createInBackground(file));
      try {
        final opening = Stopwatch()..start();
        await db.meta('benchmark');
        stdout.writeln('OPEN_OR_MIGRATE_MS=${opening.elapsedMilliseconds}');
        final cold = Stopwatch()..start();
        expect(await db.search('дну', maxTypos: 1), isNotEmpty);
        stdout.writeln('COLD_FUZZY_MS=${cold.elapsedMilliseconds}');
        for (final (query, typos) in [
          ('п', 2),
          ('др', 2),
          ('дну', 1),
          ('стам', 1),
          ('стаматал', 2),
          ('проект', 2),
          ('ффф', 1),
          ('ab', 2),
          ('abc', 2),
          ('abct', 2),
        ]) {
          final times = <double>[];
          for (var i = 0; i < 12; i++) {
            final watch = Stopwatch()..start();
            final results = await db.search(query, maxTypos: typos);
            times.add(watch.elapsedMicroseconds / 1000);
            expect(results.length, lessThanOrEqualTo(100));
          }
          times.sort();
          stdout.writeln(
            'QUERY=$query TYPOS=$typos P50_MS=${times[times.length ~/ 2].toStringAsFixed(1)} P95_MS=${times.last.toStringAsFixed(1)}',
          );
        }
        final update = Stopwatch()..start();
        await db.put(
          Note.create(
            'item-0',
            '',
            content: '# Изменённая заметка\nДруг и планы',
          ),
        );
        stdout.writeln('UPDATE_ONE_MS=${update.elapsedMilliseconds}');
        final refreshed = Stopwatch()..start();
        expect(await db.search('изменённ', maxTypos: 1), isNotEmpty);
        stdout.writeln(
          'SEARCH_AFTER_UPDATE_MS=${refreshed.elapsedMilliseconds}',
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
