import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rrule/rrule.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import 'repository.dart';

const _maximumSnapshot = 512 * 1024 * 1024;
const _maximumArchive = 100 * 1024 * 1024 * 1024;
final _attachmentReference = RegExp(r'attachment:([a-f0-9]{64})');
final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
const _preferences = {
  'calendar_view',
  'planner_view',
  'sidebar_collapsed',
  'home_calendar_fraction',
  'home_scratchpad_fraction',
  'last_calendar_task',
};

class LocalBackupEntry {
  const LocalBackupEntry(this.path, this.created, this.bytes);
  final String path;
  final DateTime created;
  final int bytes;
}

/// Local, portable snapshots. No network credentials or device paths are exported.
/// The ZIP container is deliberately unencrypted; UI labels this explicitly.
class LocalBackupService {
  LocalBackupService(this.repo, {this.directory, this.beforeRestore});
  final Repository repo;
  final Directory? directory;
  final Future<void> Function()? beforeRestore;
  bool busy = false;

  Future<Directory> folder() async {
    final root =
        directory ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'backups'),
        );
    await root.create(recursive: true);
    return root;
  }

  Future<List<LocalBackupEntry>> list() async {
    final root = await folder();
    final result = <LocalBackupEntry>[];
    await for (final item in root.list(followLinks: false)) {
      if (item is File && item.path.endsWith('.ygglocal')) {
        final stat = await item.stat();
        result.add(LocalBackupEntry(item.path, stat.modified, stat.size));
      }
    }
    result.sort((a, b) => b.created.compareTo(a.created));
    return result;
  }

  Future<Map<String, dynamic>> _snapshot() => repo.serial(
    () => repo.db.transaction(() async {
      final records = await repo.db.entities(includeDeleted: true);
      final files = await repo.db.customSelect('SELECT * FROM files').get();
      final conflicts = await repo.db
          .customSelect('SELECT * FROM conflicts')
          .get();
      final metadata = await repo.db
          .customSelect('SELECT * FROM metadata')
          .get();
      final activity = await repo.db
          .customSelect('SELECT start,end FROM app_activity')
          .get();
      return <String, dynamic>{
        'format': 1,
        'created': repo.now().toUtc().toIso8601String(),
        'records': records.map((e) => e.toJson()).toList(),
        'files': files.map((r) => Map<String, dynamic>.from(r.data)).toList(),
        'conflicts': conflicts
            .map((r) => Map<String, dynamic>.from(r.data))
            .toList(),
        'preferences': {
          for (final r in metadata)
            if (_preferences.contains(r.read<String>('key')))
              r.read<String>('key'): r.read<String>('value'),
        },
        'activity': activity
            .map((r) => Map<String, dynamic>.from(r.data))
            .toList(),
      };
    }),
  );

  Future<LocalBackupEntry> create() async {
    if (busy) throw StateError('Резервное копирование уже выполняется');
    busy = true;
    try {
      return await _create();
    } finally {
      busy = false;
    }
  }

  Future<LocalBackupEntry> _create() async {
    final root = await folder();
    final data = await _snapshot();
    final target = p.join(
      root.path,
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-${repo.newId()}.ygglocal',
    );
    await _writeInBackground(data, target);
    return LocalBackupEntry(
      target,
      DateTime.parse(data['created'] as String),
      await File(target).length(),
    );
  }

  Future<void> restore(String source) async {
    if (busy) throw StateError('Резервное копирование уже выполняется');
    busy = true;
    Directory? stage;
    try {
      final root = await folder();
      stage = await root.createTemp('.restore-');
      final stagePath = stage.path;
      // Validation completes before any live database or connection is changed.
      final data = await _readInBackground(source, stagePath);
      await _create(); // A full local safety copy, including current attachments.
      if (beforeRestore != null) await beforeRestore!();
      final attachmentRoot = Directory(p.join(root.parent.path, 'attachments'));
      await attachmentRoot.create(recursive: true);
      final restoredFiles = <Map<String, dynamic>>[];
      for (final raw in data['files'] as List) {
        final file = Map<String, dynamic>.from(raw as Map);
        final id = file['id'] as String;
        final extension = p.extension(file['name'] as String).toLowerCase();
        final suffix = RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension)
            ? extension
            : '';
        final target = p.join(attachmentRoot.path, '$id$suffix');
        // Content-addressed verified bytes may safely replace an existing cache.
        await File(p.join(stagePath, id)).copy(target);
        restoredFiles.add({...file, 'path': target});
      }
      await repo.serial(() async {
        await repo.db.transaction(() async {
          for (final table in ['outbox', 'records', 'conflicts', 'files']) {
            await repo.db.customStatement('DELETE FROM $table');
          }
          await repo.db.clearSearchIndex();
          await repo.db.customStatement(
            "DELETE FROM metadata WHERE key IN ('server_url','server_generation','sync_cursor')",
          );
          var ordinal = 0;
          final created = DateTime.parse(data['created'] as String);
          for (final raw in data['records'] as List) {
            var record = Entity.fromJson(
              Map<String, dynamic>.from(raw as Map),
            ).withVersion(0);
            if (record.kind == 'session' && record.data['end'] == null) {
              final start = parseTime(record.data['start']);
              record = record.change({
                'end': wireTime(
                  created.isAfter(start)
                      ? created
                      : start.add(const Duration(microseconds: 1)),
                ),
              });
            }
            await repo.db.put(record);
            await repo.db.customStatement(
              'INSERT INTO outbox VALUES(?,?,?,?)',
              [record.id, repo.newId(), record.encoded, ++ordinal],
            );
          }
          for (final file in restoredFiles) {
            await repo.db.customStatement('INSERT INTO files VALUES(?,?,?,0)', [
              file['id'],
              file['name'],
              file['path'],
            ]);
          }
          for (final raw in data['conflicts'] as List) {
            final row = raw as Map;
            await repo.db.customStatement(
              'INSERT INTO conflicts VALUES(?,?,?)',
              [row['id'], row['local'], row['remote']],
            );
          }
          for (final key in _preferences) {
            await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
              key,
            ]);
          }
          for (final entry in (data['preferences'] as Map).entries) {
            if (_preferences.contains(entry.key)) {
              await repo.db.setMeta(entry.key as String, entry.value as String);
            }
          }
          // Keep local usage history already on this device. Imported intervals
          // are inserted only if absent; no running activity row is invalidated.
          for (final raw in data['activity'] as List) {
            final row = raw as Map;
            await repo.db.customStatement(
              'INSERT INTO app_activity(start,end) SELECT ?,? WHERE NOT EXISTS (SELECT 1 FROM app_activity WHERE start=? AND end=?)',
              [row['start'], row['end'], row['start'], row['end']],
            );
          }
          await repo.db.setMeta('ordinal', '$ordinal');
        });
        await repo.reload();
      });
      await repo.initialize(timezone: repo.snapshot.settings.timezone);
      repo.syncStatus = 'Локально';
      repo.syncError = null;
      repo.publish();
    } finally {
      try {
        if (stage != null && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } finally {
        busy = false;
      }
    }
  }
}

