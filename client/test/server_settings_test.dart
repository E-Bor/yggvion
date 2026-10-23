import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/data/server_installer.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/server_settings.dart';
import 'package:yggvion/ui/encryption_settings.dart';
import 'package:yggvion/ui/theme.dart';

class AdminFixture extends SyncService {
  AdminFixture(super.repo);
  int metricRequests = 0;
  int fetchRequests = 0;
  Object? fetchBody;
  bool linked = true;
  @override
  bool get connected => linked;
  @override
  String get url => 'https://192.0.2.1';
  @override
  Future<void> disconnect() async {
    await super.disconnect();
    linked = false;
  }

  @override
  Future<List<Map<String, dynamic>>> devices() async => [];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    if (path == '/api/v1/backups/remote' && method == 'GET') {
      return {
        'backups': [
          {
            'id': 'test-copy',
            'created': '2026-10-21T10:00:00Z',
            'records': 12,
            'files': 3,
          },
        ],
      };
    }
    if (path == '/api/v1/backups/remote/test-copy/fetch') {
      fetchRequests++;
      fetchBody = data;
      return {};
    }
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
  test(
    'connection and installation cannot replace an existing server',
    () async {
      final repo = Repository(LocalDatabase(NativeDatabase.memory()));
      await repo.initialize();
      final sync = AdminFixture(repo);
      addTearDown(() async {
        sync.dispose();
        await repo.db.close();
      });
      await expectLater(
        sync.pair('https://192.0.2.2', 'code', 'device'),
        throwsStateError,
      );
      await expectLater(
        sync.pairInvitation('yggvion://connect', 'device'),
        throwsStateError,
      );
      final installer = ServerInstaller(sync);
      for (final operation in ServerOperation.values) {
        await expectLater(
          installer.install(
            operation: operation,
            host: '192.0.2.2',
            sshPort: 22,
            httpsPort: 443,
            user: 'root',
            password: '',
            deviceName: 'device',
            verifyHost: (_, _) async => throw StateError('Must not connect'),
            onStatus: (_) {},
          ),
          throwsStateError,
        );
      }
      final note = await repo.createNote();
      await repo.saveNoteContent(note.id, 'Keep local content');
      await sync.disconnect();
      expect(sync.connected, isFalse);
      expect(repo.snapshot.note(note.id)?.content, 'Keep local content');
      expect(await repo.db.meta('server_url'), isNull);
      expect(() => sync.requireDisconnected(), returnsNormally);
    },
  );
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
        const EncryptionPage(),
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
          expect(find.text('Подключиться по приглашению'), findsNothing);
          expect(find.text('Установить на VPS'), findsNothing);
          expect(
            find.text('Существующий сервер с публичным HTTPS'),
            findsNothing,
          );
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
          await tester.scrollUntilVisible(
            find.text('Забыть сервер'),
            350,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Очистить сервер'), findsOneWidget);
          expect(find.text('Обновить серверную часть'), findsOneWidget);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Забыть сервер'));
          await tester.pumpAndSettle();
          expect(find.text('Забыть сервер?'), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Забыть сервер'),
            ),
          );
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await tester.pumpAndSettle();
          expect(sync.connected, isFalse);
          await tester.scrollUntilVisible(
            find.text('Подключиться по приглашению'),
            350,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Подключиться по приглашению'), findsOneWidget);
          expect(find.text('Управление сервером'), findsNothing);
          sync.linked = true;
        }
        expect(find.text('Ключ серверного архива'), findsNothing);
        if (page is RemoteBackupsPage) {
          await tester.scrollUntilVisible(
            find.text('Показать копии'),
            500,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Показать копии'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byTooltip('Вернуть на VPS'));
          await tester.tap(find.byTooltip('Вернуть на VPS'));
          await tester.pumpAndSettle();
          expect(sync.fetchRequests, 1);
          expect(sync.fetchBody, isNull);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Ключ восстановления'), findsNothing);
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
