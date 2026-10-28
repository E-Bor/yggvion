import 'package:intl/intl.dart';

import 'messages.dart';

/// One local language per running application, including background services.
/// This preference is not part of the synchronized workspace.
abstract final class AppLocale {
  static const supported = ['ru', 'en', 'es', 'de', 'zh', 'hi'];
  static String _language = 'ru';
  static String get language => _language;

  static void use(String language) {
    _language = supported.contains(language) ? language : 'ru';
    Intl.defaultLocale = _language;
  }
}

final _parameter = RegExp(r'\{(\d+)\}');

/// Only system messages explicitly passed here are translated. Values are
/// substituted in a single pass, so note text containing {0} stays untouched.
String tr(String message, [List<Object?> values = const []]) =>
    trIn(AppLocale.language, message, values);

String trIn(
  String language,
  String message, [
  List<Object?> values = const [],
]) {
  final index = AppLocale.supported.indexOf(language) - 1;
  final translated = index < 0 ? message : messages[message]?[index] ?? message;
  if (values.isEmpty) return translated;
  return translated.replaceAllMapped(_parameter, (match) {
    final index = int.parse(match[1]!);
    return index < values.length ? '${values[index]}' : match[0]!;
  });
}

String formatAge(int years, {String? language}) {
  final locale = language ?? AppLocale.language;
  final tail = years % 100;
  final unit = locale != 'ru'
      ? (years == 1 ? 'год' : 'лет')
      : tail >= 11 && tail <= 14
      ? 'лет'
      : switch (years % 10) {
          1 => 'год',
          2 || 3 || 4 => 'года',
          _ => 'лет',
        };
  return '$years ${trIn(locale, unit)}';
}
