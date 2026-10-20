import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'models.dart';

class AiDraft {
  AiDraft(this.action, this.data, this.summary, {this.blocks = const []});
  final String action;
  final Map<String, dynamic> data;
  final String summary;
  final List<({String taskId, DateTime start, DateTime end})> blocks;
  bool get writes => ['task', 'note', 'plan'].contains(action);
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
    if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
      throw const FormatException('Уточните время в формате ЧЧ:ММ');
    }
    final parts = value.split(':').map(int.parse).toList();
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
  }) {
    if (json.length > 32000) {
      throw const FormatException('Ответ модели слишком длинный');
    }
    final d = jsonDecode(json) as Map<String, dynamic>;
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

    var dateText = text('date');
    final today = tz.TZDateTime.from(now, zone);
    final requested = ['task', 'plan'].contains(action)
        ? relativeDate(request ?? '', today, zone)
        : null;
    if (requested != null) {
      dateText = dayKey(requested);
    } else if (d['weekday'] is int) {
      final weekday = number('weekday', 1, 1, 7);
      var delta = (weekday - today.weekday + 7) % 7;
      if (delta == 0) delta = 7;
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
        final minutes = number(
          'minutes',
          snapshot.settings.defaultMinutes,
          1,
          1440,
        );
        final timeText = text('time');
        DateTime? start;
        if (dateText.isNotEmpty) {
          if (timeText.isEmpty) {
            return AiDraft(
              'clarify',
              {},
              'На какое время ${DateFormat('d MMMM', 'ru').format(date(dateText, zone))} запланировать «$title»?',
            );
          }
          final minute = clock(timeText);
          start = at(date(dateText, zone), minute, zone);
          if (start.hour != minute ~/ 60 || start.minute != minute % 60) {
            throw const FormatException(
              'В этом часовом поясе такого времени нет',
            );
          }
          if (start.isBefore(now.subtract(const Duration(minutes: 1)))) {
            throw const FormatException(
              'Получилась дата в прошлом. Уточните день и время.',
            );
          }
        } else if (timeText.isNotEmpty) {
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
        return AiDraft(
          'task',
          {
            'title': title,
            'description': text('description'),
            'project_id': project,
            'start': start?.toUtc().toIso8601String(),
            'end': end?.toUtc().toIso8601String(),
          },
          '$title\n${start == null ? 'Без времени · планировщик' : '${DateFormat('d MMMM · HH:mm', 'ru').format(start)} — ${DateFormat('HH:mm').format(tz.TZDateTime.from(end!, zone))} · ${zone.name}'}${collision ? '\nЭто время пересекается с другим событием.' : ''}',
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
        final minutes = number(
          'minutes',
          snapshot.settings.defaultMinutes,
          5,
          480,
        );
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
        final start = date(dateText, zone), days = number('days', 7, 1, 366);
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
      if (RegExp(r'следующ\S*\s+недел').hasMatch(words)) {
        delta = 7 - today.weekday + weekday;
      } else {
        delta = (weekday - today.weekday + 7) % 7;
        if (delta == 0) delta = 7;
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
