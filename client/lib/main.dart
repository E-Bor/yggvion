import 'l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as timezone;
import 'data/database.dart';
import 'data/storage_reset.dart';
import 'package:path_provider/path_provider.dart';
import 'data/app_icon.dart';
import 'data/activity.dart';
import 'data/reminders.dart';
import 'data/repository.dart';
import 'data/sync.dart';
import 'data/system_tracking.dart';
import 'ui/app.dart';
import 'ui/providers.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  await initializeDateFormatting();
  try {
    final localZone = await FlutterTimezone.getLocalTimezone();
    final repo = Repository(await LocalDatabase.open());
    await repo.initialize(timezone: localZone.identifier);
    final tracking = SystemTrackingService(repo);
    await tracking.initialize();
    final sync = SyncService(repo);
    await sync.initialize();
    final reminders = ReminderService(repo);
    await reminders.initialize();
    final appIcons = AppIconService(repo)..start();
    final activity = ApplicationActivity(repo.db)..start();
    late final ProviderContainer container;
    var stopped = false;
    Future<void> clearStorage() async {
      runApp(_resetScreen());
      await WidgetsBinding.instance.endOfFrame;
      try {
        if (!stopped) {
          final backups = container.read(localBackupProvider);
          await Future.wait([
            sync.shutdown(),
            backups.stop(),
            reminders.clearAndStop(),
            tracking.clearAndStop(),
            activity.stop(),
          ]);
          await repo.close();
          appIcons.dispose();
          container.dispose();
          stopped = true;
        }
        await StorageReset.clear(await getApplicationSupportDirectory());
        await main();
      } catch (error) {
        runApp(_resetScreen(error: error, retry: clearStorage));
      }
    }

    container = ProviderContainer(
      overrides: [
        appProvider.overrideWith((ref) => repo),
        syncProvider.overrideWithValue(sync),
        remindersProvider.overrideWithValue(reminders),
        appIconProvider.overrideWith((ref) => appIcons),
        systemTrackingProvider.overrideWith((ref) => tracking),
        activityProvider.overrideWith((ref) => activity),
        resetStorageProvider.overrideWithValue(clearStorage),
        invitationLinksProvider.overrideWithValue(AppLinks().uriLinkStream),
      ],
    );
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const YggvionApp(),
      ),
    );
  } catch (error, stack) {
    debugPrint('Startup failed: $error\n$stack');
    runApp(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                tr("Не удалось открыть рабочее пространство.\n\n{0}", [error]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _resetScreen({Object? error, Future<void> Function()? retry}) =>
    MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error == null) const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  error == null
                      ? tr("Очищаем хранилище…")
                      : tr("Не удалось завершить очистку"),
                  textAlign: TextAlign.center,
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  SelectableText('$error', textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: retry,
                    child: Text(tr("Повторить очистку")),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
