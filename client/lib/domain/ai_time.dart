/// Explicit clock times in a command. Resolving these must not depend on a
/// language model preserving the punctuation produced by speech recognition.
class AiTimeInput {
  const AiTimeInput({this.time, this.endTime, this.question});
  final String? time;
  final String? endTime;
  final String? question;
  int? get rangeMinutes {
    if (time == null || endTime == null) return null;
    int minute(String value) {
      final parts = value.split(':').map(int.parse).toList();
      return parts[0] * 60 + parts[1];
    }

    final difference = minute(endTime!) - minute(time!);
    return difference > 0 ? difference : difference + 1440;
  }

  static const _units = {
    'ноль': 0,
    'нуль': 0,
    'один': 1,
    'одна': 1,
    'два': 2,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
    'десять': 10,
    'одиннадцать': 11,
    'двенадцать': 12,
    'тринадцать': 13,
    'четырнадцать': 14,
    'пятнадцать': 15,
    'шестнадцать': 16,
    'семнадцать': 17,
    'восемнадцать': 18,
    'девятнадцать': 19,
  };
  static const _tens = {
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'пятьдесят': 50,
  };
  static final _single = _units.entries
      .where((e) => e.value > 0 && e.value < 10)
      .map((e) => e.key)
      .join('|');
  static final _number =
      '(?:\\d{1,2}|н[оу]ль\\s+(?:ноль|нуль|$_single)|'
      '(?:${_tens.keys.join('|')})(?:\\s+(?:$_single))?|'
      '${_units.keys.join('|')})';
  static final _unparsedNumber = RegExp(
    '^\\s+(?:$_number|одному|двум|трем|четырем|пяти|шести|семи|'
    'восьми|девяти|десяти|двадцати|тридцати)(?![а-яёa-z\\d])',
  );
  static const _calendarDay =
      r'сегодня|завтра|послезавтра|понедельник(?:а|у|е|ом)?|'
      r'вторник(?:а|у|е|ом)?|сред[ауеы]|четверг(?:а|у|е|ом)?|'
      r'пятниц[ауеы]|суббот[ауеы]|воскресень[ея]';
  static final _spoken = RegExp(
    '(?<![а-яёa-z\\d.,:+/\\-])'
    '(?:(в|к|на|с|до|$_calendarDay)(?:\\s*[,;:–—])?\\s+)?($_number|час)'
    '(?:\\s+(час(?:а|ов)?))?'
    '(?:\\s+(?:и\\s+)?($_number)(?:\\s+минут(?:у|ы)?)?)?'
    '(?:\\s+(утра|дня|вечера|ночи))?'
    '(?![а-яёa-z\\d])',
  );
  static final _digits = RegExp(
    r'(?<![а-яёa-z\d.,+:/-])(\d{1,2})\s*([:.,\-–—])\s*(\d{2})'
    r'(?![а-яёa-z\d]|[./:\-]\d)',
  );
  static final _attachedPreposition = RegExp(
    r'(?<![а-яёa-z\d])([вкс]|на)(?=\d{1,2}[:.,\-–—])',
  );
  static final _duration = RegExp(
    r'(?:через|длительност[ьи]|длительностью|продолжительность|'
    r'продолжительностью|в течение|на протяжении)'
    r'\s*:?\s*(?:(?:примерно|около)\s+)?$',
  );
  static final _period = RegExp(
    r'^\s*(утра|дня|вечера|ночи|am|pm)(?![а-яёa-z\d])',
  );
  static final _dateOrDurationSuffix = RegExp(
    r'^\s*(?:январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|'
    r'октябр|ноябр|декабр|числ|год|дн|день|недел|месяц|минут|секунд)',
  );
  static final _nonClockPrefix = RegExp(
    r'(?:^|[^а-яёa-z\d])(?:верси[яиюе]|релиз[ау]?|сборк[аиу]|'
    r'номер(?:а|ом|у)?|телефон(?:а|у)?|цен[ауы]|стоимостью|стоимост[ьи]|'
    r'сумм[ауы]|за)(?:\s+(?:до|на|с))?\s*:?\s*$',
  );
  static final _nonClockSuffix = RegExp(
    r'^\s*(?:[₽$€%]|(?:руб(?:ль|ля|лей)?|доллар(?:а|ов)?|евро|'
    r'кг|км|см|мм|мл|литр(?:а|ов)?|процент(?:а|ов)?|подряд)'
    r'(?![а-яёa-z]))',
  );
  static final _on = RegExp(r'(?:^|[^а-яёa-z\d])на\s*$');
  static final _hours = RegExp(r'^\s*(?:час(?:а|ов)?|ч\.?)(?![а-яёa-z])');
  static final _dates = RegExp(
    r'(?<!\d)(?:\d{1,2}\s*[,./-]\s*\d{1,2}\s*[,./-]\s*\d{4}|'
    r'\d{4}\s*[,./-]\s*\d{1,2}\s*[,./-]\s*\d{1,2})(?!\d)',
  );
  static final _phoneNumbers = RegExp(
    r'(?<![а-яёa-z\d])\+?\d[\d ()–-]{7,}\d(?!\d)',
  );

