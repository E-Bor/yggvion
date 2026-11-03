import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';

const _channel = MethodChannel('dev.yggvion/server_installer');

/// Loads text for execution on the remote VPS; it never runs on this device.
Future<Uint8List> loadServerScript({required bool uninstall}) async {
  final name = uninstall ? 'uninstall.sh' : 'install.sh';
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    final data = await _channel.invokeMethod<Uint8List>('loadScript', name);
    if (data == null || data.isEmpty) {
      throw StateError(tr('Установочный файл повреждён'));
    }
    return data;
  }
  final data = await rootBundle.load('assets/server/$name');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
