import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'repository.dart';

/// Keeps native Apple icons in sync without overlapping OS requests or issuing
/// a request for every intermediate color while the user explores the palette.
class AppIconService extends ChangeNotifier with WidgetsBindingObserver {
  AppIconService(
    this.repo, {
    this.channel = const MethodChannel('dev.yggvion/app_icon'),
    this.debounce = const Duration(milliseconds: 600),
    TargetPlatform? platform,
  }) : supported =
           !kIsWeb &&
           [
             TargetPlatform.macOS,
             TargetPlatform.iOS,
           ].contains(platform ?? defaultTargetPlatform);

  final Repository repo;
  final MethodChannel channel;
  final Duration debounce;
  final bool supported;
  String? error;
  Timer? _timer;
  int? _desired, _applied;
  bool _started = false, _busy = false, _disposed = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void start() {
    if (!supported || _started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    repo.addListener(_changed);
    _changed();
  }

  void _changed() {
    final color = repo.snapshot.settings.accentColor;
    if (_desired == color) return;
    _desired = color;
    _timer?.cancel();
    _timer = Timer(debounce, _apply);
  }

  void retry() {
    if (_disposed || !_started) return;
    _timer?.cancel();
    _timer = Timer(debounce, _apply);
  }

  Future<void> _apply() async {
    _timer = null;
    final color = _desired;
    if (_disposed ||
        _busy ||
        !_foreground ||
        color == null ||
        color == _applied) {
      return;
    }
    _busy = true;
    try {
      await channel.invokeMethod<void>('setAccent', {'color': color});
      _applied = color;
      error = null;
    } catch (exception) {
      error = 'Не удалось изменить системную иконку. Цвет темы сохранён.';
      debugPrint('App icon update failed: $exception');
    } finally {
      _busy = false;
      if (!_disposed) {
        notifyListeners();
        if (_desired != color) retry();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) retry();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_started) {
      repo.removeListener(_changed);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
