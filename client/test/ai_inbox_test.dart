import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:record/record.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/ai_models.dart';
import 'package:yggvion/data/ai_service.dart';
import 'package:yggvion/data/ai_speech.dart';
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/reminders.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/domain/ai_proposal.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/ai_page.dart';
import 'package:yggvion/ui/ai_voice_button.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/theme.dart';

class FileRecorder implements AudioRecorder {
  String? path;
  int starts = 0, stops = 0;
  bool disposed = false;
  Completer<bool>? permission;
  @override
  Future<bool> hasPermission({bool request = true}) async =>
      permission == null ? true : await permission!.future;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    starts++;
    this.path = path;
    await File(path).writeAsBytes(List.filled(128, 0));
  }

  @override
  Future<String?> stop() async {
    stops++;
    return path;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FileSpeech implements AiSpeechTranscriber {
  int calls = 0;
  bool fail = false;
  Completer<String>? pending;
  @override
  Future<String> transcribe(String modelPath, String recordingPath) async {
    calls++;
    expect(await File(recordingPath).exists(), isTrue);
    if (fail) throw StateError('transcription unavailable');
    return pending == null
        ? 'Создай заметку: купить молоко'
        : await pending!.future;
  }
}

class InboxLanguage implements AiLanguageRuntime {
  int calls = 0;
  Completer<String>? pending;
  String answer = '{"action":"note","content":"Купить молоко"}';
  @override
  Future<String> interpret(
    String path,
    String system,
    String input, {
    Map<String, dynamic>? schema,
  }) async {
    calls++;
    return pending == null ? answer : await pending!.future;
  }

  @override
  Future<void> close() async {
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(StateError('cancelled'));
    }
  }
}

