import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/local_backup.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/ui/calendar_sharing.dart';
import 'package:yggvion/ui/local_backups.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show settle;

class SharingFixture extends SyncService {
  SharingFixture(super.repo);
  int? requestedDays;
  bool revoked = false;
  @override
  Future<Map<String, dynamic>> createCalendarShare(int days) async {
    requestedDays = days;
    return {
      'id': 'invitation',
      'url': 'https://203.0.113.1:8443/share#${'a'.padRight(64, 'a')}',
      'expires': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
    };
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    revoked =
        method == 'DELETE' && path == '/api/v1/calendar-shares/invitation';
    return {'revoked': revoked};
  }
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets('backup schedule and share controls work at $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      final copiedLinks = <String>[];
      var clipboardUnavailable = false;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (clipboardUnavailable) {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          copiedLinks.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      late Repository repo;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('yggvion-backup-ui-');
        repo = Repository(LocalDatabase(NativeDatabase.memory()));
        await repo.initialize();
      });
      final backups = LocalBackupService(repo, directory: dir);
      final sync = SharingFixture(repo);
      await tester.runAsync(
        () => sync.setEncryptionPassword('UI fixture password 42'),
      );
      final container = ProviderContainer(
        overrides: [
          appProvider.overrideWith((ref) => repo),
          syncProvider.overrideWithValue(sync),
          localBackupProvider.overrideWith((ref) => backups),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        sync.dispose();
        await tester.runAsync(() async {
          await repo.db.close();
          await dir.delete(recursive: true);
        });
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      Widget app(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: appTheme(),
          home: Scaffold(body: child),
        ),
      );
      await tester.pumpWidget(
        app(ListView(children: const [LocalBackupsPanel()])),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('local-backup-schedule')));
      // Drain both widget microtasks and real archive-isolate messages.
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (backups.scheduleEnabled && !backups.busy) break;
      }
      expect(backups.busy, isFalse, reason: backups.scheduleError);
      await settle(tester);
      expect(backups.scheduleEnabled, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('local-backup-days')),
        '3',
      );
      await settle(tester);
      expect(backups.scheduleDays, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(app(const CalendarShareDialog()));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('14 дней'));
      await tester.tap(find.text('Создать ссылку'));
      await settle(tester);
      expect(sync.requestedDays, 14);
      final url = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(copiedLinks, [url]);
      expect(find.text('Ссылка скопирована'), findsOneWidget);
      expect(find.text('Скопировать ссылку'), findsNothing);
      expect(find.byKey(const ValueKey('copy-calendar-share')), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(copiedLinks, [
        url,
      ], reason: 'Rebuilds must not overwrite the clipboard');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отозвать доступ'));
      await settle(tester);
      expect(sync.revoked, isTrue);
      expect(find.text('Создать ссылку'), findsOneWidget);
      expect(find.text('Ссылка скопирована'), findsNothing);

      clipboardUnavailable = true;
      await tester.tap(find.text('Создать ссылку'));
      await settle(tester);
      expect(find.text(url), findsOneWidget);
      expect(find.text('Ссылка скопирована'), findsNothing);
      expect(
        find.textContaining('Ссылка создана, но не удалось скопировать'),
        findsOneWidget,
      );
      expect(copiedLinks, [url]);
      await tester.tap(find.text('Отозвать доступ'));
      await settle(tester);
      expect(
        find.textContaining('Ссылка создана, но не удалось скопировать'),
        findsNothing,
      );

      clipboardUnavailable = false;
      await tester.tap(find.text('Создать ссылку'));
      await settle(tester);
      expect(copiedLinks, [url, url]);
      expect(find.text('Ссылка скопирована'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
