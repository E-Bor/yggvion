import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/encryption.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'records hide content, authenticate metadata and use fresh nonces',
    () async {
      final key = WorkspaceKey(List.filled(32, 1));
      const note = Entity(
        id: 'note1',
        kind: 'note',
        data: {'title': 'Private title', 'content': 'Private text'},
      );
      final wire = await key.encrypt(note, {});
      expect(wire.id, isNot(note.id));
      expect(wire.encoded, isNot(contains('Private')));
      expect((await key.decrypt(wire)).record.data, note.data);
      expect((await key.decrypt(wire)).record.id, note.id);
      expect(
        (await key.encrypt(note, {})).data['nonce'],
        isNot(wire.data['nonce']),
      );
      // Versions and cursors are assigned by the relay; content identity is bound.
      expect((await key.decrypt(wire.withVersion(42))).record.version, 42);
      for (final changed in [
        Entity.fromJson({...wire.toJson(), 'id': 'other'}),
        Entity.fromJson({...wire.toJson(), 'kind': 'task'}),
        Entity.fromJson({...wire.toJson(), 'deleted': true}),
        wire.change({
          'files': ['a' * 64],
        }),
        wire.change({'nonce': base64.encode(List.filled(12, 0))}),
        wire.change({'box': base64.encode(List.filled(32, 0))}),
      ]) {
        await expectLater(key.decrypt(changed), throwsA(anything));
      }
      await expectLater(
        WorkspaceKey(List.filled(32, 2)).decrypt(wire),
        throwsFormatException,
      );
      await expectLater(key.decrypt(note), throwsFormatException);
    },
  );
  test(
    'chunked files authenticate final length, position, purpose and key',
    () async {
      final dir = await Directory.systemTemp.createTemp('ygg-e2ee-unit-');
      addTearDown(() => dir.delete(recursive: true));
      final key = WorkspaceKey(List.filled(32, 1)),
          source = File('${dir.path}/source'),
          cipher = File('${dir.path}/cipher'),
          output = File('${dir.path}/output');
      for (final length in [0, 37, 2 * WorkspaceKey.chunkSize + 57]) {
        await source.writeAsBytes(List.generate(length, (i) => i % 251));
        await key.encryptFile(source, cipher, 'attachment:test');
        await key.decryptFile(cipher, output, 'attachment:test');
        expect(await output.readAsBytes(), await source.readAsBytes());
      }
      final encrypted = await cipher.readAsBytes();
      await expectLater(
        key.decryptFile(cipher, output, 'backup'),
        throwsA(anything),
      );
      await expectLater(
        WorkspaceKey(
          List.filled(32, 2),
        ).decryptFile(cipher, output, 'attachment:test'),
        throwsFormatException,
      );
      final stride = WorkspaceKey.chunkSize + 16;
      for (final bytes in [
        [
          ...encrypted.sublist(0, 112),
          ...encrypted.sublist(112 + stride, 112 + 2 * stride),
          ...encrypted.sublist(112, 112 + stride),
          ...encrypted.sublist(112 + 2 * stride),
        ],
        encrypted.sublist(0, encrypted.length - 1),
        [...encrypted, 0],
        [...encrypted]..[112] ^= 1,
        [...encrypted]..[47] ^= 1,
      ]) {
        await cipher.writeAsBytes(bytes);
        await expectLater(
          key.decryptFile(cipher, output, 'attachment:test'),
          throwsA(anything),
        );
      }
    },
  );
}
