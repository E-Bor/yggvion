import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';

class LocalDatabase extends GeneratedDatabase {
  LocalDatabase(super.executor);
  static Future<LocalDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return LocalDatabase(
      NativeDatabase.createInBackground(
        File(p.join(dir.path, 'yggvion.sqlite')),
      ),
    );
  }

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final sql in [
        'CREATE TABLE records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)',
        'CREATE INDEX records_kind ON records(kind, deleted)',
        'CREATE TABLE outbox(id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, ordinal INTEGER NOT NULL)',
        'CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        'CREATE TABLE conflicts(id TEXT PRIMARY KEY, local TEXT NOT NULL, remote TEXT NOT NULL)',
        'CREATE TABLE files(id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0)',
        "CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED, content, tokenize='unicode61')",
      ]) {
        await customStatement(sql);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA journal_mode=WAL');
      await customStatement('PRAGMA busy_timeout=5000');
    },
  );
  Future<List<Entity>> entities({bool includeDeleted = false}) async {
    final rows = await customSelect(
      'SELECT payload FROM records ${includeDeleted ? '' : 'WHERE deleted=0'} ORDER BY rowid',
    ).get();
    return rows
        .map(
          (r) => Entity.fromJson(
            jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Future<Entity?> entity(String id) async {
    final row = await customSelect(
      'SELECT payload FROM records WHERE id=?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    return row == null
        ? null
        : Entity.fromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          );
  }

  Future<void> put(Entity entity) async {
    await customStatement(
      'INSERT INTO records(id,kind,payload,deleted) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, deleted=excluded.deleted',
      [entity.id, entity.kind, entity.encoded, entity.deleted ? 1 : 0],
    );
    await customStatement('DELETE FROM search_index WHERE id=?', [entity.id]);
    if (!entity.deleted && entity.searchable.isNotEmpty) {
      await customStatement(
        'INSERT INTO search_index(id,content) VALUES (?,?)',
        [entity.id, entity.searchable],
      );
    }
  }

  Future<String?> meta(String key) async => (await customSelect(
    'SELECT value FROM metadata WHERE key=?',
    variables: [Variable(key)],
  ).getSingleOrNull())?.read<String>('value');
  Future<void> setMeta(String key, String value) => customStatement(
    'INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  // Shared with the Linux companion so only one process delivers a reminder.
  Future<bool> claimReminder(String key) async =>
      await customUpdate(
        'INSERT OR IGNORE INTO metadata(key,value) VALUES (?,?)',
        variables: [
          Variable(key),
          Variable(DateTime.now().toUtc().toIso8601String()),
        ],
      ) ==
      1;

  Future<void> releaseReminder(String key) =>
      customStatement('DELETE FROM metadata WHERE key=?', [key]);
  Future<List<Entity>> search(String query) async {
    final words = RegExp(
      r'[\p{L}\p{N}_]+',
      unicode: true,
    ).allMatches(query).map((m) => '"${m[0]}"*').take(20).join(' AND ');
    if (words.isEmpty) return [];
    final rows = await customSelect(
      'SELECT r.payload FROM search_index s JOIN records r ON r.id=s.id WHERE search_index MATCH ? AND r.deleted=0 ORDER BY rank LIMIT 100',
      variables: [Variable(words)],
    ).get();
    return rows
        .map(
          (r) => Entity.fromJson(
            jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
          ),
        )
        .toList();
  }
}
