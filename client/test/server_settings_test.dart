import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/ai_service.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/ui/ai_settings.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/server_settings.dart';
import 'package:yggvion/ui/theme.dart';

class AdminFixture extends SyncService {
  AdminFixture(super.repo);
  @override
  bool get connected => true;
  @override
  String get url => 'https://192.0.2.1';
  @override
  Future<List<Map<String, dynamic>>> devices() async => [];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async => {
    'config': {'every_hours': 24, 'keep_daily': 7, 'keep_weekly': 4},
    'status': {'running': false},
    'backups': <Object>[],
    'remote': {'kind': 'disabled'},
  };
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets('server, backup and AI settings remain usable at $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Repository repo;
      await tester.runAsync(() async {
        repo = Repository(LocalDatabase(NativeDatabase.memory()));
        await repo.initialize();
      });
      final sync = AdminFixture(repo), ai = AiService(repo)..enabled = true;
      final container = ProviderContainer(
        overrides: [
          appProvider.overrideWith((ref) => repo),
          syncProvider.overrideWithValue(sync),
          aiProvider.overrideWith((ref) => ai),
        ],
      );
      for (final page in <Widget>[
        const SynchronizationPage(),
        const InstallServerPage(),
        const BackupsPage(),
        const RemoteBackupsPage(initial: {'kind': 'sftp'}),
        const AiSettingsPage(),
      ]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: appTheme(), home: page),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${page.runtimeType} initial layout',
        );
        await tester.drag(find.byType(ListView).first, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${page.runtimeType} scrolled layout',
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(ai.shutdown);
      sync.dispose();
      container.dispose();
      await tester.runAsync(repo.db.close);
    });
  }
}
