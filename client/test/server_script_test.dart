import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/server_script.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.yggvion/server_installer');
  final scripts = {
    'install.sh': Uint8List.fromList(utf8.encode('#!/bin/sh\necho "Привет"\n')),
    'uninstall.sh': Uint8List.fromList(utf8.encode('#!/bin/sh\nexit 0\n')),
  };

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      null,
    );
  });

  test('iOS reads each unchanged script from native app resources', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final requested = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'loadScript');
      requested.add(call.arguments as String);
      return scripts[call.arguments];
    });
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (_) {
      fail('iOS must not read the relocated scripts from App.framework');
    });
    expect(await loadServerScript(uninstall: false), scripts['install.sh']);
    expect(await loadServerScript(uninstall: true), scripts['uninstall.sh']);
    expect(requested, ['install.sh', 'uninstall.sh']);
  });

  test('iOS rejects absent or empty script data', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    for (final value in [null, Uint8List(0)]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => value,
      );
      await expectLater(loadServerScript(uninstall: false), throwsStateError);
    }
  });

  test('native resource errors reach the installer', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'missing_script');
    });
    await expectLater(
      loadServerScript(uninstall: true),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'missing_script',
        ),
      ),
    );
  });

  test('other platforms keep reading raw Flutter assets', () async {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      final requested = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
        fail('Only iOS needs the native resource channel');
      });
      binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
        message,
      ) async {
        final key = const StringCodec().decodeMessage(message)!;
        requested.add(key);
        return ByteData.sublistView(scripts[key.split('/').last]!);
      });
      expect(await loadServerScript(uninstall: false), scripts['install.sh']);
      expect(await loadServerScript(uninstall: true), scripts['uninstall.sh']);
      expect(requested, [
        'assets/server/install.sh',
        'assets/server/uninstall.sh',
      ]);
    }
  });
}
