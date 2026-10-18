import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as timezone;
import 'data/database.dart';
import 'data/reminders.dart';
import 'data/repository.dart';
import 'data/sync.dart';
import 'ui/app.dart';
import 'ui/providers.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  await initializeDateFormatting('ru');
  try {
    final localZone = await FlutterTimezone.getLocalTimezone();
    final repo = Repository(await LocalDatabase.open());
    await repo.initialize(timezone: localZone.identifier);
    final sync = SyncService(repo);
    await sync.initialize();
    final reminders = ReminderService(repo);
    await reminders.initialize();
    runApp(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) => repo),
          syncProvider.overrideWithValue(sync),
          remindersProvider.overrideWithValue(reminders),
        ],
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
                'Не удалось открыть рабочее пространство.\nДанные не удалены.\n\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