Future<void> _writeArchive(Map<String, dynamic> data, String target) async {
  final sources = (data['files'] as List)
      .map((r) => Map<String, dynamic>.from(r as Map))
      .toList();
  final ids = sources.map((r) => r['id']).toSet();
  for (final record in _attachmentRecords(data)) {
    for (final match in _attachmentReference.allMatches(jsonEncode(record))) {
      if (!ids.contains(match[1])) {
        throw StateError(
          'Не все вложения загружены на устройство. Откройте синхронизацию и повторите создание копии.',
        );
      }
    }
  }
  final fileMetadata = <Map<String, dynamic>>[];
  var total = 0;
  for (final item in sources) {
    final file = File(item['path'] as String);
    final size = await file.length();
    total += size;
    if (size > 300 * 1024 * 1024 || total > _maximumArchive) {
      throw StateError('Превышен размер резервной копии');
    }
    if ((await sha256.bind(file.openRead()).first).toString() != item['id']) {
      throw StateError('Повреждено вложение ${item['name']}');
    }
    fileMetadata.add({'id': item['id'], 'name': item['name'], 'size': size});
  }
  data['files'] = fileMetadata;
  final bytes = utf8.encode(jsonEncode(data));
  if (bytes.length > _maximumSnapshot) {
    throw StateError('Слишком большой снимок данных');
  }
  final encoder = ZipFileEncoder();
  final temporary = '$target.part';
  var closed = false;
  try {
    encoder.create(temporary, level: 0);
    encoder.addArchiveFile(
      ArchiveFile.noCompress('snapshot.json', bytes.length, bytes),
    );
    final digest = utf8.encode(sha256.convert(bytes).toString());
    encoder.addArchiveFile(
      ArchiveFile.noCompress('snapshot.sha256', digest.length, digest),
    );
    for (final file in sources) {
      final stream = InputFileStream(file['path'] as String);
      try {
        encoder.addArchiveFile(
          ArchiveFile.stream('attachments/${file['id']}', stream)
            ..compression = CompressionType.none,
        );
      } finally {
        await stream.close();
      }
    }
    await encoder.close();
    closed = true;
    await File(temporary).rename(target);
  } finally {
    if (!closed) await encoder.close();
    if (await File(temporary).exists()) await File(temporary).delete();
  }
}

