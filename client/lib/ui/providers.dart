import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repository.dart';
import '../data/sync.dart';
import '../data/reminders.dart';
import '../data/clipboard.dart';

final appProvider = ChangeNotifierProvider<Repository>(
  (ref) => throw StateError('Repository must be provided at startup'),
);
final syncProvider = Provider<SyncService>(
  (ref) => throw StateError('Sync must be provided at startup'),
);
final remindersProvider = Provider<ReminderService>(
  (ref) => throw StateError('Reminders must be provided at startup'),
);
final clipboardProvider = Provider<AttachmentClipboard>(
  (ref) => AttachmentClipboard(ref.read(appProvider)),
);
