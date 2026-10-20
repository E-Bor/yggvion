import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:llamadart/llamadart.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/ai_models.dart';
import 'package:yggvion/data/ai_service.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/ai_actions.dart';
import 'package:yggvion/domain/ai_prompt.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/ui/ai_page.dart';
import 'package:yggvion/ui/providers.dart';

class ControlledRuntime implements AiLanguageRuntime {
  int calls = 0, closes = 0;
  String? lastSystem, lastInput;
  Map<String, dynamic>? lastSchema;
  final started = Completer<void>(), response = Completer<String>();
  @override
  Future<String> interpret(
    String path,
    String system,
    String input, {
    Map<String, dynamic>? schema,
  }) {
    calls++;
    lastSystem = system;
    lastInput = input;
    lastSchema = schema;
    started.complete();
    return response.future;
  }

  @override
  Future<void> close() async {
    closes++;
    if (!response.isCompleted) response.completeError(StateError('cancelled'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Repository repo;
  late Directory dir;
  late AiService ai;
  late ControlledRuntime runtime;
  final now = DateTime.utc(2026, 10, 20, 8);
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yggvion-ai-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize(timezone: 'Europe/Moscow');
    runtime = ControlledRuntime();
    ai = AiService(repo, runtimeFactory: () => runtime);
    await ai.initialize();
  });
  tearDown(() async {
    await ai.shutdown();
    await repo.db.close();
    repo.dispose();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
  });
  AiDraft parse(Map<String, dynamic> d) =>
      AiActions.parse(jsonEncode(d), repo.snapshot, now);

  test(
    'disabled AI cannot invoke native inference and hides the microphone',
    () async {
      expect(ai.enabled, isFalse);
      await expectLater(ai.interpret('Создай заметку'), throwsStateError);
      expect(runtime.calls, 0);
      final cache = await ai.directory;
      await cache.create();
      await File('${cache.path}/stale.gguf').writeAsString('weights');
      await ai.initialize();
      expect(await cache.exists(), isFalse);
    },
  );
  testWidgets('AI page appears only when AI is enabled', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiProvider.overrideWith((ref) => ai)],
        child: const MaterialApp(home: Scaffold(body: AiPage())),
      ),
    );
    expect(find.byKey(const ValueKey('ai-page')), findsNothing);
    await tester.runAsync(() => ai.setEnabled(true));
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-page')), findsOneWidget);
    await tester.runAsync(() => ai.setEnabled(false));
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-page')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  for (final smallInstalled in [false, true]) {
    test(
      'retired Base is removed; Small ${smallInstalled ? 'is reused' : 'must be downloaded'}',
      () async {
        await repo.db.setMeta('ai_enabled', 'true');
        await repo.db.setMeta('ai_speech_model', 'whisper-base');
        final cache = await ai.directory;
        await cache.create();
        final base = File('${cache.path}/ggml-base.bin');
        final partial = File('${cache.path}/ggml-base.bin.part');
        await base.writeAsString('test legacy model');
        await partial.writeAsString('test partial model');
        await File(
          '${cache.path}/${ai.selected.file}',
        ).writeAsString('test model');
        final small = File('${cache.path}/${speechModel.file}');
        if (smallInstalled) await small.writeAsString('test small model');
        await ai.initialize();
        expect(ai.speechSelected.id, 'whisper-small');
        expect(await repo.db.meta('ai_speech_model'), 'whisper-small');
        expect(await base.exists(), isFalse);
        expect(await partial.exists(), isFalse);
        expect(await small.exists(), smallInstalled);
        expect(ai.ready, smallInstalled);
        if (!smallInstalled) {
          expect(ai.status, contains('скачайте Whisper Small'));
        }
      },
    );
  }
  test(
    'switching off cancels active inference, removes models and never writes late output',
    () async {
      await ai.setEnabled(true);
      ai.ready = true;
      final cache = await ai.directory;
      await cache.create();
      await File('${cache.path}/model.gguf').writeAsString('weights');
      final running = ai.interpret('Создай задачу');
      final failed = expectLater(running, throwsStateError);
      await runtime.started.future;
      await ai.setEnabled(false);
      await failed;
      expect(runtime.closes, greaterThan(0));
      expect(await cache.exists(), isFalse);
      expect(ai.busy, isFalse);
      expect(repo.snapshot.tasks, isEmpty);
    },
  );
  test(
    'explicit local time converts to UTC; missing time asks a question',
    () async {
      final draft = parse({
        'action': 'task',
        'title': 'Стоматолог',
        'date': '2026-10-26',
        'time': '15:00',
        'minutes': 60,
      });
      expect(draft.data['start'], '2026-10-26T12:00:00.000Z');
      await ai.setEnabled(true);
      await ai.apply(draft);
      expect(repo.snapshot.tasks.single.title, 'Стоматолог');
      expect(
        repo.snapshot.blocks.single.end.difference(
          repo.snapshot.blocks.single.start,
        ),
        const Duration(hours: 1),
      );
      expect(
        parse({'action': 'task', 'title': 'Врач', 'date': '2026-10-26'}).action,
        'task',
      );
      expect(
        () => parse({
          'action': 'task',
          'title': 'Врач',
          'date': '2026-02-31',
          'time': '15:00',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'voice time survives interpretation, preview and saving with the default duration',
    () async {
      const input = 'Запиши меня с томатологу на следующую субботу на 13-30.';
      await ai.setEnabled(true);
      ai.ready = true;
      final pending = ai.interpret(input);
      await runtime.started.future;
      expect(runtime.lastInput, input);
      expect(runtime.lastSystem, contains('Явное время начала: 13:30'));
      expect(runtime.lastSchema, AiActions.taskSchema());
      runtime.response.complete(
        jsonEncode({
          'action': 'task',
          'title': 'Посещение стоматолога',
          'date': '2026-10-24',
          'time': '',
        }),
      );
      final draft = await pending;
      expect(draft.action, 'task');
      expect(draft.summary, contains('13:30'));
      expect(repo.snapshot.tasks, isEmpty);
      await ai.apply(draft);
      final block = repo.snapshot.blocks.single;
      expect(block.start, DateTime.utc(2026, 10, 31, 10, 30));
      expect(block.end, DateTime.utc(2026, 10, 31, 11));
    },
  );
  for (final input in [
    'Запиши меня к стоматологу на следующую субботу на 13-30.',
    'Запиши на завтра свободное время',
  ]) {
    test(
      'complete appointment extracts content with a task-only schema: $input',
      () async {
        await ai.setEnabled(true);
        ai.ready = true;
        final pending = ai.interpret(input);
        await runtime.started.future;
        expect(runtime.lastSchema, AiActions.taskSchema());
        expect(runtime.lastSystem, contains('по умолчанию 30 минут'));
        runtime.response.complete(
          '{"action":"task","title":"Событие","minutes":120}',
        );
        final draft = await pending;
        expect(runtime.calls, 1);
        expect(runtime.closes, 1);
        expect(ai.busy, isFalse);
        expect(repo.snapshot.tasks, isEmpty);
        expect(draft.action, 'task');
        final start = DateTime.parse(draft.data['start'] as String);
        final end = DateTime.parse(draft.data['end'] as String);
        expect(end.difference(start), const Duration(minutes: 30));
      },
    );
  }
  for (final entry in {
    'Запланируй стоматолога в 13:30': 'На какую дату?',
    'Создай заметку про встречу в субботу в 13:30': 'Какой текст сохранить?',
    'Покажи статистику на завтра в 13:30': 'Какая статистика нужна?',
  }.entries) {
    test(
      'other missing information is not silently filled: ${entry.key}',
      () async {
        await ai.setEnabled(true);
        ai.ready = true;
        final pending = ai.interpret(entry.key);
        await runtime.started.future;
        runtime.response.complete(
          jsonEncode({'action': 'clarify', 'question': entry.value}),
        );
        final draft = await pending;
        expect(draft.action, 'clarify');
        expect(draft.summary, entry.value);
        expect(runtime.calls, 1);
        expect(repo.snapshot.tasks, isEmpty);
      },
    );
  }
  test('ambiguous times ask a question without loading the model', () async {
    await ai.setEnabled(true);
    ai.ready = true;
    final draft = await ai.interpret(
      'Запланируй стоматолога на субботу в 13:30 или 14:30',
    );
    expect(draft.action, 'clarify');
    expect(runtime.calls, 0);
    expect(runtime.closes, 0);
  });
  test('disabling AI cancels structured task extraction', () async {
    await ai.setEnabled(true);
    ai.ready = true;
    final pending = ai.interpret('Запланируй врача на субботу в 13:30');
    final failed = expectLater(pending, throwsStateError);
    await runtime.started.future;
    expect(runtime.lastSchema, AiActions.taskSchema());
    await ai.setEnabled(false);
    await failed;
    expect(runtime.closes, greaterThan(0));
    expect(ai.busy, isFalse);
    expect(repo.snapshot.tasks, isEmpty);
  });
  test('date-like text in a note is not validated as an appointment', () async {
    await ai.setEnabled(true);
    ai.ready = true;
    final pending = ai.interpret('Создай заметку: в примере ошибка 2026-02-31');
    await runtime.started.future;
    expect((runtime.lastSchema!['properties'] as Map)['action'], {
      'type': 'string',
      'enum': ['note'],
    });
    runtime.response.complete(
      '{"action":"note","content":"В примере ошибка 2026-02-31"}',
    );
    expect((await pending).data['content'], 'В примере ошибка 2026-02-31');
  });
  test('every action schema is accepted by the native grammar compiler', () {
    for (final input in [
      'Создай заметку: купить молоко',
      'Запланируй прогулку в пятницу',
      'Покажи статистику за сегодня',
      'Распредели мои задачи на неделю',
    ]) {
      final prompt = AiPrompt.build(input, repo.snapshot, now);
      expect(
        () => LlamaStructuredOutput.jsonSchema(
          schema: prompt.schema,
          decoder: (json) => json,
        ),
        returnsNormally,
        reason: input,
      );
    }
  });
  test(
    'new task in a free slot cannot be saved after the slot becomes occupied',
    () async {
      final draft = AiActions.parse(
        '{"action":"task","title":"Врач"}',
        repo.snapshot,
        now,
        request: 'Запиши врача на завтра в свободное время',
      );
      expect(draft.action, 'task');
      await repo.createTask(
        'Другая встреча',
        start: DateTime.parse(draft.data['start'] as String),
        end: DateTime.parse(draft.data['end'] as String),
      );
      await ai.setEnabled(true);
      await expectLater(ai.apply(draft), throwsStateError);
      expect(repo.snapshot.tasks, hasLength(1));
      expect(repo.snapshot.tasks.single.title, 'Другая встреча');
    },
  );
  test(
    'planner avoids occupied time, uses distinct blocks and rejects stale plan atomically',
    () async {
      final a = await repo.createTask('A'), b = await repo.createTask('B');
      await BirthdayService(repo).save('Test birthday', DateTime(1990, 10, 21));
      await repo.createTask(
        'Busy',
        start: DateTime.utc(2026, 10, 21, 6),
        end: DateTime.utc(2026, 10, 21, 7),
      );
      final draft = parse({
        'action': 'plan',
        'task_ids': [a.id, b.id],
        'date': '2026-10-21',
        'days': 1,
        'minutes': 30,
      });
      expect(draft.blocks.first.start.toUtc(), DateTime.utc(2026, 10, 21, 7));
      expect(draft.blocks.last.start, draft.blocks.first.end);
      expect(
        () => parse({
          'action': 'plan',
          'task_ids': [a.id],
          'date': '2027-10-21',
        }),
        throwsFormatException,
      );
      await repo.createTask(
        'New conflict',
        start: draft.blocks.first.start,
        end: draft.blocks.first.end,
      );
      await ai.setEnabled(true);
      await expectLater(ai.apply(draft), throwsStateError);
      expect(repo.snapshot.taskBlocks(a.id), isEmpty);
      expect(repo.snapshot.taskBlocks(b.id), isEmpty);
    },
  );
  test(
    'relative weekdays are calculated locally even when the model invents a date',
    () {
      final draft = AiActions.parse(
        jsonEncode({
          'action': 'task',
          'title': 'Стоматолог',
          'date': '2026-10-27',
          'time': '15:00',
          'minutes': 60,
        }),
        repo.snapshot,
        now,
        request: 'Запланируй на понедельник в 15:00 стоматолога на час',
      );
      expect(
        DateTime.parse(draft.data['start'] as String),
        DateTime.utc(2026, 10, 26, 12),
      );
      final nextMonth = AiActions.parse(
        jsonEncode({
          'action': 'task',
          'title': 'Звонок',
          'date': '2026-10-27',
          'time': '10:00',
        }),
        repo.snapshot,
        DateTime.utc(2026, 10, 31, 8),
        request: 'Звонок завтра в 10:00',
      );
      expect(
        DateTime.parse(nextMonth.data['start'] as String),
        DateTime.utc(2026, 11, 1, 7),
      );
    },
  );
  test(
    'statistics are calculated from stored data; unsafe actions and invented IDs are rejected',
    () async {
      await BirthdayService(repo).save('Test birthday', DateTime(1990, 10, 21));
      await repo.createTask(
        'Work',
        start: DateTime.utc(2026, 10, 21, 6),
        end: DateTime.utc(2026, 10, 21, 7),
      );
      expect(
        parse({
          'action': 'statistics',
          'date': '2026-10-21',
          'days': 1,
        }).summary,
        contains('Запланировано: 1 ч 0 мин'),
      );
      expect(
        () => parse({'action': 'shell', 'command': 'rm -rf /'}),
        throwsFormatException,
      );
      expect(
        () => parse({
          'action': 'plan',
          'task_ids': ['invented'],
          'date': '2026-10-21',
        }),
        throwsFormatException,
      );
      expect(
        () => parse({
          'action': 'task',
          'title': 'Work',
          'project_id': 'invented',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'hardware selection respects phone memory limits and desktop headroom',
    () {
      expect(
        const AiHardware(
          memoryBytes: 8 * 1073741824,
          freeBytes: 0,
          name: 'phone',
          mobile: true,
        ).recommended.id,
        'qwen-2',
      );
      expect(
        const AiHardware(
          memoryBytes: 16 * 1073741824,
          freeBytes: 0,
          name: 'Mac',
          mobile: false,
        ).recommended.id,
        'qwen-4',
      );
      expect(
        const AiHardware(
          memoryBytes: 32 * 1073741824,
          freeBytes: 0,
          name: 'Mac',
          mobile: false,
        ).recommended.id,
        'qwen-9',
      );
    },
  );

  final nativeModel = Platform.environment['YGGVION_TEST_LANGUAGE_MODEL'];
  test(
    'native model: explicit time, configured duration and free time for a new task',
    () async {
      await ai.shutdown();
      ai = AiService(repo);
      await ai.setEnabled(true);
      final cache = await ai.directory;
      await cache.create(recursive: true);
      await Link('${cache.path}/${ai.selected.file}').create(nativeModel!);
      ai.ready = true;
      final draft = await ai.interpret(
        'Запиши меня с томатологу на следующую субботу на 13-30.',
      );
      expect(draft.action, 'task', reason: draft.summary);
      expect(draft.data['start'], '2026-10-31T10:30:00.000Z');
      expect(draft.data['end'], '2026-10-31T11:00:00.000Z');
      expect(repo.snapshot.tasks, isEmpty);
      await repo.updateSettings(45, [0], 'Europe/Moscow');
      final configured = await ai.interpret(
        'Запиши меня к стоматологу на 24 октября 2026 в 13:30',
      );
      expect(configured.action, 'task', reason: configured.summary);
      expect(configured.data['start'], '2026-10-24T10:30:00.000Z');
      expect(configured.data['end'], '2026-10-24T11:15:00.000Z');
      final explicit = await ai.interpret(
        'Запиши меня к стоматологу на субботу в 13:30 на полчаса',
      );
      expect(explicit.action, 'task', reason: explicit.summary);
      expect(explicit.data['end'], '2026-10-24T11:00:00.000Z');
      await repo.createTask(
        'Занято',
        start: DateTime.utc(2026, 10, 21, 6),
        end: DateTime.utc(2026, 10, 21, 8),
      );
      final free = await ai.interpret('Запиши на завтра свободное время');
      expect(free.action, 'task', reason: free.summary);
      expect((free.data['title'] as String).toLowerCase(), contains('свободн'));
      expect(free.data['start'], '2026-10-21T10:05:00.000Z');
      expect(free.data['end'], '2026-10-21T10:50:00.000Z');
      expect(repo.snapshot.tasks, hasLength(1));
      await ai.apply(free);
      expect(repo.snapshot.tasks, hasLength(2));
    },
    skip: nativeModel == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
