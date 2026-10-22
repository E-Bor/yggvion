import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/encryption.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const password = 'Длинная фраза для теста 42';
  late WorkspaceKey key;
  late PasswordEnvelope envelope;
  setUpAll(() async {
    key = WorkspaceKey.generate();
    envelope = await PasswordEnvelope.create(key, password);
  });

  test(
    'password round trip is self-contained and rejects a wrong password',
    () async {
      final copy = PasswordEnvelope.fromEncoded(envelope.encoded)!;
      expect((await copy.unlock(password)).id, key.id);
      expect(copy.encoded, isNot(contains(password)));
      expect(copy.encoded, isNot(contains(key.recovery)));
      await expectLater(
        copy.unlock('Другая длинная фраза 42'),
        throwsFormatException,
      );
    },
  );

  test('key wrapping uses fresh salts and authenticated revisions', () async {
    final next = await PasswordEnvelope.create(key, password, revision: 2);
    expect(next.value['salt'], isNot(envelope.value['salt']));
    expect(next.value['nonce'], isNot(envelope.value['nonce']));
    expect(next.value['box'], isNot(envelope.value['box']));
    next.verify(key);
    for (final field in ['salt', 'nonce', 'box', 'mac']) {
      final value = Map<String, dynamic>.from(envelope.value);
      final bytes = base64.decode(value[field] as String)..[0] ^= 1;
      value[field] = base64.encode(bytes);
      final altered = PasswordEnvelope.fromJson(value);
      expect(() => altered.verify(key), throwsFormatException);
    }
    final altered = PasswordEnvelope.fromJson({
      ...envelope.value,
      'revision': 2,
    });
    await expectLater(altered.unlock(password), throwsFormatException);
    expect(
      () => envelope.verify(WorkspaceKey.generate()),
      throwsFormatException,
    );
  });

  test('untrusted envelope cannot request excessive KDF work', () {
    for (final entry in {
      'memory': 999999999,
      'iterations': 999999999,
      'parallelism': 1000,
      'v': 2,
      'kdf': 'none',
      'revision': 0,
      'salt': base64.encode(List.filled(2048, 0)),
      'unexpected': true,
    }.entries) {
      expect(
        () => PasswordEnvelope.fromJson({
          ...envelope.value,
          entry.key: entry.value,
        }),
        throwsFormatException,
        reason: entry.key,
      );
    }
    for (final invalid in ['', 'short', '            ', 'a' * 257]) {
      expect(
        () => PasswordEnvelope.validatePassword(invalid, creating: true),
        throwsFormatException,
      );
    }
    expect(
      () => PasswordEnvelope.validatePassword(password, creating: true),
      returnsNormally,
    );
  });
}