  static int _value(String text) {
    if (text == 'час') return 1;
    final digits = int.tryParse(text);
    if (digits != null) return digits;
    return text
        .split(RegExp(r'\s+'))
        .fold(0, (sum, word) => sum + (_units[word] ?? _tens[word]!));
  }

  /// The structured model field can use the same numeric separators as ASR.
  static String? normalizeClock(String text) {
    final match = RegExp(
      r'^(\d{1,2})\s*[:.,\-–— ]\s*(\d{2})$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    return _clock(int.parse(match[1]!), int.parse(match[2]!));
  }

  static String? _clock(int hour, int minute, [String? period]) {
    if (hour > 23 || minute > 59) return null;
    if (period != null) {
      if (period == 'дня' || period == 'вечера' || period == 'pm') {
        if (hour == 0) return null;
        if (hour < 12) hour += 12;
      } else {
        if (hour > 12) return null;
        if (hour == 12) hour = 0;
      }
    }
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  static AiTimeInput fromRequest(String input) {
    final text = input
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAllMapped(_attachedPreposition, (m) => '${m[1]} ');
    // Keep offsets while excluding dates and long telephone numbers. Otherwise
    // scanning "18 00" globally could pick it out of "+7 900 123 18 00".
    final blocked = [
      ..._dates.allMatches(text),
      ..._phoneNumbers
          .allMatches(
            text.replaceAllMapped(_dates, (m) => ''.padLeft(m[0]!.length)),
          )
          .where((m) => RegExp(r'\d').allMatches(m[0]!).length >= 10),
    ];
    bool isClockContext(int start, int end) {
      if (blocked.any((m) => start < m.end && end > m.start)) return false;
      final before = text.substring(0, start), after = text.substring(end);
      return !_duration.hasMatch(before) &&
          !(_on.hasMatch(before) && _hours.hasMatch(after)) &&
          !_nonClockPrefix.hasMatch(before) &&
          !_nonClockSuffix.hasMatch(after) &&
          !_dateOrDurationSuffix.hasMatch(after);
    }

    final found = <({int start, int end, String? time})>[];
    for (final match in _digits.allMatches(text)) {
      final before = text.substring(0, match.start);
      if (match[2] == '.' &&
          int.parse(match[3]!) >= 1 &&
          int.parse(match[3]!) <= 12 &&
          _on.hasMatch(before)) {
        continue; // "на 13.05" could mean May 13; let the model resolve it.
      }
      final period = _period.firstMatch(text.substring(match.end));
      final end = match.end + (period?.end ?? 0);
      if (!isClockContext(match.start, end)) continue;
      found.add((
        start: match.start,
        end: end,
        time: _clock(int.parse(match[1]!), int.parse(match[3]!), period?[1]),
      ));
    }
    for (final match in _spoken.allMatches(text)) {
      if (found.any((m) => match.start < m.end && match.end > m.start)) {
        continue;
      }
      final after = text.substring(match.end);
      final start = match.start + match[0]!.indexOf(match[2]!);
      if (RegExp(r'^[\d:.,/\-–—]').hasMatch(after) ||
          !isClockContext(start, match.end) ||
          _unparsedNumber.hasMatch(after)) {
        continue;
      }
      // A standalone quantity is not a clock. Unanchored spoken clocks need
      // minutes, "часов", or a period such as "вечера".
      if (match[1] == null &&
          match[3] == null &&
          match[4] == null &&
          match[5] == null) {
        continue;
      }
      // "На час" and "на 13 часов" may be durations. "С 13" may be a
      // range. Do not promote those into a single appointment time.
      if ((match[1] == 'на' || match[1] == 'с') &&
          (match[3] != null || match[4] == null) &&
          match[5] == null) {
        continue;
      }
      found.add((
        start: start,
        end: match.end,
        time: _clock(
          _value(match[2]!),
          match[4] == null ? 0 : _value(match[4]!),
          match[5],
        ),
      ));
    }
    if (found.any((m) => m.time == null)) {
      return const AiTimeInput(
        question: 'Проверьте время: часы от 0 до 23, минуты от 0 до 59.',
      );
    }
    final times = found.map((m) => m.time!).toSet();
    if (times.length > 1) {
      found.sort((a, b) => a.start.compareTo(b.start));
      // Keep explicit start/end times, including crossing midnight. Alternatives
      // separated by "или" must never turn into a range or a guessed start.
      if (found.length == 2 &&
          RegExp(
            r'^\s*(?:до|[-–—])\s*$',
          ).hasMatch(text.substring(found.first.end, found.last.start))) {
        return AiTimeInput(time: found.first.time, endTime: found.last.time);
      }
      return const AiTimeInput(
        question:
            'В команде несколько вариантов времени. Уточните время начала.',
      );
    }
    return AiTimeInput(time: times.firstOrNull);
  }
}

/// Durations are separate from clock times: "в 13 часов" is a start,
/// "на час" is a duration. An omitted duration always uses the user's setting.
class AiDurationInput {
  const AiDurationInput({this.minutes, this.specified = false, this.question});
  final int? minutes;
  final bool specified;
  final String? question;

  static final _prefix = RegExp(
    r'(?:^|[^а-яё])(?:на|длительностью|продолжительностью|в течение)\s+'
    r'(?:(?:примерно|около)\s+)?',
  );
  static final _amount = RegExp(
    '^(полчаса|полчасика|полтора часа|полторы минуты|четверть часа|'
    'час(?:а|ов)? с половиной|час(?:а|ов)?|'
    '-?\\d+(?:[.,]\\d+)?|${AiTimeInput._number})'
    '(?:\\s*(час(?:а|ов)?|ч\\.?|минут(?:а|у|ы)?|мин\\.?))?'
    '(?![а-яёa-z\\d])',
  );

  static AiDurationInput fromRequest(String input) {
    final text = input.toLowerCase().replaceAll('ё', 'е');
    final values = <int>[];
    var specified = false;
    for (final prefix in _prefix.allMatches(text)) {
      var remaining = text.substring(prefix.end);
      var total = 0.0;
      var count = 0;
      while (true) {
        final match = _amount.firstMatch(remaining);
        if (match == null) break;
        final value = match[1]!, unit = match[2];
        double? minutes;
        if (value.startsWith('полчас')) {
          minutes = 30;
        } else if (value == 'полтора часа' || value.contains('с половиной')) {
          minutes = 90;
        } else if (value == 'четверть часа') {
          minutes = 15;
        } else if (value == 'полторы минуты') {
          minutes = 1.5;
        } else if (value.startsWith('час')) {
          minutes = 60;
        } else if (unit != null) {
          final amount =
              double.tryParse(value.replaceAll(',', '.')) ??
              AiTimeInput._value(value).toDouble();
          minutes = amount * (unit.startsWith('ч') ? 60 : 1);
        }
        if (minutes == null) break; // a date or time, without duration units
        specified = true;
        total += minutes;
        count++;
        remaining = remaining
            .substring(match.end)
            .replaceFirst(RegExp(r'^\s+(?:и\s+)?'), '');
      }
      if (count > 0) {
        if (total < 1 || total > 1440 || total != total.roundToDouble()) {
          return const AiDurationInput(
            specified: true,
            question: 'Укажите длительность от 1 до 1440 целых минут.',
          );
        }
        values.add(total.toInt());
      }
    }
    if (values.toSet().length > 1) {
      return const AiDurationInput(
        specified: true,
        question: 'Уточните одну длительность события.',
      );
    }
    // Less common duration phrases may still be interpreted by the model.
    specified |= RegExp(
      r'(?:длительностью|продолжительностью|на протяжении|в течение)\s|'
      r'на\s+[^,.!?]{0,40}\s(?:час(?:а|ов)?|минут(?:у|ы)?)(?![а-яё])',
    ).hasMatch(text);
    return AiDurationInput(minutes: values.firstOrNull, specified: specified);
  }
}
