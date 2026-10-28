import '../l10n/strings.dart';
import 'dart:async';
import 'dart:io';
import 'package:super_clipboard/super_clipboard.dart';
import 'repository.dart';

class ClipboardPaste {
  const ClipboardPaste(this.text, {this.hasAttachments = false});
  final String text;
  final bool hasAttachments;
}

/// Reads only after an explicit paste action. File URLs take precedence over
/// text so copying a document attaches its contents instead of its local path.
class AttachmentClipboard {
  AttachmentClipboard(
    this.repository, {
    Future<ClipboardReader> Function()? reader,
  }) : _reader = reader ?? _systemReader;
  final Repository repository;
  final Future<ClipboardReader> Function() _reader;

  static Future<ClipboardReader> _systemReader() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      throw UnsupportedError(tr("Буфер обмена недоступен на этом устройстве"));
    }
    return clipboard.read();
  }

  static const _extensions = {
    Formats.png: 'png',
    Formats.jpeg: 'jpg',
    Formats.gif: 'gif',
    Formats.webp: 'webp',
    Formats.tiff: 'tiff',
    Formats.bmp: 'bmp',
    Formats.ico: 'ico',
    Formats.svg: 'svg',
    Formats.heic: 'heic',
    Formats.heif: 'heif',
    Formats.pdf: 'pdf',
    Formats.doc: 'doc',
    Formats.docx: 'docx',
    Formats.xls: 'xls',
    Formats.xlsx: 'xlsx',
    Formats.ppt: 'ppt',
    Formats.pptx: 'pptx',
    Formats.mp4: 'mp4',
    Formats.mov: 'mov',
    Formats.m4v: 'm4v',
    Formats.avi: 'avi',
    Formats.mpeg: 'mpeg',
    Formats.webm: 'webm',
    Formats.ogg: 'ogg',
    Formats.wmv: 'wmv',
    Formats.flv: 'flv',
    Formats.mkv: 'mkv',
    Formats.ts: 'ts',
    Formats.mp3: 'mp3',
    Formats.oga: 'oga',
    Formats.aac: 'aac',
    Formats.wav: 'wav',
    Formats.zip: 'zip',
    Formats.tar: 'tar',
    Formats.gzip: 'gz',
    Formats.bzip2: 'bz2',
    Formats.xz: 'xz',
    Formats.rar: 'rar',
    Formats.jar: 'jar',
    Formats.sevenZip: '7z',
    Formats.dmg: 'dmg',
    Formats.iso: 'iso',
    Formats.deb: 'deb',
    Formats.rpm: 'rpm',
    Formats.apk: 'apk',
    Formats.exe: 'exe',
    Formats.msi: 'msi',
    Formats.dll: 'dll',
    Formats.plainTextFile: 'txt',
    Formats.htmlFile: 'html',
    Formats.rtf: 'rtf',
    Formats.json: 'json',
    Formats.csv: 'csv',
  };

  Future<ClipboardPaste?> read() async {
    final reader = await _reader();
    final parts = <String>[];
    var attachments = false;
    for (final item in reader.items) {
      final formats = item
          .getFormats(Formats.standardFormats)
          .whereType<FileFormat>()
          .toList();
      // Native providers can grant temporary access to otherwise inaccessible
      // files (e.g. iOS Files), including files with unknown extensions.
      final virtual = await item.getVirtualFileReceiver();
      if (virtual != null) {
        final attached = await _file(item, null, await item.getSuggestedName());
        if (attached == null) {
          throw StateError(tr("Не удалось прочитать файл из буфера обмена"));
        }
        parts.add(attached);
        attachments = true;
        continue;
      }
      final uri = await item.readValue(Formats.fileUri);
      if (uri != null && uri.scheme == 'file') {
        try {
          parts.add(await repository.attachFile(uri.toFilePath()));
        } on FileSystemException {
          // Prefer the provider's bytes if its file URL is outside our sandbox.
          final binary = formats
              .where(
                (f) =>
                    f != Formats.plainTextFile &&
                    f != Formats.htmlFile &&
                    f != Formats.rtf,
              )
              .firstOrNull;
          if (binary == null) rethrow;
          final attached = await _file(item, binary, uri.pathSegments.last);
          if (attached == null) rethrow;
          parts.add(attached);
        }
        attachments = true;
        continue;
      }
      final image = [
        Formats.png,
        Formats.jpeg,
        Formats.gif,
        Formats.webp,
        Formats.tiff,
        Formats.bmp,
        Formats.heic,
        Formats.heif,
        Formats.svg,
        Formats.ico,
      ].where(formats.contains).firstOrNull;
      final text = image == null
          ? await item.readValue(Formats.plainText)
          : null;
      if (text != null) {
        parts.add(text);
        continue;
      }
      final link = image == null && formats.isEmpty
          ? await item.readValue(Formats.uri)
          : null;
      if (link != null) {
        parts.add(link.uri.toString());
        continue;
      }
      final format = image ?? formats.firstOrNull;
      final suggested = await item.getSuggestedName();
      // Private clipboard metadata is not itself an attachment. Actual files
      // with unknown extensions are exposed as file URLs or native files above.
      if (format == null && suggested == null) continue;
      final attached = await _file(item, format, suggested);
      if (attached != null) {
        parts.add(attached);
        attachments = true;
      }
    }
    if (parts.isEmpty) return null;
    return ClipboardPaste(parts.join('\n\n'), hasAttachments: attachments);
  }

  Future<String?> _file(
    ClipboardDataReader item,
    FileFormat? format,
    String? name,
  ) {
    final result = Completer<String?>();
    final progress = item.getFile(
      format,
      (file) async {
        try {
          if (file.fileSize != null &&
              file.fileSize! > Repository.maxAttachmentBytes) {
            throw ArgumentError(Repository.attachmentSizeError);
          }
          var filename =
              file.fileName ??
              name ??
              tr("Вложение.{0}", [_extensions[format] ?? 'bin']);
          // A synthesized PNG must not retain a TIFF extension from the source.
          if (format == Formats.png &&
              !filename.toLowerCase().endsWith('.png')) {
            filename = '$filename.png';
          }
          final stream = file.getStream();
          result.complete(await repository.attachStream(stream, filename));
        } catch (error, stack) {
          result.completeError(error, stack);
        } finally {
          file.close();
        }
      },
      onError: result.completeError,
      synthesizeFilesFromURIs: false,
    );
    if (progress == null) result.complete(null);
    return result.future;
  }
}
