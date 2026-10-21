import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/local_backup.dart';
import 'package:yggvion/data/repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  late Directory dir;
  late Repository repo;
  late LocalBackupService backups;
  var disconnects = 0;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yggvion-local-backup-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    repo = Repository(LocalDatabase(NativeDatabase.memory()));
    await repo.initialize();
    disconnects = 0;
    backups = LocalBackupService(
      repo,
      directory: Directory('${dir.path}/backups'),
      beforeRestore: () async {
        disconnects++;
      },
    );
  });
  tearDown(() async {
    await repo.db.close();
    repo.dispose();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'offline backup round trip includes titles folders links files and preferences',
    () async {
      await repo.saveNoteFolder('Work');
      final folder = repo.snapshot.noteFolders.single;
      final note = await repo.createNote(folderId: folder.id);
      final file = File('${dir.path}/example.bin');
      await file.writeAsBytes(List.generate(1024 * 1024, (i) => i % 251));
      final attachment = await repo.attachFile(file.path);
      await repo.saveNote(note.id, 'Named note', '# Heading\n\n$attachment');
      await repo.createTask(
        'Linked task',
        description: '[note](note:${note.id})',
      );
      await repo.db.setMeta('server_url', 'https://192.0.2.123');
      await repo.db.setMeta('calendar_view', 'week');
      final saved = await backups.create();
      final stream = InputFileStream(saved.path);
      final archive = ZipDecoder().decodeStream(stream);
      final json = utf8.decode(archive.findFile('snapshot.json')!.readBytes()!);
      expect(json, isNot(contains('192.0.2.123')));
      expect(json, isNot(contains(dir.path)));
      await stream.close();
      await repo.saveNote(note.id, 'Changed', 'later');
      await repo.deleteNoteFolder(folder);
      await backups.restore(saved.path);
      expect(disconnects, 1);
      expect(repo.snapshot.note(note.id)!.title, 'Named note');
      expect(repo.snapshot.note(note.id)!.folderId, folder.id);
      expect(repo.snapshot.noteFolders.single.title, 'Work');
      expect(repo.snapshot.tasks.single.description, '[note](note:${note.id})');
      expect(repo.calendarView.name, 'week');
      expect(await repo.db.meta('server_url'), isNull);
      expect(
        await backups.list(),
        hasLength(2),
      ); // Includes pre-restore safety copy.
      expect(
        (await repo.db.customSelect('SELECT * FROM outbox').get()).length,
        repo.snapshot.entities.length,
      );
      final files = await repo.db.customSelect('SELECT * FROM files').get();
      expect(
        await File(files.single.read<String>('path')).readAsBytes(),
        await file.readAsBytes(),
      );
      expect(files.single.read<int>('uploaded'), 0);
    },
  );
  test(
    'corrupt snapshot attachment or unexpected paths never change live data',
    () async {
      final file = File('${dir.path}/file.bin');
      await file.writeAsBytes([1, 2, 3, 4]);
      final note = await repo.createNote();
      await repo.saveNote(note.id, 'Keep', await repo.attachFile(file.path));
      final saved = await backups.create();
      for (final corruption in [
        'snapshot',
        'attachment',
        'path',
        'duplicate',
        'truncated',
        'invalid-fields',
      ]) {
        final input = InputFileStream(saved.path);
        final original = ZipDecoder().decodeStream(input);
        final path = '${dir.path}/$corruption.ygglocal';
        final encoder = ZipFileEncoder()..create(path, level: 0);
        List<int>? alteredSnapshot;
        if (corruption == 'invalid-fields') {
          final data =
              jsonDecode(
                    utf8.decode(
                      original.findFile('snapshot.json')!.readBytes()!,
                    ),
                  )
                  as Map;
          final settings = (data['records'] as List).cast<Map>().singleWhere(
            (r) => r['kind'] == 'settings',
          );
          (settings['data'] as Map)['timezone'] = 'Invalid/Unknown';
          alteredSnapshot = utf8.encode(jsonEncode(data));
        }
        for (final entry in original) {
          var bytes = List<int>.from(entry.readBytes()!);
          if (alteredSnapshot != null) {
            if (entry.name == 'snapshot.json') bytes = alteredSnapshot;
            if (entry.name == 'snapshot.sha256') {
              bytes = utf8.encode(sha256.convert(alteredSnapshot).toString());
            }
          }
          if ((corruption == 'snapshot' && entry.name == 'snapshot.json') ||
              (corruption == 'attachment' &&
                  entry.name.startsWith('attachments/'))) {
            bytes[bytes.length - 1] ^= 1;
          }
          encoder.addArchiveFile(
            ArchiveFile.noCompress(entry.name, bytes.length, bytes),
          );
        }
        if (corruption == 'path') {
          encoder.addArchiveFile(ArchiveFile.noCompress('../escape', 1, [1]));
        }
        if (corruption == 'duplicate') {
          encoder.addArchiveFile(
            ArchiveFile.noCompress('snapshot.sha256', 64, List.filled(64, 97)),
          );
        }
        await encoder.close();
        await input.close();
        if (corruption == 'truncated') {
          final f = await File(path).open(mode: FileMode.append);
          await f.truncate(80);
          await f.close();
        }
        await expectLater(
          backups.restore(path),
          throwsA(
            anyOf(
              isA<FormatException>(),
              isA<ArchiveException>(),
              isA<RangeError>(),
            ),
          ),
          reason: corruption,
        );
        expect(repo.snapshot.note(note.id)!.title, 'Keep');
        expect(disconnects, 0);
        expect(await backups.list(), hasLength(1));
      }
    },
  );
  test(
    'missing attachment prevents successful backup and removes partial files',
    () async {
      final note = await repo.createNote();
      await repo.saveNote(
        note.id,
        'Missing',
        '[file](attachment:${sha256.convert([7])})',
      );
      await expectLater(backups.create(), throwsStateError);
      expect(await backups.list(), isEmpty);
      expect(backups.busy, isFalse);
    },
  );
}
