import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';

class LocalDatabase extends GeneratedDatabase {
  LocalDatabase(super.executor);
  static Future<LocalDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    try {
      await removeRetiredFiles(dir);
    } on FileSystemException catch (error) {
      // Retry on the next launch; a locked cache must not block workspace access.
      debugPrint('Could not remove retired local caches: $error');
    }
    return LocalDatabase(
      NativeDatabase.createInBackground(
        File(p.join(dir.path, 'yggvion.sqlite')),
      ),
    );
  }

  /// Only these app-owned caches are retired. Never follow links into attachments
  /// or delete paths saved in old model/voice metadata.
  static Future<void> removeRetiredFiles(Directory root) async {
    for (final name in ['local-ai', 'ai-recordings']) {
      final path = p.join(root.path, name);
      switch (await FileSystemEntity.type(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.file:
          await File(path).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          throw FileSystemException('Unexpected retired cache type', path);
      }
    }
  }

  @override
  int get schemaVersion => 4;
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
        'CREATE TABLE recovery_snapshots(id TEXT PRIMARY KEY, created TEXT NOT NULL, payload TEXT NOT NULL)',
        "CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED, content, tokenize='unicode61')",
      ]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (m, from, to) => transaction(() async {
      if (from < 2) {
        await customStatement(
          'CREATE TABLE recovery_snapshots(id TEXT PRIMARY KEY, created TEXT NOT NULL, payload TEXT NOT NULL)',
        );
      }
      if (from < 4) {
        // Version 3 was used by the reverted semantic-search experiment.
        // Its vectors and AI metadata are disposable, unlike accepted tasks.
        await customStatement('DROP TABLE IF EXISTS semantic_vectors');
        await customStatement("DELETE FROM metadata WHERE key GLOB 'ai_*'");
      }
    }),
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