Future<Map<String, dynamic>> _readArchive(String source, String stage) async {
  tzdata.initializeTimeZones();
  if (await File(source).length() > _maximumArchive + _maximumSnapshot) {
    throw const FormatException('Слишком большой архив');
  }
  final input = InputFileStream(source);
  try {
    final directory = ZipDirectory()..read(input);
    final names = <String>{};
    var total = 0;
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      if (!names.add(name) ||
          header.compressionMethod != 0 ||
          header.file?.compressionMethod != CompressionType.none ||
          header.uncompressedSize != header.compressedSize ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          !(name == 'snapshot.json' ||
              name == 'snapshot.sha256' ||
              RegExp(r'^attachments/[a-f0-9]{64}$').hasMatch(name))) {
        throw const FormatException('Некорректная структура локального бэкапа');
      }
      final limit = name == 'snapshot.json'
          ? _maximumSnapshot
          : name == 'snapshot.sha256'
          ? 64
          : 300 * 1024 * 1024;
      if (header.uncompressedSize < 0 || header.uncompressedSize > limit) {
        throw const FormatException('Некорректный размер файла');
      }
      total += header.uncompressedSize;
      if (total > _maximumArchive + _maximumSnapshot) {
        throw const FormatException('Превышен размер архива');
      }
    }
    if (!names.containsAll(['snapshot.json', 'snapshot.sha256'])) {
      throw const FormatException('Это не локальная копия Yggvion');
    }
    ArchiveFile entry(String name) {
      final h = directory.fileHeaders.singleWhere((h) => h.filename == name);
      return ArchiveFile.file(name, h.uncompressedSize, h.file!);
    }

    final bytes = entry('snapshot.json').readBytes()!;
    final checksum = utf8.decode(entry('snapshot.sha256').readBytes()!);
    if (sha256.convert(bytes).toString() != checksum) {
      throw const FormatException(
        'Контрольная сумма заметок и событий не совпадает',
      );
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    _validateSnapshot(data);
    final expected = <String>{'snapshot.json', 'snapshot.sha256'};
    for (final raw in data['files'] as List) {
      final file = raw as Map;
      final id = file['id'] as String;
      final name = 'attachments/$id';
      if (!expected.add(name) || !names.contains(name)) {
        throw const FormatException('Отсутствующее или повторное вложение');
      }
      final archived = entry(name);
      if (archived.size != file['size']) {
        throw const FormatException('Размер вложения не совпадает');
      }
      final path = p.join(stage, id);
      final output = OutputFileStream(path);
      try {
        archived.writeContent(output);
      } finally {
        await output.close();
      }
      if (await File(path).length() != file['size'] ||
          (await sha256.bind(File(path).openRead()).first).toString() != id) {
        throw const FormatException('Контрольная сумма вложения не совпадает');
      }
    }
    if (expected.length != names.length) {
      throw const FormatException('Лишние файлы в архиве');
    }
    final fileIds = (data['files'] as List)
        .map((f) => (f as Map)['id'])
        .toSet();
    for (final record in _attachmentRecords(data)) {
      for (final match in _attachmentReference.allMatches(jsonEncode(record))) {
        if (!fileIds.contains(match[1])) {
          throw const FormatException('Неполная копия вложений');
        }
      }
    }
    return data;
  } finally {
    await input.close();
  }
}

