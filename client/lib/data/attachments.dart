import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import '../domain/models.dart';
import 'repository.dart';

final attachmentReference = RegExp(r'attachment:([a-f0-9]{64})');

class AttachmentEntry {
  const AttachmentEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.references,
    required this.uploaded,
    this.path,
    this.addedAt,
  });
  final String id, name;
  final int size, references;
  final bool uploaded;
  final String? path;
  final DateTime? addedAt;
  bool get unused => references == 0;
  bool get image =>
      RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(name);
}

extension RepositoryAttachments on Repository {
  Future<Map<String, Set<String>>> attachmentReferences() async {
    final references = <String, Set<String>>{};
    void collect(Entity record) {
      if (record.deleted || record.kind == 'attachment') return;
      for (final match in attachmentReference.allMatches(
        jsonEncode(record.data),
      )) {
        references.putIfAbsent(match[1]!, () => {}).add(record.id);
      }
    }

    for (final record in await db.entities()) {
      collect(record);
    }
    // An unresolved version must not lose the files needed for recovery.
    for (final row
        in await db.customSelect('SELECT local,remote FROM conflicts').get()) {
      for (final side in ['local', 'remote']) {
        collect(
          Entity.fromJson(
            jsonDecode(row.read<String>(side)) as Map<String, dynamic>,
          ),
        );
      }
    }
    return references;
  }

  Future<void> ensureAttachmentCatalog({
    String? reattachedId,
  }) => commitComputed(() async {
    Map<String, Set<String>>? references;
    final changes = <Entity>[];
    for (final row
        in await db
            .customSelect(
              "SELECT f.*,r.payload AS record FROM files f LEFT JOIN records r ON r.id='attachment-'||f.id WHERE r.id IS NULL OR r.deleted=1 ORDER BY f.rowid",
            )
            .get()) {
      final id = row.read<String>('id');
      final payload = row.readNullable<String>('record');
      final old = payload == null
          ? null
          : Entity.fromJson(jsonDecode(payload) as Map<String, dynamic>);
      if (old != null && reattachedId != id) {
        references ??= await attachmentReferences();
        if (references[id]?.isNotEmpty != true) continue;
      }
      final file = File(row.read<String>('path'));
      if (!await file.exists()) continue;
      final name = row.read<String>('name');
      changes.add(
        Entity(
          id: 'attachment-$id',
          kind: 'attachment',
          version: old?.version ?? 0,
          data: {
            'file_id': id,
            'title': name,
            'size': await file.length(),
            'added_at': (await file.stat()).modified.toUtc().toIso8601String(),
            'content': 'attachment:$id',
          },
        ),
      );
    }
    return changes;
  });

  Future<List<AttachmentEntry>> attachmentInventory() async {
    await ensureAttachmentCatalog();
    final references = await attachmentReferences();
    final files = {
      for (final row in await db.customSelect('SELECT * FROM files').get())
        row.read<String>('id'): row,
    };
    final entries = <AttachmentEntry>[];
    for (final record in await db.entities()) {
      if (record.kind != 'attachment') continue;
      final id = record.data['file_id'] as String;
      final file = files[id];
      entries.add(
        AttachmentEntry(
          id: id,
          name: record.data['title'] as String,
          size: record.data['size'] as int,
          addedAt: DateTime.tryParse(record.data['added_at'] as String? ?? ''),
          references: references[id]?.length ?? 0,
          uploaded: file?.read<int>('uploaded') == 1,
          path: file?.read<String>('path'),
        ),
      );
    }
    entries.sort((a, b) {
      final dates = (b.addedAt ?? DateTime(1970)).compareTo(
        a.addedAt ?? DateTime(1970),
      );
      return dates != 0 ? dates : a.name.compareTo(b.name);
    });
    return entries;
  }

  Future<bool> removeLocalUnusedAttachment(String id) => serial(() async {
    if ((await attachmentReferences())[id]?.isNotEmpty == true) return false;
    final path = await attachmentPath(id);
    if (path != null && await File(path).exists()) await File(path).delete();
    await db.customStatement('DELETE FROM files WHERE id=?', [id]);
    await db.customStatement('DELETE FROM encrypted_files WHERE id=?', [id]);
    return true;
  });

  Future<void> purgeDeletedAttachments() async {
    for (final row
        in await db
            .customSelect(
              "SELECT r.payload FROM records r JOIN files f ON r.id='attachment-'||f.id WHERE r.kind='attachment' AND r.deleted=1",
            )
            .get()) {
      final record = Entity.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      final pending = await db
          .customSelect(
            'SELECT id FROM outbox WHERE id=?',
            variables: [Variable(record.id)],
          )
          .get();
      if (pending.isEmpty) {
        await removeLocalUnusedAttachment(record.data['file_id'] as String);
      }
    }
  }
}
