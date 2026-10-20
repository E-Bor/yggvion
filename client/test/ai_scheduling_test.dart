import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/domain/ai_actions.dart';
import 'package:yggvion/domain/ai_prompt.dart';
import 'package:yggvion/domain/ai_time.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  setUpAll(() async {
    tz_data.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  final now = DateTime.utc(2026, 10, 20, 8, 42);
  Snapshot snapshot({int minutes = 45, List<Entity> busy = const []}) =>
      Snapshot([
        Entity(
          id: 'settings',
          kind: 'settings',
          data: {
            'timezone': 'Europe/Moscow',
            'default_minutes': minutes,
            'reminders': [0],
          },
        ),
        ...busy,
      ]);
  Entity block(String id, DateTime start, DateTime end) =>
      TimeBlock.create(id, id, start, end, timezone: 'Europe/Moscow');
  AiDraft parse(
    String input, {
    Object? minutes,
    String time = '',
    String date = '',
    Snapshot? state,
  }) => AiActions.parse(
    jsonEncode({
      'action': 'task',
      'title': 'Событие',
      'time': time,
      'date': date,
      'minutes': ?minutes,
    }),
    state ?? snapshot(),
    now,
    request: input,
  );
  Duration duration(AiDraft draft) => DateTime.parse(
    draft.data['end'] as String,
  ).difference(DateTime.parse(draft.data['start'] as String));

  test(
    'a dotted clock after a weekday is exact, even when that slot is busy',
    () {
      const request = 'Поставь событие на понедельник 12.30';
      final state = snapshot(
        busy: [
          block(
            'busy',
            DateTime.utc(2026, 10, 26, 9),
            DateTime.utc(2026, 10, 26, 11),
          ),
        ],
      );
      for (final modelTime in ['', '15:00']) {
        final draft = parse(request, time: modelTime, state: state);
        expect(draft.data['start'], '2026-10-26T09:30:00.000Z');
        expect(draft.data['end'], '2026-10-26T10:15:00.000Z');
        expect(draft.data['auto_scheduled'], isNot(true));
        expect(draft.summary, contains('12:30'));
        expect(draft.summary, isNot(contains('Подобрано свободное время')));
      }
      expect(
        AiPrompt.build(request, state, now).system,
        contains('Явное время начала: 12:30'),
      );
    },
  );

  test(
    'omitted duration always uses the setting, even when the model invents one',
    () {
      for (final modelMinutes in [null, 0, 30, 60, 120, 'unknown']) {
        final draft = parse(
          'Запиши врача на субботу на 13-30.',
          minutes: modelMinutes,
        );
        expect(draft.data['start'], '2026-10-24T10:30:00.000Z');
        expect(duration(draft), const Duration(minutes: 45));
      }
      expect(
        duration(parse('Запиши врача на субботу в 13 часов')),
        const Duration(minutes: 45),
      );
    },
  );
  for (final entry in {
    'на 20 минут': 20,
    'на час': 60,
    'на полчаса': 30,
    'на полтора часа': 90,
    'на час с половиной': 90,
    'на 1,5 часа': 90,
    'на два часа и пятнадцать минут': 135,
    'на сорок пять минут': 45,
    'длительностью 2 часа 10 минут': 130,
    'на четверть часа': 15,
  }.entries) {
    test('spoken duration wins over generated minutes: ${entry.key}', () {
      final draft = parse(
        'Запиши врача на субботу в 13:30 ${entry.key}',
        minutes: 5,
      );
      expect(duration(draft), Duration(minutes: entry.value));
    });
  }
  for (final suffix in ['на 0 минут', 'на -5 минут', 'на 25 часов']) {
    test('invalid duration is not silently replaced: $suffix', () {
      expect(
        parse('Запиши врача на субботу в 13:30 $suffix').action,
        'clarify',
      );
    });
  }
  test('explicit ranges keep both ends, including midnight', () {
    final day = parse('Запиши встречу в субботу с 13:30 до 14:20', minutes: 5);
    expect(duration(day), const Duration(minutes: 50));
    final night = parse(
      'Запиши дежурство в субботу с 23:30 до 01:00',
      minutes: 5,
    );
    expect(night.data['start'], '2026-10-24T20:30:00.000Z');
    expect(night.data['end'], '2026-10-24T22:00:00.000Z');
  });
  for (final input in [
    'Запиши врача на 24 октября 2026 на 13-30',
    'Запиши врача на 24.10.2026 в 13:30',
    'Запиши врача на 2026-10-24 в тринадцать тридцать',
  ]) {
    test('explicit date and time survive omitted model fields: $input', () {
      expect(parse(input).data['start'], '2026-10-24T10:30:00.000Z');
    });
  }
  test('free time for a new task skips busy and overlapping blocks', () {
    final state = snapshot(
      busy: [
        block(
          'a',
          DateTime.utc(2026, 10, 21, 6),
          DateTime.utc(2026, 10, 21, 7),
        ),
        block(
          'b',
          DateTime.utc(2026, 10, 21, 6, 30),
          DateTime.utc(2026, 10, 21, 7, 15),
        ),
        block(
          'c',
          DateTime.utc(2026, 10, 21, 7, 30),
          DateTime.utc(2026, 10, 21, 8),
        ),
      ],
    );
    final draft = parse(
      'Запиши врача на завтра в свободное время',
      time: '09:00',
      state: state,
    );
    expect(draft.action, 'task');
    expect(draft.data['auto_scheduled'], isTrue);
    expect(draft.data['start'], '2026-10-21T10:05:00.000Z');
    expect(duration(draft), const Duration(minutes: 45));
    expect(draft.summary, contains('Подобрано свободное время'));
  });
  test('reserve free time with no activity, and start after now on today', () {
    final draft = parse('Запиши на сегодня свободное время');
    expect(draft.action, 'task');
    expect(draft.data['start'], '2026-10-20T10:05:00.000Z');
    expect(duration(draft), const Duration(minutes: 45));
  });
  test(
    'free time respects a requested range without making it the duration',
    () {
      final draft = parse(
        'Запиши врача завтра в свободное время с 15:00 до 17:00',
      );
      expect(draft.data['start'], '2026-10-21T12:35:00.000Z');
      expect(duration(draft), const Duration(minutes: 45));
    },
  );
  test('a full day or a too-short gap asks for another interval', () {
    final state = snapshot(
      busy: [
        block(
          'all-day',
          DateTime.utc(2026, 10, 20, 21),
          DateTime.utc(2026, 10, 21, 21),
        ),
      ],
    );
    expect(
      parse('Запиши врача завтра в свободное время', state: state).action,
      'clarify',
    );
    final short = parse(
      'Запиши врача завтра в свободное время с 15:00 до 15:30',
    );
    expect(short.action, 'clarify');
    expect(short.summary, contains('нет свободного окна на 45 мин'));
  });
  test('free-time allocation ignores historical blocks and birthdays', () {
    final historic = block(
      'history',
      DateTime.utc(2026, 10, 21, 6),
      DateTime.utc(2026, 10, 21, 15),
    );
    final birthday = Task.create(
      'birthday',
      'День рождения',
    ).change({'birthday_date': '1990-10-21'});
    final state = snapshot(
      busy: [
        historic.change({'historical': true}),
        birthday,
        block(
          'birthday',
          DateTime.utc(2026, 10, 20, 21),
          DateTime.utc(2026, 10, 21, 21),
        ),
      ],
    );
    expect(
      parse(
        'Запиши врача завтра в свободное время',
        state: state,
      ).data['start'],
      '2026-10-21T10:05:00.000Z',
    );
  });
  test('a free slot still needs a day and respects the recurrence horizon', () {
    expect(parse('Запиши врача в свободное время').action, 'clarify');
    expect(
      () => parse('Запиши врача на 20 октября 2027 в свободное время'),
      throwsFormatException,
    );
  });
  test('notes and statistics do not select task-only extraction', () {
    expect(
      AiActions.requestsNewTask('Создай заметку про завтра в 13:30'),
      isFalse,
    );
    expect(AiActions.requestsNewTask('Запиши статистику за завтра'), isFalse);
    expect(
      AiActions.requestsNewTask('Запланируй все задачи на завтра'),
      isFalse,
    );
    final input = AiTimeInput.fromRequest(
      'Встреча на субботу в 13:30 или 14:00',
    );
    expect(input.question, isNotNull);
  });
  test('automatic planning also uses the configured duration when omitted', () {
    final state = snapshot(busy: [Task.create('work', 'Работа')]);
    final draft = AiActions.parse(
      '{"action":"plan","task_ids":["work"],"days":1,"minutes":120}',
      state,
      now,
      request: 'Распредели мои задачи на завтра',
    );
    expect(draft.action, 'plan');
    expect(
      draft.blocks.single.end.difference(draft.blocks.single.start),
      const Duration(minutes: 45),
    );
  });
  test('nonexistent daylight-saving time is rejected', () {
    final zone = tz.getLocation('Europe/Berlin');
    expect(
      AiActions.freeSlot(
        snapshot(),
        tz.TZDateTime(zone, 2027, 3, 28),
        now,
        30,
        2 * 60,
        3 * 60 + 30,
        zone,
      ),
      tz.TZDateTime(zone, 2027, 3, 28, 3),
    );
  });
  test(
    'a weekday without a clock picks a free slot near the middle of the day',
    () {
      final draft = parse('Запланируй стоматолога в пятницу', time: '03:00');
      expect(draft.action, 'task');
      expect(draft.data['start'], '2026-10-23T10:05:00.000Z');
      expect(draft.data['auto_scheduled'], isTrue);
    },
  );
  test('morning and evening narrow the automatic search window', () {
    expect(
      parse('Запиши врача в пятницу утром').data['start'],
      '2026-10-23T06:35:00.000Z',
    );
    expect(
      parse('Запиши врача в пятницу вечером').data['start'],
      '2026-10-23T15:35:00.000Z',
    );
  });
  test(
    'midday occupancy selects the nearest available slot and earlier tie',
    () {
      final state = snapshot(
        minutes: 30,
        busy: [
          block(
            'busy',
            DateTime.utc(2026, 10, 23, 9),
            DateTime.utc(2026, 10, 23, 11),
          ),
        ],
      );
      final draft = parse('Запланируй врача в пятницу', state: state);
      expect(draft.data['start'], '2026-10-23T11:00:00.000Z');
    },
  );
  test(
    'this, next and bare weekday follow explicit calendar-week semantics',
    () {
      final zone = tz.getLocation('Europe/Moscow');
      final today = tz.TZDateTime(zone, 2026, 10, 20, 11);
      for (final entry in {
        'эту субботу': '2026-10-24',
        'следующую субботу': '2026-10-31',
        'в субботу': '2026-10-24',
        'в субботу на следующей неделе': '2026-10-31',
        'в эту пятницу': '2026-10-23',
        'в следующий понедельник': '2026-10-26',
        'в этот понедельник': '2026-10-19',
      }.entries) {
        expect(
          dayKey(AiActions.requestDate(entry.key, today, zone)!),
          entry.value,
          reason: entry.key,
        );
      }
      expect(
        dayKey(
          AiActions.requestDate(
            'в пятницу',
            tz.TZDateTime(zone, 2026, 10, 23),
            zone,
          )!,
        ),
        '2026-10-23',
      );
      expect(
        dayKey(
          AiActions.requestDate(
            'следующий понедельник',
            tz.TZDateTime(zone, 2026, 12, 31),
            zone,
          )!,
        ),
        '2027-01-04',
      );
    },
  );
  test('an interrupted command retains its original relative date', () {
    final draft = AiActions.parse(
      '{"action":"task","title":"Врач"}',
      snapshot(),
      DateTime.utc(2026, 10, 21, 8),
      request: 'Запиши врача на завтра',
      referenceTime: DateTime.utc(2026, 10, 20, 8),
    );
    expect(draft.data['start'], '2026-10-21T10:05:00.000Z');
  });
  test('statistics for today override a model-invented period', () {
    final draft = AiActions.parse(
      '{"action":"statistics","date":"2026-01-01","days":7}',
      snapshot(),
      now,
      request: 'Покажи статистику за сегодня',
    );
    expect(draft.data['date'], '2026-10-20');
    expect(draft.data['days'], 1);
  });
}
