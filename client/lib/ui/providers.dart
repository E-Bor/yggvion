import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repository.dart';
import '../data/sync.dart';
import '../data/reminders.dart';
import '../data/clipboard.dart';
import '../data/app_icon.dart';
import '../data/system_tracking.dart';
import '../data/activity.dart';
import '../data/local_backup.dart';

final systemTrackingProvider = ChangeNotifierProvider<SystemTrackingService?>(
  (ref) => null,
);
final activityProvider = ChangeNotifierProvider<ApplicationActivity?>(
  (ref) => null,
);
final invitationLinksProvider = Provider<Stream<Uri>?>((ref) => null);
final openNoteProvider = StateProvider<String?>((ref) => null);
final selectedNoteFolderProvider = StateProvider<String>((ref) => '');

// The native shell supplies this optional service at startup.
final appIconProvider = ChangeNotifierProvider<AppIconService?>((ref) => null);

final resetStorageProvider = Provider<Future<void> Function()>(
  (ref) => throw StateError('Storage reset must be provided at startup'),
);

final appProvider = ChangeNotifierProvider<Repository>(
  (ref) => throw StateError('Repository must be provided at startup'),
);
final syncProvider = Provider<SyncService>(
  (ref) => throw StateError('Sync must be provided at startup'),
);
final remindersProvider = Provider<ReminderService>(
  (ref) => throw StateError('Reminders must be provided at startup'),
);
final localBackupProvider = ChangeNotifierProvider<LocalBackupService>(
  (ref) => LocalBackupService(
    ref.read(appProvider),
    beforeRestore: ref.read(syncProvider).disconnect,
  ),
);
final clipboardProvider = Provider<AttachmentClipboard>(
  (ref) => AttachmentClipboard(ref.read(appProvider)),
);
