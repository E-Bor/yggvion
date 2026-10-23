import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import '../domain/fuzzy_search.dart';
import 'search_worker.dart';
import 'storage_reset.dart';

class LocalDatabase extends GeneratedDatabase {
  LocalDatabase(super.executor);
  final _searchWorker = SearchWorker();
  int _searchRevision = 0, _vocabularyRevision = -1;
  Future<void>? _preparingVocabulary;
  static Future<LocalDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    await StorageReset.finishPending(dir);
    if (Platform.isIOS) {
      await const MethodChannel(
        'dev.yggvion/storage_policy',
      ).invokeMethod<void>('excludePrivateDataFromBackup');
    }
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
  int get schemaVersion => 8;
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
        'CREATE TABLE IF NOT EXISTS encrypted_outbox(operation_id TEXT PRIMARY KEY, source TEXT NOT NULL, payload TEXT NOT NULL)',
        'CREATE TABLE IF NOT EXISTS encrypted_files(key_id TEXT NOT NULL, id TEXT NOT NULL, cipher_id TEXT NOT NULL, PRIMARY KEY(key_id,id))',
        _searchSchema,
        _vocabularySchema,
        'CREATE TABLE app_activity(id INTEGER PRIMARY KEY, start INTEGER NOT NULL, end INTEGER NOT NULL)',
        'CREATE INDEX app_activity_end ON app_activity(end)',
      ]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (m, from, to) => transaction(() async {
      if (from < 8) {
        await customStatement(
          'CREATE TABLE IF NOT EXISTS encrypted_outbox(operation_id TEXT PRIMARY KEY, source TEXT NOT NULL, payload TEXT NOT NULL)',
        );
        await customStatement(
          'CREATE TABLE IF NOT EXISTS encrypted_files(key_id TEXT NOT NULL, id TEXT NOT NULL, cipher_id TEXT NOT NULL, PRIMARY KEY(key_id,id))',
        );
      }
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
      if (from < 5) {
        await customStatement(
          'CREATE TABLE app_activity(id INTEGER PRIMARY KEY, start INTEGER NOT NULL, end INTEGER NOT NULL)',
        );
        await customStatement(
          'CREATE INDEX app_activity_end ON app_activity(end)',
        );
      }
      if (from < 7) {
        // Search is a derived index. Rebuild it from the unchanged records,
        // including the visible Markdown title of each note.
        await customStatement('DROP TABLE IF EXISTS search_terms');
        await customStatement('DROP TABLE search_index');
        await customStatement(_searchSchema);
        await customStatement(_vocabularySchema);
        var lastRow = 0;
        while (true) {
          final rows = await customSelect(
            "SELECT rowid,payload FROM records WHERE rowid>? AND deleted=0 AND kind IN ('note','task') ORDER BY rowid LIMIT 256",
            variables: [Variable(lastRow)],
          ).get();
          if (rows.isEmpty) break;
          await batch((batch) {
            for (final row in rows) {
              final entity = Entity.fromJson(
                jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
              );
              final document = searchDocument(entity);
              if (document != null) {
                batch.customStatement(
                  'INSERT INTO search_index(rowid,title,body,category) VALUES(?,?,?,?)',
                  [
                    row.read<int>('rowid'),
                    document.title,
                    document.body,
                    document.category,
                  ],
                );
              }
            }
          });
          lastRow = rows.last.read<int>('rowid');
        }
      }
    }),
    beforeOpen: (details) async {
      await customStatement('PRAGMA journal_mode=WAL');
      await customStatement('PRAGMA busy_timeout=5000');
    },
  );
  static const _searchSchema =
      "CREATE VIRTUAL TABLE search_index USING fts5(title, body, category, tokenize='unicode61', prefix='1 2 3 4')";
  static const _vocabularySchema =
      "CREATE VIRTUAL TABLE search_terms USING fts5vocab(search_index, 'col')";
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

  Future<void> put(Entity entity) => transaction(() async {
    await customStatement(
      'INSERT INTO records(id,kind,payload,deleted) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, deleted=excluded.deleted',
      [entity.id, entity.kind, entity.encoded, entity.deleted ? 1 : 0],
    );
    if (entity.kind != 'note' && entity.kind != 'task') return;
    final row = await customSelect(
      'SELECT r.rowid,s.title,s.body,s.category FROM records r LEFT JOIN search_index s ON s.rowid=r.rowid WHERE r.id=?',
      variables: [Variable(entity.id)],
    ).getSingle();
    final document = searchDocument(entity);
    if (row.readNullable<String>('title') == document?.title &&
        row.readNullable<String>('body') == document?.body &&
        row.readNullable<String>('category') == document?.category) {
      return; // Status/timer/sync metadata changes do not rebuild search text.
    }
    final rowId = row.read<int>('rowid');
    await customStatement('DELETE FROM search_index WHERE rowid=?', [rowId]);
    if (document != null) {
      await customStatement(
        'INSERT INTO search_index(rowid,title,body,category) VALUES (?,?,?,?)',
        [rowId, document.title, document.body, document.category],
      );
    }
    _searchRevision++;
  });

  Future<void> clearSearchIndex() async {
    await customStatement('DELETE FROM search_index');
    _searchRevision++;
  }

  Future<void> _prepareVocabulary() async {
    while (_vocabularyRevision != _searchRevision) {
      final preparing = _preparingVocabulary ??= _loadVocabulary(
        _searchRevision,
      );
      try {
        await preparing;
      } finally {
        if (identical(_preparingVocabulary, preparing)) {
          _preparingVocabulary = null;
        }
      }
    }
  }

  Future<void> _loadVocabulary(int revision) async {
    final rows = await customSelect(
      "SELECT DISTINCT term FROM search_terms WHERE col IN ('title','body') ORDER BY term",
    ).get();
    await _searchWorker.expand(
      const [],
      0,
      vocabulary: rows.map((r) => r.read<String>('term')).toList(),
    );
    _vocabularyRevision = revision;
  }

  @override
  Future<void> close() async {
    _searchWorker.dispose();
    await super.close();
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
  Future<List<Entity>> search(String query, {int maxTypos = 0}) async {
    if (maxTypos < 0 || maxTypos > 2) {
      throw ArgumentError.value(maxTypos, 'maxTypos', 'Expected 0, 1 or 2');
    }
    final words = searchWords(query);
    if (words.isEmpty) return [];
    final exact = prefixSearchQuery(words);
    List<String>? expansions;
    final results = <Entity>[];
    final rowIds = <int>[];
    // Location is the primary priority; edit distance ranks within each group.
    for (final category in ['note', 'task']) {
      for (final columns in ['title', '{title body}']) {
        Future<void> append(String expression) async {
          final matches = await _searchMatches(
            'category:$category AND $columns:($expression)',
            rowIds,
            100 - results.length,
          );
          for (final row in matches) {
            rowIds.add(row.read<int>('rowid'));
            results.add(
              Entity.fromJson(
                jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
              ),
            );
          }
        }

        await append(exact);
        if (results.length >= 100) return results;
        if (expansions == null) {
          if (words.any((w) => wordTypoLimit(w, maxTypos) > 0)) {
            await _prepareVocabulary();
            try {
              expansions = await _searchWorker.expand(words, maxTypos);
            } catch (_) {
              _vocabularyRevision = -1;
              rethrow;
            }
          } else {
            expansions = const [];
          }
        }
        for (final expansion in expansions) {
          await append(expansion);
          if (results.length >= 100) return results;
        }
      }
    }
    return results;
  }

  Future<List<QueryRow>> _searchMatches(
    String expression,
    List<int> excluded,
    int limit,
  ) => customSelect(
    '''SELECT r.payload, matches.rowid FROM (
        SELECT rowid, rank FROM search_index WHERE search_index MATCH ?
        ${excluded.isEmpty ? '' : 'AND rowid NOT IN (${List.filled(excluded.length, '?').join(',')})'}
        ORDER BY rank LIMIT ?
      ) matches JOIN records r ON r.rowid=matches.rowid
      ORDER BY matches.rank, matches.rowid''',
    variables: [
      Variable(expression),
      ...excluded.map(Variable.new),
      Variable(limit),
    ],
  ).get();

  Future<int> beginActivity(DateTime time) => customInsert(
    'INSERT INTO app_activity(start,end) VALUES (?,?)',
    variables: [
      Variable(time.microsecondsSinceEpoch),
      Variable(time.microsecondsSinceEpoch),
    ],
  );

  Future<void> endActivity(int id, DateTime time) => customStatement(
    'UPDATE app_activity SET end=? WHERE id=? AND end<?',
    [time.microsecondsSinceEpoch, id, time.microsecondsSinceEpoch],
  );

  Future<List<TimeRange>> activity(DateTime start, DateTime end) async =>
      (await customSelect(
            'SELECT start,end FROM app_activity WHERE end>=? AND start<? ORDER BY start',
            variables: [
              Variable(start.microsecondsSinceEpoch),
              Variable(end.microsecondsSinceEpoch),
            ],
          ).get())
          .map(
            (row) => TimeRange(
              DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('start'),
                isUtc: true,
              ),
              DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('end'),
                isUtc: true,
              ),
            ),
          )
          .toList();

  Future<DateTime?> get activityStarted async {
    final row = await customSelect(
      'SELECT min(start) AS first FROM app_activity',
    ).getSingle();
    final value = row.readNullable<int>('first');
    return value == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
  }
}
