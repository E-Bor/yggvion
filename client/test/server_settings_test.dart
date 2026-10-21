import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/server_settings.dart';
import 'package:yggvion/ui/theme.dart';

class AdminFixture extends SyncService {
  AdminFixture(super.repo);
  int metricRequests = 0;
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
  }) async {
    if (path == '/api/v1/metrics') {
      metricRequests++;
      return {
        'sampled_at': '2026-10-21T10:00:00Z',
        'cpu_percent': 12.5,
        'memory_total_bytes': 4294967296,
        'memory_used_bytes': 1073741824,
        'process_memory_bytes': 67108864,
        'disk_total_bytes': 42949672960,
        'disk_available_bytes': 21474836480,
        'uptime_seconds': 3600,
      };
    }
    return {
      'config': {'every_hours': 24, 'keep_daily': 7, 'keep_weekly': 4},
      'status': {'running': false},
      'backups': <Object>[],
      'remote': {'kind': 'disabled'},
    };
  }
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets('server and backup settings remain usable at $width px', (
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
      final sync = AdminFixture(repo);
      final container = ProviderContainer(
        overrides: [
          appProvider.overrideWith((ref) => repo),
          syncProvider.overrideWithValue(sync),
        ],
      );
      for (final page in <Widget>[
        const SynchronizationPage(),
        const InstallServerPage(),
        const BackupsPage(),
        const RemoteBackupsPage(initial: {'kind': 'sftp'}),
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
        if (page is SynchronizationPage) {
          expect(find.text('Сервер доступен'), findsOneWidget);
          expect(find.text('12.5%'), findsOneWidget);
          expect(sync.metricRequests, 1);
          await tester.pump(const Duration(minutes: 5));
          expect(
            sync.metricRequests,
            1,
            reason: 'No background metrics polling',
          );
          await sync.metrics();
          expect(
            sync.metricRequests,
            1,
            reason: 'Immediate refresh uses cache',
          );
        }
        await tester.drag(find.byType(ListView).first, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${page.runtimeType} scrolled layout',
        );
      }
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      container.dispose();
      await tester.runAsync(repo.db.close);
    });
  }
}