Future<void> until(bool Function() check) async {
  final limit = DateTime.now().add(const Duration(seconds: 5));
  while (!check() && DateTime.now().isBefore(limit)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(check(), isTrue, reason: 'Timed out waiting for local AI work');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;
  late Repository repo;
  late AiService ai;
  late FileRecorder recorder;
  late FileSpeech speech;
  late InboxLanguage language;
  bool providerOwnsRepo = false;
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    providerOwnsRepo = false;
    dir = await Directory.systemTemp.createTemp('yggvion-inbox-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => dir.path);
    repo = Repository(
      LocalDatabase(NativeDatabase.memory()),
      clock: () => DateTime.utc(2026, 10, 20, 8),
    );
    await repo.initialize(timezone: 'Europe/Moscow');
    recorder = FileRecorder();
    speech = FileSpeech();
    language = InboxLanguage();
    ai = AiService(
      repo,
      recorderFactory: () => recorder,
      transcriber: speech,
      runtimeFactory: () => language,
    );
    await ai.initialize();
    await ai.setEnabled(true);
    final models = await ai.directory;
    await models.create(recursive: true);
    for (final name in [ai.selected.file, speechModel.file]) {
      await File('${models.path}/$name').writeAsString('fixture');
    }
    await ai.select(ai.selected);
  });
  tearDown(() async {
    await ai.shutdown();
    await repo.db.close();
    if (!providerOwnsRepo) repo.dispose();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
  });
  Future<int> count(String table) async =>
      (await repo.db
              .customSelect('SELECT COUNT(*) AS n FROM $table')
              .getSingle())
          .read<int>('n');

  Future<void> pumpVoiceButton(
    WidgetTester tester, {
    ValueNotifier<bool>? visible,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [aiProvider.overrideWith((ref) => ai)],
      child: MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          floatingActionButton: visible == null
              ? const AiVoiceButton()
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, show, _) =>
                      show ? const AiVoiceButton() : const SizedBox.shrink(),
                ),
        ),
      ),
    ),
  );

  Future<TestGesture> holdMicrophone(WidgetTester tester) async {
    late TestGesture gesture;
    // Native recording/file IO uses the real event loop, including the gesture
    // deadline. Keep it out of the widget test's fake timer zone.
    await tester.runAsync(() async {
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('ai-record'))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
    });
    await tester.pump();
    return gesture;
  }

  Future<void> settleRecorder(WidgetTester tester) async {
    // Let native/file futures complete while rendering the resulting state.
    // pumpAndSettle alone advances fake time and cannot flush those futures.
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  test(
    'recording does not load speech or language models; only send starts work',
    () async {
      speech.pending = Completer<String>();
      await ai.startRecording();
      expect(ai.recording, isTrue);
      expect(recorder.starts, 1);
      expect(speech.calls, 0);
      expect(language.calls, 0);
      expect(ai.proposals, isEmpty);
      await ai.finishRecording();
      await until(() => speech.calls == 1);
      expect(ai.recording, isFalse);
      expect(ai.proposals.single.state, AiProposalState.transcribing);
      speech.pending!.complete('Создай заметку: купить молоко');
      await until(() => !ai.processing);
      expect(ai.proposals.single.state, AiProposalState.ready);
      expect(language.calls, 1);
      expect(await File(recorder.path!).exists(), isFalse);
    },
  );

  test(
    'voice files, transcript and suggestions never enter sync or attachments',
    () async {
      final records = await count('records'), outbox = await count('outbox');
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => !ai.processing);
      expect(await count('files'), 0);
      expect(await count('records'), records);
      expect(await count('outbox'), outbox);
      expect(await repo.db.meta('ai_inbox'), contains('купить молоко'));
      final item = ai.proposals.single;
      await Future.wait([ai.confirm(item), ai.confirm(item)]);
      expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), hasLength(1));
      expect(await count('files'), 0);
      expect(await count('outbox'), outbox + 1);
      expect(item.state, AiProposalState.applied);
      // Recovery after a crash between applying and persisting the UI status.
      item.state = AiProposalState.ready;
      await ai.confirm(item);
      expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), hasLength(1));
    },
  );

  test(
    'a voice message keeps Monday 12.30 through confirmation and storage',
    () async {
      speech.pending = Completer<String>()
        ..complete('Поставь событие на понедельник 12.30');
      language.answer = '{"action":"task","title":"Событие"}';
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => !ai.processing);
      final item = ai.proposals.single;
      expect(item.state, AiProposalState.ready);
      expect(item.draft!.summary, contains('26 октября · 12:30'));
      expect(repo.snapshot.tasks, isEmpty);
      await ai.confirm(item);
      final block = repo.snapshot.blocks.single;
      expect(block.start, DateTime.utc(2026, 10, 26, 9, 30));
      expect(block.end, DateTime.utc(2026, 10, 26, 10));
      expect(item.state, AiProposalState.applied);
      expect(await File(recorder.path!).exists(), isFalse);
    },
  );

  test(
    'failed transcription keeps audio locally and retry removes it on success',
    () async {
      speech.fail = true;
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => !ai.processing);
      final item = ai.proposals.single;
      expect(item.state, AiProposalState.failed);
      expect(await File(recorder.path!).exists(), isTrue);
      speech.fail = false;
      await ai.retry(item);
      await until(() => !ai.processing);
      expect(item.state, AiProposalState.ready);
      expect(item.audio, isNull);
      expect(await File(recorder.path!).exists(), isFalse);
    },
  );

  test(
    'cancelled microphone permission cannot start a late recording',
    () async {
      recorder.permission = Completer<bool>();
      final starting = ai.startRecording();
      await ai.cancelRecording();
      recorder.permission!.complete(true);
      await starting;
      expect(recorder.starts, 0);
      expect(ai.recording, isFalse);
      expect(speech.calls, 0);
    },
  );

  test('cancelling another recording resumes the waiting proposal', () async {
    speech.pending = Completer<String>();
    await ai.startRecording();
    await ai.finishRecording();
    await until(() => speech.calls == 1);
    await ai.startRecording();
    speech.pending!.complete('Создай заметку: купить молоко');
    await until(() => !ai.processing);
    expect(ai.proposals.single.state, AiProposalState.queued);
    expect(language.calls, 0);
    await ai.cancelRecording();
    await until(() => !ai.processing);
    expect(ai.proposals.single.state, AiProposalState.ready);
    expect(language.calls, 1);
    expect(speech.calls, 1);
  });

  test(
    'switching AI off rejects late transcripts and deletes all local temporary files',
    () async {
      speech.pending = Completer<String>();
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => speech.calls == 1);
      final disabling = ai.setEnabled(false);
      speech.pending!.complete('Создай заметку: поздний результат');
      await disabling;
      expect(ai.proposals, isEmpty);
      expect(await (await ai.recordingsDirectory).exists(), isFalse);
      expect(await (await ai.directory).exists(), isFalse);
      expect(language.calls, 0);
      expect(await repo.db.meta('ai_inbox'), '[]');
    },
  );

  test(
    'dismissed active audio is cleaned up after native transcription finishes',
    () async {
      speech.pending = Completer<String>();
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => speech.calls == 1);
      await ai.dismiss(ai.proposals.single);
      speech.pending!.complete('Создай заметку: молоко');
      await until(() => !ai.processing);
      expect(ai.proposals, isEmpty);
      expect(await File(recorder.path!).exists(), isFalse);
      expect(language.calls, 0);
    },
  );

  test(
    'interrupted queue resumes after restart and does not repeat applied actions',
    () async {
      await ai.shutdown();
      final item = AiProposal(
        id: 'recovery-1',
        createdAt: repo.now(),
        input: 'Создай заметку: молоко',
        state: AiProposalState.interpreting,
      );
      await repo.db.setMeta('ai_inbox', jsonEncode([item.toJson()]));
      ai = AiService(repo, transcriber: speech, runtimeFactory: () => language);
      await ai.initialize();
      await until(() => !ai.processing);
      expect(ai.proposals.single.state, AiProposalState.ready);
      await ai.confirm(ai.proposals.single);
      await ai.shutdown();
      ai = AiService(repo, transcriber: speech, runtimeFactory: () => language);
      await ai.initialize();
      expect(ai.proposals.single.state, AiProposalState.applied);
      expect(language.calls, 1);
    },
  );

  test(
    'backgrounding defers LLM work until returning, while preserving the recording',
    () async {
      speech.pending = Completer<String>();
      await ai.startRecording();
      await ai.finishRecording();
      await until(() => speech.calls == 1);
      ai.didChangeAppLifecycleState(AppLifecycleState.paused);
      speech.pending!.complete('Создай заметку: молоко');
      await until(() => !ai.processing);
      expect(language.calls, 0);
      expect(ai.proposals.single.state, AiProposalState.queued);
      ai.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await until(() => !ai.processing);
      expect(ai.proposals.single.state, AiProposalState.ready);
      expect(language.calls, 1);
    },
  );

  test(
    'unknown model files and obsolete selection are removed on startup',
    () async {
      await ai.shutdown();
      final cache = await ai.directory;
      final obsolete = File('${cache.path}/retired-experiment.gguf');
      await obsolete.writeAsString('obsolete');
      await repo.db.setMeta('ai_model', 'retired-model');
      ai = AiService(repo, transcriber: speech, runtimeFactory: () => language);
      await ai.initialize();
      expect(await obsolete.exists(), isFalse);
      expect(ai.selected.id, languageModels.first.id);
      expect(ai.ready, isTrue);
    },
  );

  test('completion markers roll back together with calendar writes', () async {
    final before = await count('outbox');
    await expectLater(
      repo.commitComputed(
        () async => [Task.create('rollback-task', 'Rollback')],
        writeLocalState: () async => throw StateError('storage failure'),
      ),
      throwsStateError,
    );
    expect(await repo.db.entity('rollback-task'), isNull);
    expect(await count('outbox'), before);
  });

  test('saved audio filename cannot escape the device-local directory', () {
    expect(
      () => AiProposal.fromJson({
        'id': 'valid',
        'created_at': repo.now().toIso8601String(),
        'input': '',
        'audio': '../../attachments/private.wav',
        'seconds': 1,
        'state': 'queued',
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'AI is a fifth mobile tab, previews fit and disabling returns to the calendar',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sync = SyncService(repo), reminders = ReminderService(repo);
      providerOwnsRepo = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) => repo),
            aiProvider.overrideWith((ref) => ai),
            syncProvider.overrideWithValue(sync),
            remindersProvider.overrideWithValue(reminders),
          ],
          child: const YggvionApp(),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(
        navigation.destinations.map((d) => (d as NavigationDestination).label),
        ['Канбан', 'Планировщик', 'Заметки', 'AI', 'Сегодня'],
      );
      final microphone = find.byKey(const ValueKey('ai-record'));
      final create = find.byKey(const ValueKey('create-menu'));
      expect(microphone, findsOneWidget);
      expect(tester.getCenter(microphone).dx, tester.getCenter(create).dx);
      expect(
        tester.getBottomLeft(microphone).dy,
        lessThan(tester.getTopLeft(create).dy),
      );
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/today_ai_390.png'),
      );
      final recordingGesture = await holdMicrophone(tester);
      await settleRecorder(tester);
      final recordingStatus = find.byKey(const ValueKey('ai-recording-status'));
      expect(recordingStatus, findsOneWidget);
      expect(tester.getTopLeft(recordingStatus).dx, greaterThanOrEqualTo(0));
      expect(
        tester.getTopRight(recordingStatus).dx,
        lessThan(tester.getTopLeft(microphone).dx),
      );
      await tester.runAsync(recordingGesture.cancel);
      await settleRecorder(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-planner')));
      await tester.pumpAndSettle();
      expect(microphone, findsNothing);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-ai')));
      await tester.pumpAndSettle();
      expect(microphone, findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/ai_empty_390.png'),
      );
      language.answer = '{"action":"task","title":"Стоматолог"}';
      await tester.runAsync(() async {
        await ai.submitText('Запланируй стоматолога в пятницу');
        await until(() => !ai.processing);
      });
      await tester.pumpAndSettle();
      expect(find.text('Добавить в календарь'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/ai_proposal_390.png'),
      );
      await tester.runAsync(() => ai.setEnabled(false));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-page')), findsNothing);
      expect(find.byKey(const ValueKey('mobile-nav-ai')), findsNothing);
      expect(microphone, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      reminders.dispose();
    },
  );

  testWidgets(
    'phone inbox stays responsive and work survives leaving the tab',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final visible = ValueNotifier(true);
      language.pending = Completer<String>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiProvider.overrideWith((ref) => ai)],
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: visible,
                builder: (_, show, _) =>
                    show ? const AiPage() : const Text('Календарь'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await ai.submitText('Создай заметку: молоко');
        await until(() => language.calls == 1);
      });
      await tester.pump();
      expect(find.text('Готовим предложение…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      visible.value = false;
      await tester.pump();
      await tester.runAsync(() async {
        language.pending!.complete(
          '{"action":"note","content":"Купить молоко"}',
        );
        await until(() => !ai.processing);
      });
      visible.value = true;
      await tester.pump();
      expect(find.text('Сохранить заметку'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      visible.dispose();
    },
  );

  testWidgets('hold records with haptic feedback; release sends once', (
    tester,
  ) async {
    final haptics = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await pumpVoiceButton(tester);
    final microphone = find.byKey(const ValueKey('ai-record'));
    final surface = find.byKey(const ValueKey('ai-record-surface'));
    final idleBounds = tester.getRect(surface);
    await tester.tap(microphone);
    await tester.pump();
    expect(recorder.starts, 0);
    expect(haptics, isEmpty);
    final gesture = await holdMicrophone(tester);
    await tester.runAsync(() => until(() => haptics.isNotEmpty));
    await settleRecorder(tester);
    expect(haptics.single.arguments, 'HapticFeedbackType.mediumImpact');
    expect(recorder.starts, 1);
    expect(ai.recording, isTrue);
    expect(tester.getRect(surface).width, greaterThan(idleBounds.width * 1.3));
    expect(find.text('Отпустите, чтобы отправить'), findsOneWidget);
    expect(speech.calls, 0);
    expect(language.calls, 0);
    // Releasing outside the original target must still finish the recording.
    await gesture.moveBy(const Offset(-90, -20));
    await tester.pump();
    expect(ai.recording, isTrue);
    expect(recorder.stops, 0);
    expect(speech.calls, 0);
    await tester.runAsync(() async {
      await gesture.up();
      await until(() => ai.proposals.length == 1 && !ai.processing);
    });
    await settleRecorder(tester);
    expect(ai.recording, isFalse);
    expect(tester.getRect(surface).width, closeTo(idleBounds.width, .01));
    expect(recorder.stops, 1);
    expect(speech.calls, 1);
    expect(ai.proposals.single.state, AiProposalState.ready);
    expect(find.byKey(const ValueKey('ai-recording-status')), findsNothing);
    expect(
      find.text('Голосовое отправлено. Предложение появится в AI.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'release before microphone permission prevents a late recording',
    (tester) async {
      recorder.permission = Completer<bool>();
      await pumpVoiceButton(tester);
      final gesture = await holdMicrophone(tester);
      expect(ai.recording, isTrue);
      await tester.runAsync(() async {
        await gesture.up();
        await until(() => !ai.recording);
        recorder.permission!.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(recorder.starts, 0);
      expect(ai.proposals, isEmpty);
      expect(speech.calls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final leaveScreen in [false, true]) {
    testWidgets(
      '${leaveScreen ? 'leaving Today' : 'cancelling the pointer'} discards the held recording',
      (tester) async {
        final visible = ValueNotifier(true);
        await pumpVoiceButton(tester, visible: visible);
        final gesture = await holdMicrophone(tester);
        await tester.runAsync(() async {
          await until(() => recorder.starts == 1);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
        expect(ai.recording, isTrue);
        await tester.runAsync(() async {
          if (leaveScreen) {
            visible.value = false;
            await tester.pump();
          } else {
            await gesture.cancel();
          }
          await until(
            () =>
                !ai.recording &&
                recorder.disposed &&
                !File(recorder.path!).existsSync(),
          );
        });
        await settleRecorder(tester);
        expect(ai.proposals, isEmpty);
        expect(
          await tester.runAsync(() => File(recorder.path!).exists()),
          isFalse,
        );
        expect(speech.calls, 0);
        expect(tester.takeException(), isNull);
        if (leaveScreen) await gesture.up();
        await tester.pumpWidget(const SizedBox());
        visible.dispose();
      },
    );
  }

  testWidgets('denied microphone permission leaves the button usable', (
    tester,
  ) async {
    recorder.permission = Completer<bool>()..complete(false);
    await pumpVoiceButton(tester);
    final gesture = await holdMicrophone(tester);
    await tester.runAsync(gesture.up);
    await tester.runAsync(() => until(() => recorder.disposed));
    await settleRecorder(tester);
    expect(ai.recording, isFalse);
    expect(recorder.starts, 0);
    expect(ai.proposals, isEmpty);
    expect(find.textContaining('Разрешите доступ к микрофону'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
