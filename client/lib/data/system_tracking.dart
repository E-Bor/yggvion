import '../l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../domain/tracking_action.dart';
import 'repository.dart';

/// Publishes changes, not seconds. ActivityKit / Android's chronometer draws
/// the clock while Flutter sleeps. Native actions are durable until DB commit.
class SystemTrackingService extends ChangeNotifier with WidgetsBindingObserver {
  SystemTrackingService(
    this.repo, {
    this.channel = const MethodChannel('dev.yggvion/tracking'),
    TargetPlatform? platform,
  }) : supported =
           !kIsWeb &&
           const [
             TargetPlatform.iOS,
             TargetPlatform.android,
           ].contains(platform ?? defaultTargetPlatform);

  final Repository repo;
  final MethodChannel channel;
  final bool supported;
  String? error;
  String? _signature;
  bool _started = false, _stopped = false, _again = false;
  Future<void>? _work;

  Future<void> initialize() async {
    if (!supported || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'actionsChanged') await refresh(force: true);
    });
    repo.addListener(_changed);
    // Apply lock-screen pauses before sync starts or the UI can change timers.
    await refresh(force: true);
  }

  void _changed() {
    if (_signature != _currentSignature()) unawaited(refresh());
  }

  String _currentSignature() {
    final task = repo.trackedTask;
    if (task == null) return '';
    return jsonEncode([
      task.entity.encoded,
      repo.snapshot.estimate(task.id).inMilliseconds,
      repo.snapshot.settings.accentColor,
      repo.language,
      for (final session in repo.snapshot.sessions)
        if (session.taskId == task.id) session.entity.encoded,
    ]);
  }

  Future<void> refresh({bool force = false}) {
    if (!_started || _stopped) return Future.value();
    if (force) _signature = null;
    if (_work != null) {
      _again = true;
      return _work!;
    }
    return _work = _refresh().whenComplete(() => _work = null);
  }

  Future<void> _refresh() async {
    do {
      _again = false;
      try {
        final pending =
            await channel.invokeListMethod<dynamic>('pending') ?? [];
        final acknowledged = <String>[];
        for (final raw in pending) {
          final action = TrackingAction.fromMap(raw as Map);
          await repo.applyTrackingAction(action);
          acknowledged.add(action.id);
        }
        final signature = _currentSignature();
        if (signature != _signature || acknowledged.isNotEmpty) {
          final task = repo.trackedTask, now = repo.now();
          final sessions = repo.snapshot.sessions
              .where((s) => s.taskId == task?.id && s.running)
              .toList();
          final accepted = await channel.invokeMethod<bool>('publish', {
            'acknowledged': acknowledged,
            'state': task == null
                ? null
                : {
                    'taskId': task.id,
                    'title': String.fromCharCodes(task.title.runes.take(180)),
                    'deviceId': repo.deviceId,
                    'plannedMs': repo.snapshot.estimate(task.id).inMilliseconds,
                    'elapsedMs': repo.snapshot
                        .spent(task.id, now)
                        .inMilliseconds,
                    'updatedAtMs': now.millisecondsSinceEpoch,
                    'running': sessions.isNotEmpty,
                    'sessionIds': sessions.map((s) => s.id).toList(),
                    'accent': repo.snapshot.settings.accentColor,
                    'labels': {
                      'running': tr('В работе'),
                      'pause': tr('Пауза'),
                      'resume': tr('Продолжить'),
                      'stop': tr('Остановить'),
                      'planned': tr('План'),
                      'actual': tr('Факт'),
                      'hour': tr('ч'),
                      'minute': tr('мин'),
                      'channel': tr('Текущая задача'),
                      'progress': tr('Факт относительно плана'),
                    },
                  },
          });
          // An OS action arrived between reading and publishing. Never replace
          // its new state with the older Flutter snapshot.
          if (accepted == false) {
            _again = true;
          } else {
            _signature = signature;
          }
        }
        if (error != null) {
          error = null;
          notifyListeners();
        }
      } catch (exception) {
        error = tr("Не удалось обновить таймер на экране блокировки.");
        debugPrint('System tracking update failed: $exception');
        notifyListeners();
        break; // Preserve the queue; retry on resume or the next data change.
      }
    } while (_again && !_stopped);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh(force: true));
  }

  Future<void> clearAndStop() async {
    _stopped = true;
    if (_started) {
      repo.removeListener(_changed);
      WidgetsBinding.instance.removeObserver(this);
      await _work;
      await channel.invokeMethod<void>('clear');
      channel.setMethodCallHandler(null);
    }
  }

  @override
  void dispose() {
    _stopped = true;
    if (_started) {
      repo.removeListener(_changed);
      WidgetsBinding.instance.removeObserver(this);
      channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
