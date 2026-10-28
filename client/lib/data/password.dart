part of 'encryption.dart';

class PasswordRequired implements Exception {
  const PasswordRequired();
  @override
  String toString() => tr("Введите пароль шифрования");
}

/// Public KDF parameters for direct password-derived encryption.
/// The password is remembered only in the device's local profile.
class PasswordConfig {
  PasswordConfig._(Map<String, dynamic> value)
    : value = Map.unmodifiable(value);
  final Map<String, dynamic> value;
  String get keyId => value['key_id'] as String;
  String get encoded => jsonEncode(value);
  static String storageKey(String id) => 'password_config_$id';

  factory PasswordConfig.fromJson(Map<String, dynamic> v) {
    const fields = {
      'v',
      'key_id',
      'kdf',
      'memory',
      'iterations',
      'parallelism',
      'salt',
    };
    if (v.length != fields.length ||
        !fields.containsAll(v.keys) ||
        v['v'] != 2 ||
        v['kdf'] != 'argon2id' ||
        v['memory'] != 19456 ||
        v['iterations'] != 2 ||
        v['parallelism'] != 1 ||
        v['key_id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['key_id'] as String) ||
        v['salt'] is! String ||
        (v['salt'] as String).length != 24 ||
        base64.decode(v['salt'] as String).length != 16) {
      throw FormatException(tr("Неверный формат парольного шифрования"));
    }
    return PasswordConfig._(v);
  }

  static PasswordConfig? fromEncoded(String? text) => text == null
      ? null
      : PasswordConfig.fromJson(jsonDecode(text) as Map<String, dynamic>);

  static void validatePassword(String password, {bool creating = false}) {
    if (password.isEmpty ||
        password.runes.length > 256 ||
        utf8.encode(password).length > 1024 ||
        (creating && (password.runes.length < 12 || password.trim().isEmpty))) {
      throw FormatException(
        tr("Используйте пароль или фразу от 12 до 256 символов"),
      );
    }
  }

  static Future<WorkspaceKey> _derive(String password, List<int> salt) async {
    final bytes = await Isolate.run(() async {
      final derived = await const DartArgon2id(
        parallelism: 1,
        memory: 19456,
        iterations: 2,
        hashLength: 32,
        maxIsolates: 1,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      return Uint8List.fromList(await derived.extractBytes());
    });
    try {
      return WorkspaceKey(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<PasswordConfig> create(String password) async {
    validatePassword(password, creating: true);
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _derive(password, salt);
    return PasswordConfig.fromJson({
      'v': 2,
      'key_id': key.id,
      'kdf': 'argon2id',
      'memory': 19456,
      'iterations': 2,
      'parallelism': 1,
      'salt': base64.encode(salt),
    });
  }

  void verify(WorkspaceKey key) {
    if (key.id != keyId) {
      throw FormatException(tr("Неверный пароль или повреждённые параметры"));
    }
  }

  Future<WorkspaceKey> unlock(String password) async {
    validatePassword(password);
    final key = await _derive(password, base64.decode(value['salt'] as String));
    verify(key);
    return key;
  }

  List<int> get archiveHeader {
    final data = utf8.encode(encoded);
    final header = Uint8List(12)..setRange(0, 8, ascii.encode('YGGPASS2'));
    ByteData.sublistView(header).setUint32(8, data.length);
    return [...header, ...data];
  }

  static Future<({PasswordConfig config, int offset})> readArchive(
    File file,
  ) async {
    final input = await file.open();
    try {
      final prefix = await input.read(12);
      if (prefix.length != 12 ||
          ascii.decode(prefix.sublist(0, 8), allowInvalid: true) !=
              'YGGPASS2') {
        throw FormatException(tr("Формат копии не поддерживается"));
      }
      final length = ByteData.sublistView(prefix).getUint32(8);
      if (length < 1 || length > 4096) {
        throw FormatException(tr("Неверный заголовок копии"));
      }
      final data = await WorkspaceKey._readExact(input, length);
      return (
        config: PasswordConfig.fromJson(
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        ),
        offset: 12 + length,
      );
    } finally {
      await input.close();
    }
  }
}
