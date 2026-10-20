import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../domain/ai_actions.dart';
import '../domain/ai_proposal.dart';
import '../domain/ai_prompt.dart';
import '../domain/models.dart';
import 'ai_models.dart';
import 'ai_speech.dart';
import 'repository.dart';

abstract interface class AiLanguageRuntime {
  Future<String> interpret(
    String path,
    String system,
    String input, {
    Map<String, dynamic>? schema,
  });
  Future<void> close();
}

class LlamaLanguageRuntime implements AiLanguageRuntime {
  final engine = LlamaEngine(LlamaBackend());
  @override
  Future<String> interpret(
    String path,
    String system,
    String input, {
    Map<String, dynamic>? schema,
  }) async {
    await engine.setModel(
      LlamaModel(ModelSource.path(path)),
      params: const ModelParams(contextSize: 4096),
    );
    return engine
        .create(
          [
            LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: input),
          ],
          enableThinking: false,
          params: const GenerationParams(maxTokens: 768, temp: 0.1),
          responseFormat: {
            'type': 'json_schema',
            'json_schema': {'schema': schema ?? AiActions.schema},
          },
        )
        .text();
  }

  @override
  Future<void> close() async {
    engine.cancelGeneration();
    await engine.dispose();
  }
}

class AiService extends ChangeNotifier with WidgetsBindingObserver {
  AiService(
    this.repo, {
    AiLanguageRuntime Function()? runtimeFactory,
    AudioRecorder Function()? recorderFactory,
    AiSpeechTranscriber? transcriber,
    Dio? downloader,
    this.storageRoot,
  }) : runtimeFactory = runtimeFactory ?? LlamaLanguageRuntime.new,
       recorderFactory = recorderFactory ?? AudioRecorder.new,
       transcriber = transcriber ?? WhisperFileTranscriber(),
       downloader =
           downloader ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(minutes: 2),
             ),
           );
  final Repository repo;
  final AiLanguageRuntime Function() runtimeFactory;
  final AudioRecorder Function() recorderFactory;
  final AiSpeechTranscriber transcriber;
  final Dio downloader;

  /// Isolated storage for device diagnostics. Production uses app support,
  /// independently of synced attachments.
  final Directory? storageRoot;
  bool enabled = false,
      busy = false,
      ready = false,
      modelInstalled = false,
      recording = false,
      stopping = false;
  String status = '', queueError = '';
  double? progress;
  AiModel selected = languageModels.first;
  AiModel get speechSelected => speechModel;
  AiHardware? hardware;
  Directory? _directory, _recordings;
  AiLanguageRuntime? _runtime;
  CancelToken? _download;
  Future<void>? _work, _queueWork, _finishWork;
  AudioRecorder? _recorder;
  Timer? _recordTimer;
  Stopwatch? _recordWatch;
  AiProposal? _recordingItem;
  final List<AiProposal> _proposals = [];
  final Set<String> _applying = {};
  String? _activeId;
  int _epoch = 0;
  bool _disposed = false,
      _closed = false,
      _foreground = true,
      _observing = false;
  static const _background = MethodChannel('dev.yggvion/ai_background');

  List<AiProposal> get proposals => List.unmodifiable(_proposals.reversed);
  bool applying(String id) => _applying.contains(id);
  int get recordingSeconds => _recordWatch?.elapsed.inSeconds ?? 0;
  bool get processing => _queueWork != null;
  bool get downloading => _download != null;
  int get pendingCount => _proposals
      .where(
        (p) =>
            p.state == AiProposalState.ready ||
            p.state == AiProposalState.clarification,
      )
      .length;
  void publish() {
    if (!_disposed) notifyListeners();
  }

  Future<Directory> get directory async => _directory ??= Directory(
    '${(storageRoot ?? await getApplicationSupportDirectory()).path}/local-ai',
  );
  // Not attachments: this directory is never registered in the files table,
  // outbox, workspace export or server backup.
  Future<Directory> get recordingsDirectory async => _recordings ??= Directory(
    '${(storageRoot ?? await getApplicationSupportDirectory()).path}/ai-recordings',
  );

  Future<void> initialize() async {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    enabled = await repo.db.meta('ai_enabled') == 'true';
    final id = await repo.db.meta('ai_model');
    selected =
        languageModels.where((m) => m.id == id).firstOrNull ??
        languageModels.first;
    final dir = await directory;
    if (!enabled) {
      if (await dir.exists()) await dir.delete(recursive: true);
      await _clearInbox();
      return;
    }
    // Retire any model outside the current catalogue, including abandoned
    // experiments and partial downloads, without retaining their identifiers.
    final allowed = {
      for (final m in [...languageModels, speechModel]) ...[
        m.file,
        '${m.file}.part',
      ],
    };
    if (await dir.exists()) {
      await for (final file in dir.list(followLinks: false)) {
        if (!allowed.contains(file.uri.pathSegments.last)) {
          await file.delete(recursive: true);
        }
      }
    }
    if (id != null && !languageModels.any((m) => m.id == id)) {
      hardware = await AiHardware.detect();
      for (final m in languageModels.where(hardware!.fits)) {
        if (await File('${dir.path}/${m.file}').exists()) selected = m;
      }
      await repo.db.setMeta('ai_model', selected.id);
    }
    await repo.db.setMeta('ai_speech_model', speechModel.id);
    await _refreshReady();
    if (!await File('${dir.path}/${speechModel.file}').exists()) {
      status = 'Для голосового ввода скачайте Whisper Small.';
    }
    final saved = await repo.db.meta('ai_inbox');
    _proposals.clear();
    if (saved != null) {
      for (final json in jsonDecode(saved) as List) {
        final item = AiProposal.fromJson(
          Map<String, dynamic>.from(json as Map),
        );
        if (item.working) item.state = AiProposalState.queued;
        if (await repo.db.meta('ai_applied_${item.id}') == 'true') {
          item.state = AiProposalState.applied;
        }
        _proposals.add(item);
      }
    }
    final recordings = await recordingsDirectory;
    if (await recordings.exists()) {
      final referenced = _proposals
          .map((p) => p.audio)
          .whereType<String>()
          .toSet();
      await for (final file in recordings.list(followLinks: false)) {
        if (!referenced.contains(file.uri.pathSegments.last)) {
          await file.delete(recursive: true);
        }
      }
    }
    await _saveInbox();
    publish();
    resumeQueue();
  }

  Future<void> inspectHardware() async {
    hardware = await AiHardware.detect();
    if (await repo.db.meta('ai_model') == null) {
      selected = hardware!.recommended;
    }
    await _refreshReady();
    publish();
  }

  Future<void> setEnabled(bool value) async {
    if (stopping) return;
    enabled = value;
    _epoch++;
    publish();
    await repo.db.setMeta('ai_enabled', '$value');
    if (value) {
      await _refreshReady();
      resumeQueue();
      return;
    }
    stopping = true;
    publish();
    try {
      _download?.cancel();
      await cancelRecording();
      await _runtime?.close();
      _runtime = null;
      try {
        await _work;
      } on Object {
        /* Initiating operation reports errors. */
      }
      await _queueWork;
      await _clearInbox();
      final dir = await directory;
      if (await dir.exists()) await dir.delete(recursive: true);
      ready = false;
      modelInstalled = false;
      progress = null;
      status = '';
      busy = false;
    } finally {
      stopping = false;
      publish();
    }
  }

  Future<void> _clearInbox() async {
    _proposals.clear();
    await _saveInbox();
    final recordings = await recordingsDirectory;
    if (await recordings.exists()) await recordings.delete(recursive: true);
  }

  Future<void> select(AiModel model) async {
    if (busy || processing || recording || stopping) {
      throw StateError('Дождитесь окончания операции');
    }
    if (hardware != null && !hardware!.fits(model)) {
      throw StateError('Для этой модели недостаточно памяти');
    }
    selected = model;
    await repo.db.setMeta('ai_model', model.id);
    await _refreshReady();
    publish();
    resumeQueue();
  }

  Future<void> _refreshReady() async {
    final dir = await directory;
    modelInstalled = await File('${dir.path}/${selected.file}').exists();
    ready =
        modelInstalled &&
        await File('${dir.path}/${speechModel.file}').exists();
  }

  void check([int? epoch]) {
    if (!enabled || stopping || _closed || (epoch != null && epoch != _epoch)) {
      throw StateError('AI выключен');
    }
  }

  Future<void> install() async {
    check();
    if (busy || processing || recording) {
      throw StateError('Дождитесь окончания операции');
    }
    await inspectHardware();
    if (!hardware!.fits(selected)) {
      throw StateError('Для модели недостаточно памяти');
    }
    if (hardware!.freeBytes > 0 &&
        hardware!.freeBytes <
            selected.bytes + speechSelected.bytes + (512 << 20)) {
      throw StateError('Недостаточно свободного места для моделей');
    }
    await repo.db.setMeta('ai_speech_model', speechSelected.id);
    await repo.db.setMeta('ai_model', selected.id);
    final epoch = _epoch;
    busy = true;
    publish();
    final work = _install(epoch);
    _work = work;
    try {
      await work;
    } finally {
      _download = null;
      busy = false;
      _work = null;
      publish();
      resumeQueue();
    }
  }

  Future<void> _install(int epoch) async {
    final dir = await directory;
    await dir.create(recursive: true);
    _download = CancelToken();
    for (final model in [selected, speechSelected]) {
      check(epoch);
      final target = File('${dir.path}/${model.file}');
      if (await target.exists()) {
        final digest = await Isolate.run(() => fileDigest(target.path));
        if (digest == model.sha256) continue;
        await target.delete();
      }
      final part = File('${target.path}.part');
      var offset = await part.exists() ? await part.length() : 0;
      if (offset > model.bytes) {
        await part.delete();
        offset = 0;
      }
      status = 'Скачиваем ${model.label}';
      progress = offset / model.bytes;
      publish();
      if (offset < model.bytes) {
        final response = await downloader.get<ResponseBody>(
          model.url,
          options: Options(
            responseType: ResponseType.stream,
            headers: offset == 0 ? null : {'Range': 'bytes=$offset-'},
          ),
          cancelToken: _download,
        );
        if (response.statusCode == 200) offset = 0;
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw StateError('Не удалось скачать модель');
        }
        if (response.statusCode == 206 &&
            !((response.headers.value('content-range') ?? '').startsWith(
              'bytes $offset-',
            ))) {
          throw StateError('Некорректное продолжение загрузки');
        }
        final file = await part.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        try {
          await for (final chunk in response.data!.stream) {
            check(epoch);
            offset += chunk.length;
            if (offset > model.bytes) {
              throw StateError('Размер модели не совпадает с каталогом');
            }
            await file.writeFrom(chunk);
            progress = offset / model.bytes;
            publish();
          }
          await file.flush();
        } finally {
          await file.close();
        }
      }
      check(epoch);
      status = 'Проверяем целостность ${model.label}';
      publish();
      final digest = await Isolate.run(() => fileDigest(part.path));
      check(epoch);
      if (await part.length() != model.bytes || digest != model.sha256) {
        await part.delete();
        throw StateError(
          'Контрольная сумма модели не совпала. Повторите загрузку.',
        );
      }
      await part.rename(target.path);
    }
    check(epoch);
    ready = true;
    modelInstalled = true;
    status = 'Модели готовы к работе без интернета';
    progress = null;
    publish();
  }

  static Future<String> fileDigest(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();
  void cancelDownload() => _download?.cancel();

  Future<AiDraft> interpret(String input, {DateTime? requestedAt}) async {
    check();
    if (!ready) throw StateError('Сначала установите модели в настройках');
    if (busy || recording) {
      throw StateError('Сначала завершите текущую операцию');
    }
    if (input.trim().isEmpty || input.length > 4000) {
      throw ArgumentError('Введите команду длиной до 4000 символов');
    }
    busy = true;
    status = 'Разбираем команду на этом устройстве';
    publish();
    final epoch = _epoch;
    final done = Completer<void>();
    _work = done.future;
    AiLanguageRuntime? runtime;
    try {
      final notes = (await repo.db.search(input))
          .where((e) => e.kind == 'note')
          .take(3)
          .map(
            (e) => e.searchable.substring(0, e.searchable.length.clamp(0, 600)),
          )
          .toList();
      final prompt = AiPrompt.build(
        input,
        repo.snapshot,
        requestedAt ?? repo.now(),
        notes: notes,
      );
      final dir = await directory;
      check(epoch);
      if (prompt.clarification != null) {
        return AiDraft('clarify', {}, prompt.clarification!);
      }
      runtime = runtimeFactory();
      _runtime = runtime;
      final response = await runtime
          .interpret(
            '${dir.path}/${selected.file}',
            prompt.system,
            input,
            schema: prompt.schema,
          )
          .timeout(const Duration(minutes: 3));
      check(epoch);
      return AiActions.parse(
        response,
        repo.snapshot,
        repo.now(),
        request: input,
        referenceTime: requestedAt,
      );
    } finally {
      try {
        await runtime?.close();
      } finally {
        if (identical(_runtime, runtime)) _runtime = null;
        busy = false;
        status = '';
        done.complete();
        _work = null;
        publish();
      }
    }
  }

  Future<void> _saveInbox() {
    final json = jsonEncode(_proposals.map((p) => p.toJson()).toList());
    return repo.serial(() => repo.db.setMeta('ai_inbox', json));
  }

  void _ensureCapacity() {
    if (_proposals.length >= 100) {
      throw StateError('Уберите старые предложения перед новой записью');
    }
  }

  Future<void> submitText(String input) async {
    check();
    input = input.trim();
    if (input.isEmpty || input.length > 4000) {
      throw ArgumentError('Введите команду длиной до 4000 символов');
    }
    _ensureCapacity();
    final item = AiProposal(
      id: repo.newId(),
      createdAt: repo.now(),
      input: input,
    );
    _proposals.add(item);
    try {
      await _saveInbox();
    } on Object {
      _proposals.remove(item);
      rethrow;
    }
    publish();
    resumeQueue();
  }

  Future<void> startRecording() async {
    check();
    if (recording || _finishWork != null || (busy && _queueWork == null)) {
      throw StateError('Дождитесь окончания текущей операции');
    }
    _ensureCapacity();
    final epoch = _epoch;
    final id = repo.newId();
    final item = AiProposal(
      id: id,
      createdAt: repo.now(),
      input: '',
      audio: '$id.wav',
    );
    _recordingItem = item;
    recording = true;
    queueError = '';
    publish();
    try {
      final recorder = recorderFactory();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        throw StateError(
          'Разрешите доступ к микрофону в настройках устройства',
        );
      }
      check(epoch);
      // A cancelled permission prompt must not reopen the microphone later.
      if (!identical(_recordingItem, item)) return;
      final recordings = await recordingsDirectory;
      await recordings.create(recursive: true);
      check(epoch);
      if (!identical(_recordingItem, item)) return;
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: '${recordings.path}/${item.audio}',
      );
      check(epoch);
      if (!identical(_recordingItem, item)) {
        await recorder.cancel();
        return;
      }
      _recordWatch = Stopwatch()..start();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        publish();
        if (recordingSeconds >= 120) {
          unawaited(
            finishRecording().catchError((Object e) {
              queueError = '$e';
              publish();
            }),
          );
        }
      });
    } on Object {
      await cancelRecording();
      rethrow;
    }
  }

  Future<void> finishRecording() =>
      _finishWork ??= _finishRecording().whenComplete(() => _finishWork = null);

  Future<void> _finishRecording() async {
    final item = _recordingItem;
    final recorder = _recorder;
    if (item == null || recorder == null) return;
    final epoch = _epoch;
    final seconds = recordingSeconds;
    _recordTimer?.cancel();
    _recordTimer = null;
    try {
      await recorder.stop();
      check(epoch);
      if (!identical(_recordingItem, item)) return;
      final file = File('${(await recordingsDirectory).path}/${item.audio}');
      if (!await file.exists() || await file.length() <= 44) {
        throw StateError('Запись пуста. Попробуйте ещё раз.');
      }
      final queued = AiProposal(
        id: item.id,
        createdAt: item.createdAt,
        input: '',
        audio: item.audio,
        seconds: seconds,
      );
      _proposals.add(queued);
      try {
        await _saveInbox();
      } on Object {
        _proposals.remove(queued);
        rethrow;
      }
    } finally {
      if (!_proposals.any((p) => p.id == item.id)) await _deleteAudio(item);
      await recorder.dispose();
      if (identical(_recordingItem, item)) {
        _recordingItem = null;
        _recorder = null;
        _recordWatch = null;
        recording = false;
      }
      publish();
      resumeQueue();
    }
  }

  Future<void> cancelRecording() async {
    final item = _recordingItem;
    final recorder = _recorder;
    _recordingItem = null;
    _recorder = null;
    _recordTimer?.cancel();
    _recordTimer = null;
    _recordWatch = null;
    recording = false;
    try {
      if (recorder != null) {
        await recorder.cancel();
        await recorder.dispose();
      }
    } finally {
      if (item != null && _finishWork == null) await _deleteAudio(item);
      publish();
      resumeQueue();
    }
  }

  Future<void> _deleteAudio(AiProposal item) async {
    if (item.audio == null) return;
    final file = File('${(await recordingsDirectory).path}/${item.audio}');
    if (await file.exists()) await file.delete();
    item.audio = null;
  }

  void resumeQueue() {
    if (!enabled ||
        !ready ||
        busy ||
        recording ||
        stopping ||
        _closed ||
        !_foreground ||
        _queueWork != null ||
        !_proposals.any((p) => p.state == AiProposalState.queued)) {
      return;
    }
    final work = _drainQueue();
    _queueWork = work;
    unawaited(
      work.whenComplete(() {
        _queueWork = null;
        publish();
        if (queueError.isEmpty) resumeQueue();
      }),
    );
  }

  Future<void> _backgroundTime(String method) async {
    if (!Platform.isIOS) return;
    try {
      await _background.invokeMethod<void>(method);
    } on MissingPluginException {
      /* Desktop tests have no iOS bridge. */
    }
  }

  Future<void> _drainQueue() async {
    final epoch = _epoch;
    try {
      while (enabled &&
          ready &&
          _foreground &&
          !recording &&
          epoch == _epoch &&
          !_closed) {
        final item = _proposals
            .where((p) => p.state == AiProposalState.queued)
            .firstOrNull;
        if (item == null) return;
        _activeId = item.id;
        try {
          await _backgroundTime('begin');
          if (item.input.isEmpty && item.audio != null) {
            item.state = AiProposalState.transcribing;
            await _saveInbox();
            publish();
            final dir = await directory;
            final audio = '${(await recordingsDirectory).path}/${item.audio}';
            final text = await transcriber.transcribe(
              '${dir.path}/${speechModel.file}',
              audio,
            );
            check(epoch);
            if (!_proposals.contains(item)) continue;
            if (text.trim().isEmpty) {
              throw StateError(
                'Речь не обнаружена. Запишите сообщение ещё раз.',
              );
            }
            item.input = text.trim();
            // Commit transcript before deleting the only copy of the audio.
            await _saveInbox();
            await _deleteAudio(item);
            await _saveInbox();
          }
          check(epoch);
          if (!_proposals.contains(item)) continue;
          if (!_foreground || recording) {
            item.state = AiProposalState.queued;
            await _saveInbox();
            return;
          }
          item.state = AiProposalState.interpreting;
          await _saveInbox();
          publish();
          final draft = await interpret(
            item.input,
            requestedAt: item.createdAt,
          );
          check(epoch);
          if (!_proposals.contains(item)) continue;
          item.draft = draft;
          item.error = null;
          item.state = draft.action == 'clarify'
              ? AiProposalState.clarification
              : AiProposalState.ready;
          await _saveInbox();
        } on Object catch (error) {
          if (!enabled || epoch != _epoch || _closed) return;
          if (_proposals.contains(item)) {
            item.state = _foreground
                ? AiProposalState.failed
                : AiProposalState.queued;
            item.error = _foreground ? '$error' : null;
            await _saveInbox();
          }
        } finally {
          if (!_proposals.contains(item)) await _deleteAudio(item);
          _activeId = null;
          await _backgroundTime('end');
          publish();
        }
      }
    } on Object catch (error) {
      // Persistence/OS errors stay visible, and do not create a retry spin.
      queueError = 'Очередь AI остановлена: $error';
      publish();
    }
  }

  Future<void> retry(AiProposal item, {String? input}) async {
    check();
    if (!_proposals.contains(item) ||
        item.working ||
        item.state == AiProposalState.applied ||
        applying(item.id)) {
      return;
    }
    if (input != null) {
      if (input.trim().isEmpty || input.length > 4000) {
        throw ArgumentError('Введите команду длиной до 4000 символов');
      }
      item.input = input.trim();
      await _deleteAudio(item);
    }
    item.state = AiProposalState.queued;
    item.draft = null;
    item.error = null;
    queueError = '';
    await _saveInbox();
    publish();
    resumeQueue();
  }

  Future<void> dismiss(AiProposal item) async {
    if (applying(item.id)) return;
    if (!_proposals.remove(item)) return;
    await _saveInbox();
    if (_activeId == item.id) await _runtime?.close();
    // An active transcription still owns its input; the worker deletes it
    // when it notices dismissal. Other recordings can be removed immediately.
    if (_activeId != item.id) await _deleteAudio(item);
    publish();
  }

  Future<void> confirm(AiProposal item) async {
    check();
    if (!_proposals.contains(item) ||
        item.state != AiProposalState.ready ||
        item.draft?.writes != true ||
        !_applying.add(item.id)) {
      return;
    }
    publish();
    try {
      await apply(item.draft!, proposalId: item.id);
      item.state = AiProposalState.applied;
      item.error = null;
      await _saveInbox();
    } on Object catch (error) {
      item.error = '$error';
      rethrow;
    } finally {
      _applying.remove(item.id);
      publish();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _foreground = false;
      // File transcription is CPU-only in the shipped iOS engine. Never
      // begin another LLM/Metal operation while the app is in the background.
      unawaited(_runtime?.close() ?? Future<void>.value());
      if (recording) {
        unawaited(
          finishRecording().catchError((Object e) {
            queueError = '$e';
            publish();
          }),
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      resumeQueue();
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    _epoch++;
    _download?.cancel();
    await cancelRecording();
    await _runtime?.close();
    try {
      await _work;
      await _finishWork;
    } on Object {
      // The caller of the cancelled recording/inference receives its error.
    }
    await _queueWork;
    downloader.close(force: true);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  Future<void> apply(AiDraft draft, {String? proposalId}) async {
    check();
    if (!draft.writes) return;
    await repo.commitComputed(
      () async {
        check();
        if (proposalId != null &&
            await repo.db.meta('ai_applied_$proposalId') == 'true') {
          return [];
        }
        final snapshot = repo.snapshot;
        switch (draft.action) {
          case 'note':
            return [
              Note.create(
                repo.newId(),
                'Заметка',
                content: draft.data['content'] as String,
              ),
            ];
          case 'task':
            final d = draft.data;
            final task = Task.create(
              repo.newId(),
              d['title'] as String,
              description: d['description'] as String,
              projectId: d['project_id'] as String,
            );
            final project = d['project_id'] as String;
            if (project.isNotEmpty &&
                !snapshot.projects.any((p) => p.id == project)) {
              throw StateError('Проект изменился. Повторите команду.');
            }
            if (d['auto_scheduled'] == true) {
              final start = DateTime.parse(d['start'] as String);
              final end = DateTime.parse(d['end'] as String);
              if (start.isBefore(
                    repo.now().subtract(const Duration(minutes: 1)),
                  ) ||
                  snapshot.blocks.any(
                    (b) =>
                        AiActions.occupiesTime(snapshot, b) &&
                        AiActions.overlaps(start, end, b.start, b.end),
                  )) {
                throw StateError(
                  'Расписание изменилось. Подберите свободное время ещё раз.',
                );
              }
            }
            return [
              task,
              if (d['start'] != null)
                TimeBlock.create(
                  repo.newId(),
                  task.id,
                  DateTime.parse(d['start'] as String),
                  DateTime.parse(d['end'] as String),
                  timezone: snapshot.settings.timezone,
                  reminders: snapshot.settings.reminders,
                ),
            ];
          case 'plan':
            for (final block in draft.blocks) {
              final task = snapshot.task(block.taskId);
              if (task == null ||
                  !snapshot.unscheduled(task, repo.now()) ||
                  task.seriesId.isNotEmpty ||
                  task.done ||
                  snapshot.blocks.any(
                    (b) =>
                        AiActions.occupiesTime(snapshot, b) &&
                        AiActions.overlaps(
                          block.start,
                          block.end,
                          b.start,
                          b.end,
                        ),
                  )) {
                throw StateError(
                  'Расписание изменилось. Рассчитайте план ещё раз.',
                );
              }
            }
            return draft.blocks
                .map(
                  (b) => TimeBlock.create(
                    repo.newId(),
                    b.taskId,
                    b.start,
                    b.end,
                    timezone: snapshot.settings.timezone,
                    reminders: snapshot.settings.reminders,
                  ),
                )
                .toList();
          default:
            return [];
        }
      },
      writeLocalState: proposalId == null
          ? null
          : () => repo.db.setMeta('ai_applied_$proposalId', 'true'),
    );
  }
}
