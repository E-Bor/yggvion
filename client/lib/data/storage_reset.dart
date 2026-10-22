import 'dart:io';
import 'package:path/path.dart' as p;

/// Deletes only Yggvion-owned files, after all users of the database stop.
/// A marker completes an interrupted, explicitly confirmed reset on next launch.
class StorageReset {
  static const markerName = '.storage-reset-pending';
  static const ownedNames = [
    'yggvion.sqlite',
    'yggvion.sqlite-wal',
    'yggvion.sqlite-shm',
    'yggvion.sqlite-journal',
    'attachments',
    'backups',
    'local-ai',
    'ai-recordings',
  ];

  static Future<void> _checkRoot(Directory root) async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Папка хранилища не должна быть ссылкой',
        root.path,
      );
    }
    final marker = p.join(root.path, markerName);
    final markerType = await FileSystemEntity.type(marker, followLinks: false);
    if (markerType != FileSystemEntityType.file &&
        markerType != FileSystemEntityType.notFound) {
      throw FileSystemException('Некорректный маркер очистки', marker);
    }
  }

  static Future<void> clear(Directory root) async {
    await _checkRoot(root);
    await root.create(recursive: true);
    await File(
      p.join(root.path, markerName),
    ).writeAsString('User confirmed local storage deletion.\n', flush: true);
    await finishPending(root);
  }

  static Future<void> finishPending(Directory root) async {
    await _checkRoot(root);
    final marker = File(p.join(root.path, markerName));
    if (!await marker.exists()) return;
    for (final name in ownedNames) {
      final path = p.join(root.path, name);
      switch (await FileSystemEntity.type(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.file:
          await File(path).delete();
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          throw FileSystemException('Не удалось удалить файл хранилища', path);
      }
    }
    await marker.delete();
  }
}
