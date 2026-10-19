import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/app_icon.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/theme.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.yggvion/app_icon');
  const blue = AppSettings.defaultAccentColor;
  const rose = 0xffdfa6ba, lavender = 0xffb7a6e8;
  late Repository repo;
  late AppIconService service;
  late List<int> calls;

  setUpAll(tz.initializeTimeZones);

  Future<void> flush() =>
      Future<void>.delayed(const Duration(milliseconds: 80));
  Future<void> accent(int value) {
    final settings = repo.snapshot.settings;
    return repo.updateSettings(
      settings.defaultMinutes,
      settings.reminders,
      settings.timezone,
      accentColor: value,
    );
  }

  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    repo = Repository(LocalDatabase(NativeDatabase.memory()));
    await repo.initialize();
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'setAccent');
      calls.add((call.arguments as Map)['color'] as int);
      return null;
    });
    service = AppIconService(
      repo,
      platform: TargetPlatform.iOS,
      debounce: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    service.dispose();
    await repo.db.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test(
    'restores a saved accent and ignores unrelated repository changes',
    () async {
      await accent(lavender);
      service.start();
      await flush();
      expect(calls, [lavender]);
      await repo.createNote();
      await repo.reload();
      await flush();
      expect(calls, [lavender]);
      expect(service.error, isNull);
    },
  );

  test(
    'rapid palette changes coalesce and sync reload updates the icon',
    () async {
      service.start();
      await flush();
      expect(calls, [blue]);
      await accent(lavender);
      await accent(rose);
      await flush();
      expect(calls, [blue, rose]);
      await repo.commit([
        repo.snapshot.settings.entity.change({'task_color': lavender}),
      ]);
      await repo.reload();
      await flush();
      expect(calls, [blue, rose, lavender]);
    },
  );

  test(
    'never overlaps native requests and eventually applies the latest color',
    () async {
      final pending = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final value = (call.arguments as Map)['color'] as int;
        calls.add(value);
        if (value == blue) await pending.future;
        return null;
      });
      service.start();
      await flush();
      await accent(lavender);
      await accent(rose);
      await flush();
      expect(calls, [blue]);
      pending.complete();
      await flush();
      expect(calls, [blue, rose]);
    },
  );

  test(
    'defers background updates until foreground without resending on every resume',
    () async {
      service.start();
      await flush();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await accent(rose);
      await flush();
      expect(calls, [blue]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush();
      expect(calls, [blue, rose]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush();
      expect(calls, [blue, rose]);
    },
  );

  test(
    'native errors are visible, do not revert the theme, and can be retried',
    () async {
      var fail = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add((call.arguments as Map)['color'] as int);
        if (fail) throw PlatformException(code: 'icon_update_failed');
        return null;
      });
      await accent(rose);
      service.start();
      await flush();
      expect(service.error, contains('Не удалось'));
      expect(repo.snapshot.settings.accentColor, rose);
      fail = false;
      service.retry();
      await flush();
      expect(service.error, isNull);
      expect(calls, [rose, rose]);
    },
  );

  test('iOS bundles opaque icons in every palette color and required size', () {
    for (final color in Palette.projects) {
      final rgb = color.toARGB32() & 0xffffff;
      final name = color.toARGB32() == blue
          ? 'AppIcon'
          : 'Accent${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
      final directory = 'ios/Runner/Assets.xcassets/$name.appiconset';
      final manifest =
          jsonDecode(File('$directory/Contents.json').readAsStringSync())
              as Map;
      for (final item in manifest['images'] as List) {
        final bytes = File('$directory/${item['filename']}').readAsBytesSync();
        final header = ByteData.sublistView(bytes);
        final size = double.parse((item['size'] as String).split('x').first);
        final scale = double.parse(
          (item['scale'] as String).replaceAll('x', ''),
        );
        expect(header.getUint32(16), (size * scale).round());
        expect(header.getUint32(20), (size * scale).round());
        expect(bytes[25], 2, reason: 'iOS icons must be RGB without alpha');
      }
    }
  });
}
