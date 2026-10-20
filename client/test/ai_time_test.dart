import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/ai_actions.dart';
import 'package:yggvion/domain/ai_time.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  final snapshot = Snapshot([
    Entity(
      id: 'settings',
      kind: 'settings',
      data: {
        'timezone': 'Europe/Moscow',
        'default_minutes': 30,
        'reminders': [0],
      },
    ),
  ]);
  final now = DateTime.utc(2026, 10, 20, 8, 40);
  AiDraft task(
    String request, {
    String time = '',
    String date = '2026-10-24',
  }) => AiActions.parse(
    jsonEncode({
      'action': 'task',
      'title': 'Посещение стоматолога',
      'date': date,
      'time': time,
    }),
    snapshot,
    now,
    request: request,
  );

  test('the exact iPhone command recovers time omitted by the model', () {
    final draft = task(
      'Запиши меня с томатологу на следующую субботу на 13-30.',
    );
    expect(draft.action, 'task');
    expect(draft.data['start'], '2026-10-31T10:30:00.000Z');
    expect(draft.data['end'], '2026-10-31T11:00:00.000Z');
    expect(draft.summary, contains('31 октября · 13:30'));
  });

  for (final entry in {
    'Встреча завтра в 13:30': '13:30',
    'Встреча завтра на 13-30.': '13:30',
    'Встреча завтра к 13.30': '13:30',
    'Поставь событие на понедельник 12.30': '12:30',
    'Поставь событие на понедельник, 12.30.': '12:30',
    'Встреча завтра 12.30': '12:30',
    'Встреча в пятницу 12-30': '12:30',
    'Встреча в пятницу 12.05': '12:05',
    'Встреча в пятницу двенадцать тридцать': '12:30',
    'Встреча завтра 12 30': '12:30',
    'Встреча завтра на 13 — 30': '13:30',
    'Встреча завтра в 13 30': '13:30',
    'Встреча завтра на 13 30': '13:30',
    'Встреча завтра в 13 часов 30 минут': '13:30',
    'Встреча завтра в тринадцать тридцать': '13:30',
    'Встреча завтра в тринадцать часов тридцать минут': '13:30',
    'Встреча завтра к двадцать трем': null,
    'Встреча завтра в двадцать три сорок пять': '23:45',
    'Встреча завтра в двадцать три пятьдесят девять': '23:59',
    'Встреча завтра в 7:05': '07:05',
    'Встреча завтра в 7:05 вечера': '19:05',
    'Встреча завтра в 7:05 утра': '07:05',
    'Встреча завтра в 7:05 pm': '19:05',
    'Встреча завтра в семь ноль пять': '07:05',
    'Встреча завтра в семь часов пять минут': '07:05',
    'Встреча завтра в семь вечера': '19:00',
    'Встреча завтра в час дня': '13:00',
    'Встреча завтра в час тридцать дня': '13:30',
    'Встреча завтра в двенадцать ночи': '00:00',
    'Встреча завтра в двенадцать дня': '12:00',
    'Встреча завтра в пятнадцать часов': '15:00',
    'Встреча завтра в 15': '15:00',
    'Кофе в 13:30, запланируй именно на 13-30': '13:30',
  }.entries) {
    test('explicit time: ${entry.key}', () {
      expect(AiTimeInput.fromRequest(entry.key).time, entry.value);
    });
  }
  test('explicit user time wins over a different model-generated time', () {
    final draft = task('Стоматолог в субботу на 13-30', time: '15:00');
    expect(draft.data['start'], '2026-10-24T10:30:00.000Z');
    expect(AiTimeInput.fromRequest('Встреча в 13:30 дня').time, '13:30');
    expect(
      AiTimeInput.fromRequest('Встреча в тринадцать тридцать дня').time,
      '13:30',
    );
  });
  test('dotted ranges and alternatives retain every explicit clock', () {
    final range = AiTimeInput.fromRequest(
      'Встреча в понедельник 12.30 до 13.45',
    );
    expect(range.time, '12:30');
    expect(range.endTime, '13:45');
    expect(range.rangeMinutes, 75);
    expect(
      AiTimeInput.fromRequest('Встреча в понедельник 12.30 или 13.45').question,
      isNotNull,
    );
    expect(
      AiTimeInput.fromRequest('Встреча в понедельник 12.75').question,
      isNotNull,
    );
  });
  test(
    'numeric punctuation is accepted but an unrequested model clock is ignored',
    () {
      expect(AiActions.clock('13-30'), 810);
      expect(
        task('Стоматолог в субботу', time: '13-30').data['start'],
        '2026-10-24T10:15:00.000Z',
      );
      expect(AiActions.clock('7:05'), 425);
    },
  );
  test('a day without a clock is enough; a clock without a day still asks', () {
    expect(task('Стоматолог в субботу').action, 'task');
    expect(task('Стоматолог на 30 минут в субботу').action, 'task');
    expect(task('Стоматолог в субботу в 13:30', date: '').action, 'task');
    expect(task('Стоматолог в 13:30', date: '').action, 'clarify');
  });
  test(
    'invalid or alternative clocks cannot be repaired by model guessing',
    () {
      for (final request in [
        'Стоматолог на 25-30',
        'Стоматолог в 13:75',
        'Стоматолог в двадцать девять часов',
        'Стоматолог в 13:30 или 14:00',
      ]) {
        expect(task(request, time: '13:30').action, 'clarify', reason: request);
      }
    },
  );
  test('dates, durations, versions and phone numbers are not clock times', () {
    for (final request in [
      'Запиши на 13.05.2027',
      'Запиши на 13.05',
      'Запиши на 13-05-2027',
      'Запиши на 13 октября 2027',
      'Задача в 2027 году',
      'Задача на 30 минут',
      'Задача на час',
      'Работать на 13 часов',
      'Встреча через 13 часов',
      'Встреча через 13:30',
      'Записать версию 13.30',
      'Обновить версию 12.30 в понедельник',
      'Встреча в понедельник на 30 минут',
      'Встреча в понедельник 12.30.2027',
      'Заметка: номер +7 900 123-13-30',
    ]) {
      expect(AiTimeInput.fromRequest(request).time, isNull, reason: request);
      expect(
        AiTimeInput.fromRequest(request).question,
        isNull,
        reason: request,
      );
    }
  });
  test('ranges keep model duration; note content remains verbatim', () {
    final range = AiActions.parse(
      jsonEncode({
        'action': 'task',
        'title': 'Встреча',
        'date': '2026-10-24',
        'time': '13:30',
        'minutes': 60,
      }),
      snapshot,
      now,
      request: 'Встреча в субботу с 13:30 до 14:30',
    );
    expect(range.data['end'], '2026-10-24T11:30:00.000Z');
    final note = AiActions.parse(
      jsonEncode({'action': 'note', 'content': 'Дежурство 13-30'}),
      snapshot,
      now,
      request: 'Создай заметку: Дежурство 13-30',
    );
    expect(note.data['content'], 'Дежурство 13-30');
  });
}