void _validateSnapshot(Map<String, dynamic> data) {
  if (data['format'] != 1 ||
      data['records'] is! List ||
      data['files'] is! List ||
      data['conflicts'] is! List ||
      data['preferences'] is! Map ||
      data['activity'] is! List) {
    throw const FormatException('Неподдерживаемый формат локальной копии');
  }
  final created = DateTime.tryParse(data['created'] as String? ?? '');
  if (created == null ||
      created.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
    throw const FormatException('Некорректная дата снимка');
  }
  final ids = <String>{};
  final entities = <Entity>[];
  const kinds = {
    'task',
    'block',
    'session',
    'note',
    'note_folder',
    'project',
    'settings',
    'series',
    'snooze',
  };
  for (final raw in data['records'] as List) {
    final e = Entity.fromJson(Map<String, dynamic>.from(raw as Map));
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(e.id) ||
        !ids.add(e.id) ||
        !kinds.contains(e.kind)) {
      throw const FormatException('Некорректные записи');
    }
    entities.add(e);
    if (utf8.encode(e.encoded).length > 2 * 1024 * 1024) {
      throw const FormatException('Слишком большая запись');
    }
    _validateEntity(e);
  }
  for (final id in ['settings', 'scratchpad', 'reference']) {
    if (!entities.any(
      (e) =>
          e.id == id &&
          !e.deleted &&
          e.kind == (id == 'settings' ? 'settings' : 'note'),
    )) {
      throw const FormatException('Отсутствуют основные записи');
    }
  }
  for (final f in data['files'] as List) {
    if (f is! Map ||
        f['id'] is! String ||
        !_hashPattern.hasMatch(f['id'] as String) ||
        f['name'] is! String ||
        f['size'] is! int ||
        (f['size'] as int) < 0) {
      throw const FormatException('Некорректное вложение');
    }
  }
  final conflictIds = <String>{};
  for (final row in data['conflicts'] as List) {
    if (row is! Map ||
        row['id'] is! String ||
        !ids.contains(row['id']) ||
        !conflictIds.add(row['id'] as String) ||
        row['local'] is! String ||
        row['remote'] is! String) {
      throw const FormatException('Некорректный конфликт');
    }
    for (final key in ['local', 'remote']) {
      final e = Entity.fromJson(
        jsonDecode(row[key] as String) as Map<String, dynamic>,
      );
      if (e.id != row['id'] || !kinds.contains(e.kind)) {
        throw const FormatException('Некорректный конфликт');
      }
      _validateEntity(e);
    }
  }
  for (final entry in (data['preferences'] as Map).entries) {
    if (!_preferences.contains(entry.key) || entry.value is! String) {
      throw const FormatException('Некорректные настройки');
    }
  }
  for (final row in data['activity'] as List) {
    if (row is! Map ||
        row['start'] is! int ||
        row['end'] is! int ||
        (row['end'] as int) < (row['start'] as int)) {
      throw const FormatException('Некорректная статистика');
    }
  }
}

