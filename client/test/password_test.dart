import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/encryption.dart';

void main() {
  const password = 'Test encryption passphrase 42';
  late PasswordConfig config;
  late WorkspaceKey key;
  setUpAll(() async {
    config = await PasswordConfig.create(password);
    key = await config.unlock(password);
  });
  test('password and public salt reproduce the encryption key', () async {
    final copy = PasswordConfig.fromEncoded(config.encoded)!;
    expect((await copy.unlock(password)).id, key.id);
    expect(copy.value.keys.toSet(), {
      'v',
      'key_id',
      'kdf',
      'memory',
      'iterations',
      'parallelism',
      'salt',
    });
    expect(copy.encoded, isNot(contains(password)));
    await expectLater(
      copy.unlock('Incorrect passphrase'),
      throwsFormatException,
    );
  });
  test(
    'new salt changes the key, without wrapping a random master key',
    () async {
      final next = await PasswordConfig.create(password);
      expect(next.keyId, isNot(config.keyId));
      expect(next.value['salt'], isNot(config.value['salt']));
      final nextKey = await next.unlock(password);
      expect(() => config.verify(nextKey), throwsFormatException);
    },
  );
  test(
    'unsupported or excessive KDF parameters are rejected before derivation',
    () {
      for (final field in <String, dynamic>{
        'v': 1,
        'memory': 999999999,
        'iterations': 999999999,
        'parallelism': 1000,
        'salt': 'short',
        'key_id': 'invalid',
      }.entries) {
        expect(
          () => PasswordConfig.fromJson({
            ...config.value,
            field.key: field.value,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => PasswordConfig.fromJson({...config.value, 'box': 'wrapped-key'}),
        throwsFormatException,
      );
    },
  );
}
