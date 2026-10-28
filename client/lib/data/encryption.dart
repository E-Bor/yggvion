import '../l10n/strings.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import '../domain/models.dart';

part 'password.dart';

/// The server receives only keyId, never the root key. Authenticated metadata
/// deliberately excludes server-assigned versions/sequence numbers.
class WorkspaceKey {
  WorkspaceKey(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length != 32) throw FormatException(tr("Неверный ключ"));
  }

  final Uint8List _bytes;
  String get id => digest.sha256.convert(_bytes).toString();

  Future<SecretKey> _derive(String purpose, {List<int> salt = const []}) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(_bytes),
        nonce: salt,
        info: utf8.encode('yggvion/e2ee/v1/$purpose'),
      );
  List<int> _aad(Entity entity, List<String> files) => utf8.encode(
    jsonEncode([
      'yggvion/record/v1',
      id,
      entity.id,
      entity.kind,
      entity.deleted,
      files,
    ]),
  );
  // UUIDv5 occurrence IDs encode dates. Blind private identifiers as well as
  // content so the relay cannot enumerate those dates. Guest inbox identifiers
  // are intentionally public and stay stable when adopting a proposal.
  String wireId(String localId) => localId.startsWith('guest_')
      ? localId
      : digest.Hmac(
          digest.sha256,
          _bytes,
        ).convert(utf8.encode('yggvion/record-id/v1/$localId')).toString();

  Future<Entity> encrypt(Entity entity, Map<String, String> attachments) async {
    final wire = Entity(
      id: wireId(entity.id),
      kind: entity.kind,
      data: const {},
      version: entity.version,
      deleted: entity.deleted,
      seq: entity.seq,
    );
    final files = attachments.values.toSet().toList()..sort();
    final plaintext = utf8.encode(
      jsonEncode({
        'id': entity.id,
        'data': entity.data,
        'attachments': attachments,
      }),
    );
    if (plaintext.length > 2 * 1024 * 1024 - 16) {
      throw StateError(
        tr("Запись слишком большая для синхронизации (максимум 2 МБ)"),
      );
    }
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: await _derive('records'),
      aad: _aad(wire, files),
    );
    return Entity(
      id: wire.id,
      kind: entity.kind,
      version: entity.version,
      deleted: entity.deleted,
      seq: entity.seq,
      data: {
        'e2ee': 1,
        'key_id': id,
        'nonce': base64.encode(box.nonce),
        'box': base64.encode([...box.cipherText, ...box.mac.bytes]),
        'files': files,
      },
    );
  }

  Future<({Entity record, Map<String, String> attachments})> decrypt(
    Entity wire,
  ) async {
    final e = wire.data;
    if (e['e2ee'] != 1 || e['key_id'] != id) {
      throw FormatException(tr("Получена запись без ожидаемого E2EE"));
    }
    final files = (e['files'] as List).cast<String>();
    if ((e['box'] as String).length > 3 * 1024 * 1024 || files.length > 10000) {
      throw FormatException(tr("Слишком большая зашифрованная запись"));
    }
    final bytes = base64.decode(e['box'] as String);
    if (bytes.length < 16) throw FormatException(tr("Повреждена запись"));
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        bytes.sublist(0, bytes.length - 16),
        nonce: base64.decode(e['nonce'] as String),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: await _derive('records'),
      aad: _aad(wire, files),
    );
    final value = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final localId = value['id'] as String;
    if (wireId(localId) != wire.id) {
      throw FormatException(tr("Подменён идентификатор записи"));
    }
    final attachments = Map<String, String>.from(value['attachments'] as Map);
    if (attachments.values.toSet().length != files.length ||
        !files.toSet().containsAll(attachments.values)) {
      throw FormatException(tr("Повреждён список вложений"));
    }
    return (
      record: Entity(
        id: localId,
        kind: wire.kind,
        version: wire.version,
        seq: wire.seq,
        deleted: wire.deleted,
        data: Map<String, dynamic>.from(value['data'] as Map),
      ),
      attachments: attachments,
    );
  }

  // Independent random file keys (HKDF salt) allow counter nonces per file.
  // Every chunk authenticates the complete header and its position. The length
  // authenticates the final chunk, including empty files; truncation is rejected.
  static const chunkSize = 1024 * 1024;
  static final _magic = ascii.encode('YGGFILE1');
  Future<void> encryptFile(
    File source,
    File target,
    String purpose, {
    List<int> prefix = const [],
  }) async {
    final length = await source.length();
    final header = Uint8List(112)..setRange(0, 8, _magic);
    header.setRange(
      8,
      40,
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    ByteData.sublistView(header).setUint64(40, length);
    header.setRange(48, 112, ascii.encode(id));
    final key = await _derive('file/$purpose', salt: header.sublist(8, 40));
    final input = await source.open();
    final output = await target.open(mode: FileMode.write);
    try {
      await output.writeFrom(prefix);
      await output.writeFrom(header);
      var remaining = length, index = 0;
      do {
        final count = min(remaining, chunkSize);
        final bytes = await _readExact(input, count);
        final nonce = Uint8List(12);
        ByteData.sublistView(nonce).setUint64(4, index++);
        final box = await AesGcm.with256bits().encrypt(
          bytes,
          secretKey: key,
          nonce: nonce,
          aad: header,
        );
        await output.writeFrom(box.cipherText);
        await output.writeFrom(box.mac.bytes);
        remaining -= count;
      } while (remaining > 0);
      if ((await input.read(1)).isNotEmpty) {
        throw FormatException(tr("Файл изменился во время копирования"));
      }
      await output.flush();
    } finally {
      await input.close();
      await output.close();
    }
  }

  Future<void> decryptFile(
    File source,
    File target,
    String purpose, {
    int maximumBytes = 300 * 1024 * 1024,
    int offset = 0,
  }) async {
    final input = await source.open();
    RandomAccessFile? output;
    try {
      await input.setPosition(offset);
      final header = await _readExact(input, 112);
      if (ascii.decode(header.sublist(0, 8), allowInvalid: true) !=
          'YGGFILE1') {
        throw FormatException(tr("Неверный формат зашифрованного файла"));
      }
      if (ascii.decode(header.sublist(48, 112)) != id) {
        throw FormatException(tr("Нужен другой ключ восстановления"));
      }
      final length = ByteData.sublistView(header).getUint64(40);
      if (length < 0 || length > maximumBytes) {
        throw FormatException(tr("Превышен размер файла"));
      }
      final key = await _derive('file/$purpose', salt: header.sublist(8, 40));
      output = await target.open(mode: FileMode.write);
      var remaining = length, index = 0;
      do {
        final count = min(remaining, chunkSize);
        final bytes = await _readExact(input, count + 16);
        final nonce = Uint8List(12);
        ByteData.sublistView(nonce).setUint64(4, index++);
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(
            bytes.sublist(0, count),
            nonce: nonce,
            mac: Mac(bytes.sublist(count)),
          ),
          secretKey: key,
          aad: header,
        );
        await output.writeFrom(plain);
        remaining -= count;
      } while (remaining > 0);
      if ((await input.read(1)).isNotEmpty) {
        throw FormatException(tr("Лишние данные в файле"));
      }
      await output.flush();
    } finally {
      await input.close();
      await output?.close();
    }
  }

  static Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
    final bytes = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final read = await file.readInto(bytes, offset, length);
      if (read == 0) throw FormatException(tr("Зашифрованный файл обрезан"));
      offset += read;
    }
    return bytes;
  }
}
