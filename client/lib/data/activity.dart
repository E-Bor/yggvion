import '../l10n/strings.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'database.dart';

/// Device-local usage, independent of work timers and the sync outbox.
/// A foreground interval stops after two minutes without input.
class ApplicationActivity extends ChangeNotifier with WidgetsBindingObserver {
  ApplicationActivity(this.db, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  static const idleAfter = Duration(minutes: 2);
  final LocalDatabase db;
  final DateTime Function() clock;
  Timer? _timer;
  Future<void> _pending = Future.value();
  DateTime? _lastInput, _lastRequested, _savedUntil;
  int? _interval;
  bool _foreground = false, _observing = false, _disposed = false;
  String? error;

  void start() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_key);
    final state = WidgetsBinding.instance.lifecycleState;
    unawaited(
      setForeground(state == null || state == AppLifecycleState.resumed),
    );
  }

  bool _key(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) unawaited(interact());
    return false; // Never consume editor or workspace shortcuts.
  }

  Future<void> _queue(Future<void> Function() action) {
    _pending = _pending.then((_) async {
      try {
        await action();
        if (error != null) {
          error = null;
          if (!_disposed) notifyListeners();
        }
      } catch (e, stack) {
        error = tr("Не удалось сохранить активность на этом устройстве.");
        debugPrint('Activity storage failed: $e\n$stack');
        if (!_disposed) notifyListeners();
      }
    });
    return _pending;
  }

  Future<void> interact({bool force = false}) {
    if (!_foreground || _disposed) return Future.value();
    final time = clock();
    // Pointer moves and key repeats can be very frequent.
    if (!force &&
        _lastRequested != null &&
        time.difference(_lastRequested!) < const Duration(seconds: 1)) {
      return Future.value();
    }
    _lastRequested = time;
    return _queue(() async {
      if (_interval != null &&
          _lastInput != null &&
          time.isBefore(_lastInput!.add(idleAfter))) {
        // Keep frequent input in memory; persist on the 30-second checkpoint,
        // when leaving the foreground, or before showing usage statistics.
        _lastInput = time;
        return;
      }
      await _flushAt(time);
      _lastInput = time;
      if (_interval == null) {
        _interval = await db.beginActivity(time);
        _savedUntil = time;
      }
    });
  }

  Future<void> _flushAt(DateTime time) async {
    if (_interval == null || _lastInput == null) return;
    final idle = _lastInput!.add(idleAfter);
    final end = time.isBefore(idle) ? time : idle;
    if (end.isAfter(_savedUntil!)) {
      await db.endActivity(_interval!, end);
      _savedUntil = end;
    }
    if (!time.isBefore(idle)) _interval = null;
  }

  Future<void> flush() {
    final time = clock();
    return _queue(() => _flushAt(time));
  }

  Future<void> setForeground(bool active) {
    if (_foreground == active) return _pending;
    _foreground = active;
    _timer?.cancel();
    if (active) {
      if (_observing) {
        _timer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(flush()),
        );
      }
      return interact(force: true);
    }
    final time = clock();
    return _queue(() async {
      await _flushAt(time);
      _interval = null;
      _lastInput = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(setForeground(state == AppLifecycleState.resumed));
  }

  Future<void> stop() async {
    _timer?.cancel();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      HardwareKeyboard.instance.removeHandler(_key);
      _observing = false;
    }
    await setForeground(false);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      HardwareKeyboard.instance.removeHandler(_key);
    }
    unawaited(setForeground(false));
    super.dispose();
  }
}