// Validate fields the client consumes before replacing the live database.
// Server authorization and business validation still run when reconnecting.
void _validateEntity(Entity e) {
  void check(bool valid) {
    if (!valid) throw FormatException('Некорректная запись ${e.kind}');
  }

  void reminders(List<int> values) {
    check(values.every((v) => v >= 0));
  }

  try {
    switch (e.kind) {
      case 'note':
        final n = Note(e);
        n.title;
        n.content;
        n.folderId;
        n.sortOrder;
        n.pinned;
      case 'note_folder':
        final n = NoteFolder(e);
        n.title;
        n.sortOrder;
      case 'task':
        final t = Task(e);
        t.title;
        t.description;
        t.status;
        t.projectId;
        t.parentId;
        t.seriesId;
        t.occurrence;
        t.isBirthday;
      case 'block':
        final b = TimeBlock(e);
        if (!b.end.isAfter(b.start)) {
          throw const FormatException('Некорректный интервал');
        }
        tz.getLocation(b.timezone);
        b.taskId;
        b.allDay;
        b.historical;
        reminders(b.reminders);
        b.reminderAt;
      case 'session':
        final s = WorkSession(e);
        s.start;
        s.end;
        s.deviceId;
        s.taskId;
        s.discarded;
        check(s.end == null || !s.end!.isBefore(s.start));
      case 'project':
        final v = Project(e);
        v.title;
        v.color;
      case 'settings':
        final v = AppSettings(e);
        check(v.defaultMinutes >= 5 && v.defaultMinutes <= 1440);
        reminders(v.reminders);
        tz.getLocation(v.timezone);
        v.accentColor;
        v.searchTypos;
      case 'series':
        e.data['title'] as String;
        e.data['description'] as String?;
        parseTime(e.data['start']);
        tz.getLocation(e.data['timezone'] as String);
        final anchor = e.data['anchor_timezone'] as String?;
        if (anchor != null && anchor.isNotEmpty) tz.getLocation(anchor);
        final rule = e.data['rule'] as String;
        RecurrenceRule.fromString(
          rule.startsWith('RRULE:') ? rule : 'RRULE:$rule',
        );
        check((e.data['minutes'] as int) > 0);
        e.data['day_span'] as int?;
        e.data['offset_minutes'] as int?;
        e.data['all_day'] as bool?;
        reminders((e.data['reminders'] as List? ?? []).cast<int>());
        for (final instant in e.data['exceptions'] as List? ?? []) {
          parseTime(instant);
        }
        if (e.data['cancelled_from'] != null) {
          parseTime(e.data['cancelled_from']);
        }
        final birthday = e.data['birthday_date'] as String?;
        if (birthday != null && birthday.isNotEmpty) DateTime.parse(birthday);
      case 'snooze':
        e.data['task_id'] as String;
        parseTime(e.data['at']);
    }
  } on Object catch (error) {
    throw FormatException('Некорректная запись ${e.kind}: $error');
  }
}

Iterable<Object?> _attachmentRecords(Map<String, dynamic> data) sync* {
  for (final record in data['records'] as List) {
    if ((record as Map)['deleted'] != true) yield record;
  }
  for (final conflict in data['conflicts'] as List) {
    for (final key in ['local', 'remote']) {
      yield jsonDecode((conflict as Map)[key] as String);
    }
  }
}

// Top-level closures capture only transferable arguments, never a Repository.
Future<void> _writeInBackground(Map<String, dynamic> data, String target) =>
    Isolate.run(() => _writeArchive(data, target));
Future<Map<String, dynamic>> _readInBackground(String source, String stage) =>
    Isolate.run(() => _readArchive(source, stage));
