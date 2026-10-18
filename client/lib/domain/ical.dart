import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../data/repository.dart';
import 'models.dart';
import 'recurrence.dart';

class CalendarImport {
  CalendarImport(this.events, this.warnings);
  final List<ImportedEvent> events;
  final List<String> warnings;
}

class ImportedEvent {
  ImportedEvent({
    required this.uid,
    required this.title,
    required this.description,
    required this.start,
    required this.end,
    required this.timezone,
    required this.allDay,
    this.rule = '',
    this.exceptions = const [],
    this.reminders = const [],
  });
  final String uid, title, description, timezone, rule;
  final DateTime start, end;
  final bool allDay;
  final List<String> exceptions;
  final List<int> reminders;
}

String _unescape(String value) => value
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', '\\');
DateTime _date(String text, String zone) {
  final m = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
  ).firstMatch(text);
  if (m == null) throw FormatException('Неподдерживаемая дата: $text');
  final values = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
  if (m[7] == 'Z') {
    return DateTime.utc(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
    );
  }
  return tz.TZDateTime(
    tz.getLocation(zone),
    values[0],
    values[1],
    values[2],
    values[3],
    values[4],
    values[5],
  ).toUtc();
}

CalendarImport parseCalendar(String source, String defaultZone) {
  if (!source.contains('BEGIN:VCALENDAR')) {
    throw const FormatException('Это не файл iCalendar');
  }
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '')
      .split('\n');
  final events = <ImportedEvent>[], warnings = <String>[];
  final overridden = <String, List<String>>{};
  Map<String, List<(String, String)>>? event;
  var nested = 0;
  for (final line in lines) {
    if (line == 'BEGIN:VEVENT') {
      event = {};
      nested = 0;
      continue;
    }
    if (event == null) continue;
    if (line == 'END:VEVENT') {
      final data = event;
      event = null;
      try {
        String value(String key, [String fallback = '']) =>
            data[key]?.first.$2 ?? fallback;
        String zoneFor(String attributes) =>
            RegExp(r'TZID="?([^;"]+)').firstMatch(attributes)?.group(1) ??
            defaultZone;
        final recurrence = data['RECURRENCE-ID']?.first;
        if (recurrence != null) {
          (overridden[value('UID')] ??= []).add(
            wireTime(_date(recurrence.$2, zoneFor(recurrence.$1))),
          );
        }
        if (value('STATUS') == 'CANCELLED') continue;
        if (data.containsKey('RECURRENCE-ID')) {
          warnings.add(
            'Исключение серии «${value('SUMMARY')}» импортируется отдельной задачей.',
          );
        }
        final startProperty = data['DTSTART']?.first;
        if (startProperty == null) throw const FormatException('Нет DTSTART');
        final zone = zoneFor(startProperty.$1),
            start = _date(startProperty.$2, zone),
            allDay = startProperty.$2.length == 8;
        DateTime end;
        if (data.containsKey('DTEND')) {
          final e = data['DTEND']!.first;
          end = _date(e.$2, zoneFor(e.$1));
        } else if (data.containsKey('DURATION')) {
          final match = RegExp(
            r'^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
          ).firstMatch(value('DURATION'));
          if (match == null) {
            throw const FormatException('Неподдерживаемая длительность');
          }
          int n(int i) => int.parse(match[i] ?? '0');
          end = start.add(
            Duration(
              days: n(1) * 7 + n(2),
              hours: n(3),
              minutes: n(4),
              seconds: n(5),
            ),
          );
        } else {
          final local = tz.TZDateTime.from(start, tz.getLocation(zone));
          end = allDay
              ? tz.TZDateTime(
                  local.location,
                  local.year,
                  local.month,
                  local.day + 1,
                )
              : start.add(const Duration(minutes: 30));
        }
        Repository.validateInterval(start, end);
        final rule = value('RRULE');
        if (rule.isNotEmpty) RecurrenceService.parse(rule);
        if (data.containsKey('RDATE') ||
            data.containsKey('EXRULE') ||
            (recurrence?.$1.contains('RANGE=THISANDFUTURE') ?? false)) {
          warnings.add(
            '«${value('SUMMARY')}»: дополнительные правила RDATE/EXRULE и RANGE=THISANDFUTURE не переносятся.',
          );
        }
        final exceptions = <String>[];
        for (final ex in data['EXDATE'] ?? <(String, String)>[]) {
          for (final date in ex.$2.split(',')) {
            exceptions.add(wireTime(_date(date, zoneFor(ex.$1))));
          }
        }
        final reminders = <int>[];
        for (final trigger in data['TRIGGER'] ?? <(String, String)>[]) {
          final match = RegExp(
            r'^-P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
          ).firstMatch(trigger.$2);
          if (match != null) {
            reminders.add(
              int.parse(match[1] ?? '0') * 1440 +
                  int.parse(match[2] ?? '0') * 60 +
                  int.parse(match[3] ?? '0') +
                  (int.parse(match[4] ?? '0') / 60).ceil(),
            );
          } else {
            warnings.add(
              '«${value('SUMMARY')}»: нестандартное напоминание не перенесено.',
            );
          }
        }
        events.add(
          ImportedEvent(
            uid:
                '${value('UID', start.toIso8601String())}${value('RECURRENCE-ID')}',
            title: _unescape(value('SUMMARY', 'Без названия')),
            description: _unescape(value('DESCRIPTION')),
            start: start,
            end: end,
            timezone: zone,
            allDay: allDay,
            rule: rule,
            exceptions: exceptions,
            reminders: reminders,
          ),
        );
      } catch (e) {
        warnings.add(
          'Не удалось импортировать «${data['SUMMARY']?.first.$2 ?? 'Событие'}»: $e',
        );
      }
      continue;
    }
    if (line.startsWith('BEGIN:')) {
      nested++;
      continue;
    }
    if (line.startsWith('END:')) {
      nested--;
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final attributes = line.substring(0, colon);
    final key = attributes.split(';').first;
    if (nested > 0 && key != 'TRIGGER') continue;
    (event[key] ??= []).add((attributes, line.substring(colon + 1)));
  }
  for (final master in events.where((e) => e.rule.isNotEmpty)) {
    master.exceptions.addAll(overridden[master.uid] ?? []);
  }
  return CalendarImport(events, warnings);
}

