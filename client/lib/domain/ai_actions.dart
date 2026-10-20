import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'ai_time.dart';
import 'models.dart';

class AiDraft {
  AiDraft(this.action, this.data, this.summary, {this.blocks = const []});
  final String action;
  final Map<String, dynamic> data;
  final String summary;
  final List<({String taskId, DateTime start, DateTime end})> blocks;
  bool get writes => ['task', 'note', 'plan'].contains(action);
  Map<String, dynamic> toJson() => {
    'action': action,
    'data': data,
    'summary': summary,
    'blocks': [
      for (final b in blocks)
        {
          'task_id': b.taskId,
          'start': b.start.toUtc().toIso8601String(),
          'end': b.end.toUtc().toIso8601String(),
        },
    ],
  };
  factory AiDraft.fromJson(Map<String, dynamic> json) => AiDraft(
    json['action'] as String,
    Map<String, dynamic>.from(json['data'] as Map),
    json['summary'] as String,
    blocks: [
      for (final b in json['blocks'] as List)
        (
          taskId: b['task_id'] as String,
          start: DateTime.parse(b['start'] as String),
          end: DateTime.parse(b['end'] as String),
        ),
    ],
  );
}

// The model proposes a small typed command. Dates, permissions, free slots and
// statistics are validated/calculated here; generated SQL/code is never run.
class AiActions {
  static const schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['task', 'note', 'plan', 'statistics', 'clarify'],
      },
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'content': {'type': 'string'},
      'date': {'type': 'string'},
      'time': {'type': 'string'},
      'minutes': {'type': 'integer'},
      'weekday': {'type': 'integer'},
      'relative_days': {'type': 'integer'},
      'project_id': {'type': 'string'},
      'days': {'type': 'integer'},
      'day_start': {'type': 'string'},
      'day_end': {'type': 'string'},
      'task_ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'question': {'type': 'string'},
    },
    'required': ['action'],
  };
  // When the command already supplies its schedule, the model only extracts
  // event content. It cannot replace known time/default duration with a question.
  static Map<String, dynamic> taskSchema([
    Iterable<String> projectIds = const [],
  ]) => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['task'],
      },
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'project_id': {
        'type': 'string',
        'enum': ['', ...projectIds],
      },
      'minutes': {'type': 'integer'},
    },
    'required': ['action', 'title'],
  };

  static bool requestsFreeTime(String input) => RegExp(
    r'свободн(?:ое|ый|ую|ом|ого)\s+(?:врем|окн|слот|промежут)|'
    r'свободн(?:ое|ый|ую)\s+(?:окно|интервал)|когда\s+(?:будет\s+)?свободно',
    caseSensitive: false,
  ).hasMatch(input);

  static bool requestsNewTask(String input) {
    final text = input.toLowerCase().trim();
    if (RegExp(
      r'заметк|статистик|распредели|перенеси|измени|удали|'
      r'(?:все|эти|мои|существующие)\s+задач',
    ).hasMatch(text)) {
      return false;
    }
    return RegExp(
      r'^(?:пожалуйста[,\s]+)?(?:запиши(?:те)?|запланируй(?:те)?|'
      r'создай(?:те)?|добавь(?:те)?|поставь(?:те)?|назначь(?:те)?)\s',
    ).hasMatch(text);
  }

  static DateTime date(String value, tz.Location zone) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Уточните дату');
    }
    final pieces = value.split('-').map(int.parse).toList();
    final d = tz.TZDateTime(zone, pieces[0], pieces[1], pieces[2]);
    if (dayKey(d) != value) throw const FormatException('Такой даты нет');
    return d;
  }

  static int clock(String value) {
    final normalized = AiTimeInput.normalizeClock(value);
    if (normalized == null) {
      throw const FormatException('Уточните время в формате ЧЧ:ММ');
    }
    final parts = normalized.split(':').map(int.parse).toList();
    return parts[0] * 60 + parts[1];
  }

  static tz.TZDateTime at(DateTime day, int minutes, tz.Location zone) =>
      tz.TZDateTime(
        zone,
        day.year,
        day.month,
        day.day,
        minutes ~/ 60,
        minutes % 60,
      );
  static bool overlaps(DateTime a, DateTime b, DateTime c, DateTime d) =>
      a.isBefore(d) && c.isBefore(b);

  static bool occupiesTime(Snapshot snapshot, TimeBlock block) =>
      !block.historical && snapshot.task(block.taskId)?.isBirthday != true;

  static AiDraft parse(
    String json,
    Snapshot snapshot,
    DateTime now, {
    String? request,
    DateTime? referenceTime,
  }) {
    if (json.length > 32000) {
      throw const FormatException('Ответ модели слишком длинный');
    }
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Модель не вернула предложение действия');
    }
    final d = decoded;
    final action = d['action'];
    final zone = tz.getLocation(snapshot.settings.timezone);
    String text(String key, {int max = 16000}) {
      final value = (d[key] as String? ?? '').trim();
      if (value.length > max) {
        throw FormatException('Слишком длинное поле $key');
      }
      return value;
    }

    int number(String key, int fallback, int min, int max) {
      final value = d[key] ?? fallback;
      if (value is! int || value < min || value > max) {
        throw FormatException('Проверьте $key');
      }
      return value;
    }

    int durationMinutes(
      AiDurationInput duration, {
      int? range,
      int min = 1,
      int max = 1440,
    }) {
      final value =
          duration.minutes ??
          range ??
          (request != null && !duration.specified
              ? snapshot.settings.defaultMinutes
              : number('minutes', snapshot.settings.defaultMinutes, min, max));
      if (value < min || value > max) {
        throw FormatException(
          'Длительность должна быть от $min до $max минут.',
        );
      }
      return value;
    }

    var dateText = text('date');
    final today = tz.TZDateTime.from(referenceTime ?? now, zone);
    final requested = ['task', 'plan', 'statistics'].contains(action)
        ? requestDate(request ?? '', today, zone)
        : null;
    if (requested != null) {
      dateText = dayKey(requested);
    } else if (d['weekday'] is int) {
      final weekday = number('weekday', 1, 1, 7);
      var delta = (weekday - today.weekday + 7) % 7;
      dateText = dayKey(
        tz.TZDateTime(zone, today.year, today.month, today.day + delta),
      );
    } else if (d['relative_days'] is int) {
      final delta = number('relative_days', 0, 0, 365);
      dateText = dayKey(
        tz.TZDateTime(zone, today.year, today.month, today.day + delta),
      );
    }
    switch (action) {
      case 'clarify':
        return AiDraft(
          'clarify',
          d,
          text('question').isEmpty
              ? 'Уточните, что нужно сделать.'
              : text('question'),
        );
      case 'note':
        final content = text('content');
        if (content.isEmpty) throw const FormatException('Текст заметки пуст');
        return AiDraft('note', {'content': content}, content);
      case 'task':
        final title = text('title', max: 500);
        if (title.isEmpty) {
          throw const FormatException('Не хватает названия задачи');
        }
        final project = text('project_id');
        if (project.isNotEmpty &&
            !snapshot.projects.any((p) => p.id == project)) {
          throw const FormatException('Проект не найден');
        }
        final requestedTime = AiTimeInput.fromRequest(request ?? '');
        final requestedDuration = AiDurationInput.fromRequest(request ?? '');
        if (requestedTime.question != null) {
          return AiDraft('clarify', {}, requestedTime.question!);
        }
        if (requestedDuration.question != null) {
          return AiDraft('clarify', {}, requestedDuration.question!);
        }
        // Missing time on a named day means automatic scheduling, not a
        // made-up clock from the model and not another question.
        final freeTime =
            requestsFreeTime(request ?? '') ||
            (dateText.isNotEmpty &&
                (request != null
                    ? requestedTime.time == null
                    : text('time').isEmpty));
        final minutes = durationMinutes(
          requestedDuration,
          range: freeTime ? null : requestedTime.rangeMinutes,
        );
        final timeText = requestedTime.time ?? text('time');
        DateTime? start;
        if (dateText.isNotEmpty) {
          if (freeTime) {
            final day = date(dateText, zone);
            if (day.isAfter(now.add(const Duration(days: 89)))) {
              throw const FormatException(
                'Свободное время можно подобрать в пределах ближайших 90 дней.',
              );
            }
            final window = dayWindow(request ?? '');
            final begin = requestedTime.time == null
                ? window.$1
                : clock(requestedTime.time!);
            final finish = requestedTime.endTime == null
                ? window.$2
                : clock(requestedTime.endTime!);
            start = freeSlot(snapshot, day, now, minutes, begin, finish, zone);
            if (start == null) {
              return AiDraft(
                'clarify',
                {},
                '${DateFormat('d MMMM', 'ru').format(day)} нет свободного окна '
                    'на $minutes мин в интервале '
                    '${DateFormat('HH:mm').format(at(day, begin, zone))}–'
                    '${DateFormat('HH:mm').format(at(day, finish, zone))}. '
                    'Выберите другой день или часы.',
              );
            }
          } else if (timeText.isEmpty) {
            return AiDraft(
              'clarify',
              {},
              'На какое время ${DateFormat('d MMMM', 'ru').format(date(dateText, zone))} запланировать «$title»?',
            );
          } else {
            final minute = clock(timeText);
            start = at(date(dateText, zone), minute, zone);
            if (start.hour != minute ~/ 60 || start.minute != minute % 60) {
              throw const FormatException(
                'В этом часовом поясе такого времени нет',
              );
            }
          }
          if (start.isBefore(now.subtract(const Duration(minutes: 1)))) {
            throw const FormatException(
              'Получилась дата в прошлом. Уточните день и время.',
            );
          }
        } else if (timeText.isNotEmpty || freeTime) {
          return AiDraft(
            'clarify',
            {},
            'На какую дату запланировать «$title»?',
          );
        }
        final end = start?.add(Duration(minutes: minutes));
        final collision =
            start != null &&
            snapshot.blocks.any(
              (b) =>
                  occupiesTime(snapshot, b) &&
                  overlaps(start!, end!, b.start, b.end),
            );
        var scheduleSummary = 'Без времени · планировщик';
        if (start != null && end != null) {
          final localEnd = tz.TZDateTime.from(end, zone);
          final endPattern = dayKey(start) == dayKey(localEnd)
              ? 'HH:mm'
              : 'd MMMM · HH:mm';
          scheduleSummary =
              '${DateFormat('d MMMM · HH:mm', 'ru').format(start)} — '
              '${DateFormat(endPattern, 'ru').format(localEnd)}';
        }
        return AiDraft(
          'task',
          {
            'title': title,
            'description': text('description'),
            'project_id': project,
            'start': start?.toUtc().toIso8601String(),
            'end': end?.toUtc().toIso8601String(),
            if (freeTime) 'auto_scheduled': true,
          },
          '$title\n$scheduleSummary'
              '${freeTime ? '\nПодобрано свободное время · $minutes мин' : ''}'
              '${collision ? '\nЭто время пересекается с другим событием.' : ''}',
        );
      case 'plan':
        final ids = (d['task_ids'] as List? ?? []).cast<String>().toSet();
        if (ids.isEmpty || ids.length > 20) {
          throw const FormatException('Выберите от 1 до 20 задач');
        }
        final tasks = ids.map((id) => snapshot.task(id)).toList();
        if (tasks.any(
          (t) =>
              t == null ||
              t.done ||
              t.seriesId.isNotEmpty ||
              !snapshot.unscheduled(t, now),
        )) {
          throw const FormatException(
            'Планировать можно только незапланированные обычные задачи',
          );
        }
        final first = date(dateText, zone);
        final days = number('days', 1, 1, 14);
        // The calendar materializes recurring events for the next 90 days.
        // Do not silently plan beyond that known occupancy horizon.
        if (first
            .add(Duration(days: days))
            .isAfter(now.add(const Duration(days: 89)))) {
          throw const FormatException(
            'В пилоте можно распределять задачи в пределах ближайших 90 дней. Выберите более близкий период.',
          );
        }
        final requestedDuration = AiDurationInput.fromRequest(request ?? '');
        if (requestedDuration.question != null) {
          return AiDraft('clarify', {}, requestedDuration.question!);
        }
        final minutes = durationMinutes(requestedDuration, min: 5, max: 480);
        final begin = clock(
          text('day_start').isEmpty ? '09:00' : text('day_start'),
        );
        final finish = clock(
          text('day_end').isEmpty ? '18:00' : text('day_end'),
        );
        if (begin >= finish) {
          throw const FormatException(
            'Конец рабочего дня должен быть позже начала',
          );
        }
        final blocks = <({String taskId, DateTime start, DateTime end})>[];
        var taskIndex = 0;
        for (
          var offset = 0;
          offset < days && taskIndex < tasks.length;
          offset++
        ) {
          final day = tz.TZDateTime(
            zone,
            first.year,
            first.month,
            first.day + offset,
          );
          for (
            var m = begin;
            m + minutes <= finish && taskIndex < tasks.length;
            m += 5
          ) {
            final start = at(day, m, zone), end = at(day, m + minutes, zone);
            if (start.isBefore(now) ||
                snapshot.blocks.any(
                  (b) =>
                      occupiesTime(snapshot, b) &&
                      overlaps(start, end, b.start, b.end),
                ) ||
                blocks.any((b) => overlaps(start, end, b.start, b.end))) {
              continue;
            }
            blocks.add((
              taskId: tasks[taskIndex++]!.id,
              start: start,
              end: end,
            ));
            m += minutes - 5;
          }
        }
        if (taskIndex != tasks.length) {
          throw const FormatException(
            'Свободного времени для всех задач не хватает. Увеличьте период или сократите длительность.',
          );
        }
        return AiDraft(
          'plan',
          d,
          blocks
              .map(
                (b) =>
                    '${DateFormat('d MMM · HH:mm', 'ru').format(b.start)} · ${snapshot.task(b.taskId)!.title}',
              )
              .join('\n'),
          blocks: blocks,
        );
      case 'statistics':
        final period = statisticsPeriod(request ?? '', today, zone);
        final start = period?.$1 ?? date(dateText, zone);
        final days = period?.$2 ?? number('days', 7, 1, 366);
        d['date'] = dayKey(start);
        d['days'] = days;
        final end = tz.TZDateTime(
          zone,
          start.year,
          start.month,
          start.day + days,
        );
        var planned = Duration.zero, spent = Duration.zero;
        final done = <String>{};
        for (final b in snapshot.blocks) {
          if (snapshot.task(b.taskId)?.isBirthday == true) continue;
          if (overlaps(start, end, b.start, b.end)) {
            planned += _intersection(start, end, b.start, b.end);
            if (snapshot.task(b.taskId)?.done == true) done.add(b.taskId);
          }
        }
        for (final s in snapshot.sessions) {
          if (!s.discarded && overlaps(start, end, s.start, s.end ?? now)) {
            spent += _intersection(start, end, s.start, s.end ?? now);
          }
        }
        String duration(Duration d) =>
            '${d.inMinutes ~/ 60} ч ${d.inMinutes % 60} мин';
        return AiDraft(
          'statistics',
          d,
          '${DateFormat('d MMM', 'ru').format(start)} — ${DateFormat('d MMM', 'ru').format(end.subtract(const Duration(days: 1)))}\nЗапланировано: ${duration(planned)}\nУчтено: ${duration(spent)}\nЗавершено задач с блоками в периоде: ${done.length}',
        );
      default:
        throw const FormatException(
          'Модель предложила неподдерживаемую команду',
        );
    }
  }

  static DateTime? freeSlot(
    Snapshot snapshot,
    DateTime day,
    DateTime now,
    int minutes,
    int begin,
    int finish,
    tz.Location zone,
  ) {
    if (begin >= finish) {
      throw const FormatException('Конец интервала должен быть позже начала.');
    }
    final limit = at(day, finish, zone);
    final middle = (begin + finish - minutes) / 2;
    final candidates = [for (var m = begin; m < finish; m += 5) m]
      ..sort((a, b) {
        final distance = (a - middle).abs().compareTo((b - middle).abs());
        return distance == 0 ? a.compareTo(b) : distance;
      });
    for (final m in candidates) {
      final start = at(day, m, zone);
      final end = start.add(Duration(minutes: minutes));
      if (start.hour != m ~/ 60 ||
          start.minute != m % 60 ||
          start.isBefore(now) ||
          end.isAfter(limit)) {
        continue;
      }
      if (!snapshot.blocks.any(
        (b) =>
            occupiesTime(snapshot, b) && overlaps(start, end, b.start, b.end),
      )) {
        return start;
      }
    }
    return null;
  }

  static (int, int) dayWindow(String input) {
    final text = input.toLowerCase();
    if (RegExp(r'(^|[^а-яё])утром([^а-яё]|$)').hasMatch(text)) {
      return (8 * 60, 12 * 60);
    }
    if (RegExp(r'(^|[^а-яё])вечером([^а-яё]|$)').hasMatch(text)) {
      return (17 * 60, 21 * 60);
    }
    return (9 * 60, 18 * 60);
  }

  static (DateTime, int)? statisticsPeriod(
    String input,
    DateTime today,
    tz.Location zone,
  ) {
    final text = input.toLowerCase();
    final day = tz.TZDateTime(zone, today.year, today.month, today.day);
    if (text.contains('сегодня')) return (day, 1);
    if (text.contains('позавчера')) {
      return (tz.TZDateTime(zone, day.year, day.month, day.day - 2), 1);
    }
    if (text.contains('вчера')) {
      return (tz.TZDateTime(zone, day.year, day.month, day.day - 1), 1);
    }
    if (RegExp(r'(?:эт[ауой]|текущ\S*|прошл\S*)\s+недел').hasMatch(text)) {
      return (
        tz.TZDateTime(
          zone,
          day.year,
          day.month,
          day.day - day.weekday + 1 - (text.contains('прошл') ? 7 : 0),
        ),
        7,
      );
    }
    return null;
  }

  static DateTime? requestDate(String input, DateTime today, tz.Location zone) {
    final text = input.toLowerCase();
    final iso = RegExp(r'(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)').firstMatch(text);
    if (iso != null) return date(iso[0]!, zone);
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final named = RegExp(
      '(?<!\\d)(\\d{1,2})\\s+(${months.join('|')})(?:\\s+(\\d{4}))?(?![а-яё\\d])',
    ).firstMatch(text);
    final dotted = RegExp(
      r'(?:^|на\s+)(\d{1,2})\.(0?[1-9]|1[0-2])(?:\.(\d{4}))?(?![\d.])',
    ).firstMatch(text);
    if (named == null && dotted == null) {
      return relativeDate(input, today, zone);
    }
    final match = (named ?? dotted)!;
    final day = int.parse(match[1]!);
    final month = named == null
        ? int.parse(match[2]!)
        : months.indexOf(match[2]!) + 1;
    var year = int.tryParse(match[3] ?? '') ?? today.year;
    if (match[3] == null &&
        (month < today.month || (month == today.month && day < today.day))) {
      year++;
    }
    return date(
      '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
      zone,
    );
  }

  /// Common relative dates are resolved from the user's words, never by LLM
  /// arithmetic. More complex/ambiguous phrases remain visible in the preview.
  static DateTime? relativeDate(
    String input,
    DateTime today,
    tz.Location zone,
  ) {
    final words = input.toLowerCase();
    int? delta;
    // Cyrillic word boundaries are explicit (Dart's \b is ASCII-only).
    if (words.contains('послезавтра')) {
      delta = 2;
    } else if (RegExp(r'(^|[^а-яё])завтра([^а-яё]|$)').hasMatch(words)) {
      delta = 1;
    } else if (RegExp(r'(^|[^а-яё])сегодня([^а-яё]|$)').hasMatch(words)) {
      delta = 0;
    }
    if (delta == null) {
      const names = [
        'понедельник',
        'вторник',
        'сред(?:а|у|е|ы)',
        'четверг',
        'пятниц[ауеы]',
        'суббот[ауеы]',
        'воскресень[ея]',
      ];
      final found = <int>[];
      for (var i = 0; i < names.length; i++) {
        if (RegExp('(^|[^а-яё])${names[i]}([^а-яё]|\$)').hasMatch(words)) {
          found.add(i + 1);
        }
      }
      if (found.length != 1) return null;
      final weekday = found.single;
      if (RegExp(
        'следующ\\S*\\s+(?:недел|${names[weekday - 1]})',
      ).hasMatch(words)) {
        delta = 7 - today.weekday + weekday;
      } else if (RegExp(
        '(?:эт(?:у|от|а|ой|ом)|текущ\\S*)\\s+(?:недел|${names[weekday - 1]})',
      ).hasMatch(words)) {
        delta = weekday - today.weekday;
      } else {
        delta = (weekday - today.weekday + 7) % 7;
        if (RegExp(r'через\s+недел').hasMatch(words)) delta += 7;
      }
    }
    return tz.TZDateTime(zone, today.year, today.month, today.day + delta);
  }

  static Duration _intersection(
    DateTime a,
    DateTime b,
    DateTime c,
    DateTime d,
  ) {
    final start = a.isAfter(c) ? a : c, end = b.isBefore(d) ? b : d;
    return end.isAfter(start) ? end.difference(start) : Duration.zero;
  }
}
