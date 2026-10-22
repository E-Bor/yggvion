part of 'encryption.dart';

class PasswordRequired implements Exception {
  const PasswordRequired();
  @override
  String toString() => 'Введите пароль шифрования этой резервной копии';
}

/// Public, authenticated wrapping of the workspace key. Passwords and derived
/// password keys are never persisted or sent to the server.
class PasswordEnvelope {
  PasswordEnvelope._(Map<String, dynamic> value)
    : value = Map.unmodifiable(value);
  final Map<String, dynamic> value;
  String get keyId => value['key_id'] as String;
  int get revision => value['revision'] as int;
  String get encoded => jsonEncode(value);
  static String storageKey(String id) => 'password_envelope_$id';

  factory PasswordEnvelope.fromJson(Map<String, dynamic> v) {
    const fields = {
      'v',
      'key_id',
      'revision',
      'kdf',
      'memory',
      'iterations',
      'parallelism',
      'salt',
      'nonce',
      'box',
      'mac',
    };
    if (v.length != fields.length ||
        !fields.containsAll(v.keys) ||
        v['v'] != 1 ||
        v['kdf'] != 'argon2id' ||
        v['memory'] != 19456 ||
        v['iterations'] != 2 ||
        v['parallelism'] != 1 ||
        v['key_id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(v['key_id'] as String) ||
        v['revision'] is! int ||
        (v['revision'] as int) < 1 ||
        (v['revision'] as int) > 2147483647) {
      throw const FormatException('Неверный формат защиты паролем');
    }
    for (final f in {'salt': 16, 'nonce': 12, 'box': 48, 'mac': 32}.entries) {
      final text = v[f.key];
      if (text is! String ||
          text.length > 128 ||
          base64.decode(text).length != f.value) {
        throw const FormatException('Повреждена защита паролем');
      }
    }
    return PasswordEnvelope._(v);
  }

  static PasswordEnvelope? fromEncoded(String? text) => text == null
      ? null
      : PasswordEnvelope.fromJson(jsonDecode(text) as Map<String, dynamic>);

  static void validatePassword(String password, {bool creating = false}) {
    if (password.isEmpty ||
        password.runes.length > 256 ||
        utf8.encode(password).length > 1024 ||
        (creating && (password.runes.length < 12 || password.trim().isEmpty))) {
      throw const FormatException(
        'Используйте пароль или фразу от 12 до 256 символов',
      );
    }
  }

  static Future<List<int>> _passwordKey(String password, List<int> salt) =>
      Isolate.run(() async {
        final key = await const DartArgon2id(
          parallelism: 1,
          memory: 19456,
          iterations: 2,
          hashLength: 32,
          maxIsolates: 1,
        ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
        return Uint8List.fromList(await key.extractBytes());
      });

  static List<int> _aad(Map<String, dynamic> v) => utf8.encode(
    jsonEncode([
      'yggvion/password/v1',
      v['key_id'],
      v['revision'],
      v['kdf'],
      v['memory'],
      v['iterations'],
      v['parallelism'],
      v['salt'],
    ]),
  );
  static List<int> _signature(WorkspaceKey key, Map<String, dynamic> v) =>
      digest.Hmac(digest.sha256, key._bytes)
          .convert(
            utf8.encode(
              jsonEncode([
                'yggvion/password-envelope/v1',
                base64.encode(_aad(v)),
                v['nonce'],
                v['box'],
              ]),
            ),
          )
          .bytes;

  static Future<PasswordEnvelope> create(
    WorkspaceKey key,
    String password, {
    int revision = 1,
  }) async {
    validatePassword(password, creating: true);
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final v = <String, dynamic>{
      'v': 1,
      'key_id': key.id,
      'revision': revision,
      'kdf': 'argon2id',
      'memory': 19456,
      'iterations': 2,
      'parallelism': 1,
      'salt': base64.encode(salt),
    };
    final derived = await _passwordKey(password, salt);
    try {
      final box = await AesGcm.with256bits().encrypt(
        key._bytes,
        secretKey: SecretKey(derived),
        aad: _aad(v),
      );
      v.addAll({
        'nonce': base64.encode(box.nonce),
        'box': base64.encode([...box.cipherText, ...box.mac.bytes]),
      });
      v['mac'] = base64.encode(_signature(key, v));
      return PasswordEnvelope.fromJson(v);
    } finally {
      derived.fillRange(0, derived.length, 0);
    }
  }

  void verify(WorkspaceKey key) {
    final actual = base64.decode(value['mac'] as String);
    final expected = _signature(key, value);
    var difference = key.id == keyId ? 0 : 1;
    for (var i = 0; i < 32; i++) {
      difference |= actual[i] ^ expected[i];
    }
    if (difference != 0) {
      throw const FormatException('Защита паролем повреждена или подменена');
    }
  }

  Future<WorkspaceKey> unlock(String password) async {
    validatePassword(password);
    final derived = await _passwordKey(
      password,
      base64.decode(value['salt'] as String),
    );
    try {
      final box = base64.decode(value['box'] as String);
      final bytes = await AesGcm.with256bits().decrypt(
        SecretBox(
          box.sublist(0, 32),
          nonce: base64.decode(value['nonce'] as String),
          mac: Mac(box.sublist(32)),
        ),
        secretKey: SecretKey(derived),
        aad: _aad(value),
      );
      final key = WorkspaceKey(bytes);
      verify(key);
      return key;
    } on SecretBoxAuthenticationError {
      throw const FormatException('Неверный пароль или повреждённые данные');
    } finally {
      derived.fillRange(0, derived.length, 0);
    }
  }

  List<int> get archiveHeader {
    final data = utf8.encode(encoded);
    final header = Uint8List(12)..setRange(0, 8, ascii.encode('YGGPASS1'));
    ByteData.sublistView(header).setUint32(8, data.length);
    return [...header, ...data];
  }

  static Future<({PasswordEnvelope envelope, int offset})> readArchive(
    File file,
  ) async {
    final input = await file.open();
    try {
      final prefix = await input.read(12);
      if (prefix.length < 8 ||
          ascii.decode(prefix.sublist(0, 8), allowInvalid: true) !=
              'YGGPASS1') {
        throw const FormatException(
          'Формат копии не поддерживается. Нужна копия с парольным шифрованием.',
        );
      }
      if (prefix.length != 12) {
        throw const FormatException('Повреждён заголовок копии');
      }
      final length = ByteData.sublistView(prefix).getUint32(8);
      if (length < 1 || length > 4096) {
        throw const FormatException('Неверный заголовок копии');
      }
      final data = await WorkspaceKey._readExact(input, length);
      return (
        envelope: PasswordEnvelope.fromJson(
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        ),
        offset: 12 + length,
      );
    } finally {
      await input.close();
    }
  }
}