Future<int> importCalendar(
  Repository repo,
  CalendarImport calendar,
  String projectId,
) async {
  final changes = <Entity>[];
  var count = 0;
  for (final event in calendar.events) {
    final id = const Uuid().v5(
      '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
      'ical:${event.uid}',
    );
    final seriesId = event.rule.isEmpty
        ? ''
        : const Uuid().v5(
            '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
            'ical-series:${event.uid}',
          );
    if (await repo.db.entity(id) != null ||
        (seriesId.isNotEmpty && await repo.db.entity(seriesId) != null)) {
      continue;
    }
    if (seriesId.isNotEmpty) {
      changes.add(
        Entity(
          id: seriesId,
          kind: 'series',
          data: {
            'title': event.title,
            'description': event.description,
            'project_id': projectId,
            'start': wireTime(event.start),
            'minutes': event.end.difference(event.start).inMinutes,
            'timezone': event.timezone,
            'anchor_timezone': event.timezone,
            'day_span':
                RecurrenceService.wall(
                      tz.TZDateTime.from(
                        event.end,
                        tz.getLocation(event.timezone),
                      ),
                    )
                    .difference(
                      RecurrenceService.wall(
                        tz.TZDateTime.from(
                          event.start,
                          tz.getLocation(event.timezone),
                        ),
                      ),
                    )
                    .inDays,
            'rule': event.rule,
            'reminders': event.reminders,
            'all_day': event.allDay,
            'exceptions': event.exceptions,
          },
        ),
      );
    }
    if (seriesId.isNotEmpty &&
        event.exceptions.contains(wireTime(event.start))) {
      count++;
      continue;
    }
    changes.add(
      Task.create(
        id,
        event.title,
        description: event.description,
        projectId: projectId,
        seriesId: seriesId,
        occurrence: seriesId.isEmpty ? '' : wireTime(event.start),
      ),
    );
    changes.add(
      TimeBlock.create(
        const Uuid().v5(
          '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
          'ical-block:${event.uid}',
        ),
        id,
        event.start,
        event.end,
        timezone: event.timezone,
        allDay: event.allDay,
        reminders: event.reminders,
      ),
    );
    count++;
  }
  if (changes.isNotEmpty) await repo.commit(changes);
  return count;
}
