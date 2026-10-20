import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/ai_models.dart';
import 'package:yggvion/data/ai_service.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/ai_actions.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/ui/ai_settings.dart';
import 'package:yggvion/ui/providers.dart';

class ControlledRuntime implements AiLanguageRuntime {
  int calls = 0, closes = 0;
  final started = Completer<void>(), response = Completer<String>();
  @override
  Future<String> interpret(String path, String system, String input) {
    calls++;
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
  testWidgets('microphone appears only when AI is enabled', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiProvider.overrideWith((ref) => ai)],
        child: const MaterialApp(home: Scaffold(body: AssistantButton())),
      ),
    );
    expect(find.byKey(const ValueKey('ai-microphone')), findsNothing);
    await tester.runAsync(() => ai.setEnabled(true));
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-microphone')), findsOneWidget);
    await tester.runAsync(() => ai.setEnabled(false));
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-microphone')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
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
        'clarify',
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
}
