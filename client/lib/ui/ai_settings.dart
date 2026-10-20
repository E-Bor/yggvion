import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/ai_actions.dart';
import '../data/ai_models.dart';
import 'providers.dart';
import 'server_settings.dart';
import 'theme.dart';

class AiSettingsPage extends ConsumerStatefulWidget {
  const AiSettingsPage({super.key});
  @override
  ConsumerState<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends ConsumerState<AiSettingsPage> {
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(aiProvider)?.inspectHardware();
      } on Object {
        if (mounted) {
          setState(
            () => error =
                'Не удалось определить память устройства. Доступна самая компактная модель.',
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ai = ref.watch(aiProvider);
    return SettingsDetail(
      title: 'Локальный AI',
      children: [
        settingsCard('Помощник на вашем устройстве', [
          const Text(
            'Голос, планирование и команды работают локально. Для первой загрузки моделей нужен интернет. Вы предложенный план проверяете перед сохранением.',
            style: TextStyle(color: Palette.muted, height: 1.5),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Включить AI'),
            subtitle: const Text(
              'При выключении модели удаляются, микрофон и обработка останавливаются.',
            ),
            value: ai?.enabled ?? false,
            onChanged: ai == null || ai.stopping
                ? null
                : (value) => guard(context, () => ai.setEnabled(value)),
          ),
          if (ai?.stopping == true) ...[
            const LinearProgressIndicator(),
            const Text('Останавливаем обработку и удаляем модели…'),
          ],
        ]),
        if (ai != null && ai.enabled) ...[
          settingsCard('Модель для этого устройства', [
            Text(
              ai.hardware == null
                  ? 'Определяем возможности устройства…'
                  : '${ai.hardware!.name} · ${ai.hardware!.memoryBytes == 0 ? 'память не определена' : '${ai.hardware!.memoryGiB.toStringAsFixed(0)} ГБ памяти'}',
              style: const TextStyle(color: Palette.muted),
            ),
            if (error != null) Text(error!),
            const SizedBox(height: 16),
            for (final model in languageModels)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(model.label),
                subtitle: Text(
                  '${model.gib.toStringAsFixed(1)} ГБ · ${model == ai.hardware?.recommended ? 'Рекомендуется' : 'от ${model.memoryGiB} ГБ памяти'}',
                ),
                leading: Icon(
                  ai.selected.id == model.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                selected: ai.selected.id == model.id,
                onTap:
                    ai.busy ||
                        !(ai.hardware?.fits(model) ??
                            model == languageModels.first)
                    ? null
                    : () => guard(context, () => ai.select(model)),
              ),
            const Divider(),
            const Text(
              'Распознавание речи · русский · до 30 секунд',
              style: TextStyle(color: Palette.muted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(ai.speechSelected.id),
              initialValue: ai.speechSelected.id,
              isExpanded: true,
              items: [
                for (final model in speechModels)
                  DropdownMenuItem(
                    value: model.id,
                    child: Text(
                      '${model.id == 'whisper-base' ? 'Whisper Base · быстрее' : 'Whisper Small · точнее'} · ${(model.bytes / 1048576).round()} МБ',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: ai.busy
                  ? null
                  : (value) {
                      if (value != null) {
                        guard(
                          context,
                          () => ai.selectSpeech(
                            speechModels.firstWhere((m) => m.id == value),
                          ),
                        );
                      }
                    },
            ),
            const SizedBox(height: 20),
            if (ai.busy) ...[
              LinearProgressIndicator(value: ai.progress),
              const SizedBox(height: 12),
            ],
            Text(ai.status),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: ai.busy ? null : () => guard(context, ai.install),
                  icon: Icon(
                    ai.ready ? Icons.verified_outlined : Icons.download_rounded,
                  ),
                  label: Text(ai.ready ? 'Проверить модели' : 'Скачать модели'),
                ),
                if (ai.busy)
                  TextButton(
                    onPressed: ai.cancelDownload,
                    child: const Text('Отменить загрузку'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Qwen 3.5 · Apache 2.0. Whisper · MIT. Веса скачиваются с Hugging Face и проверяются по SHA-256.',
              style: TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ]),
        ],
      ],
    );
  }
}

class AssistantButton extends ConsumerWidget {
  const AssistantButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(aiProvider.select((ai) => ai?.enabled ?? false));
    if (!enabled) return const SizedBox.shrink();
    return IconButton.filledTonal(
      key: const ValueKey('ai-microphone'),
      tooltip: 'Голосовой помощник',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const AssistantDialog(),
      ),
      icon: const Icon(Icons.mic_none_rounded),
    );
  }
}

class AssistantDialog extends ConsumerStatefulWidget {
  const AssistantDialog({super.key});
  @override
  ConsumerState<AssistantDialog> createState() => _AssistantDialogState();
}

class _AssistantDialogState extends ConsumerState<AssistantDialog> {
  final input = TextEditingController();
  AiDraft? draft;
  bool busy = false, saved = false;
  String? error;
  String? lastTranscript;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ai = ref.read(aiProvider);
      if (mounted && ai != null && ai.enabled && ai.ready && !ai.busy) {
        unawaited(run(ai.startRecording));
      }
    });
  }

  @override
  void dispose() {
    input.dispose();
    final ai = ref.read(aiProvider);
    if (ai != null) {
      unawaited(
        ai.stopAssistant().catchError((Object error) {
          debugPrint('Could not stop local assistant');
        }),
      );
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } on Object catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = ref.watch(aiProvider);
    if (ai == null || !ai.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return const SizedBox.shrink();
    }
    if (ai.transcript.isNotEmpty && ai.transcript != lastTranscript) {
      lastTranscript = ai.transcript;
      input.value = TextEditingValue(
        text: ai.transcript,
        selection: TextSelection.collapsed(offset: ai.transcript.length),
      );
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: context.accentColor),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Чем займёмся?',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Например: «Запланируй на понедельник в 15:00 стоматолога на час».',
                style: TextStyle(color: Palette.muted, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (!ai.ready) ...[
                const Text(
                  'Установите модели, чтобы пользоваться помощником без интернета.',
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const AiSettingsPage(),
                      ),
                    );
                  },
                  child: const Text('Выбрать модель'),
                ),
              ] else ...[
                TextField(
                  controller: input,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 4000,
                  decoration: const InputDecoration(
                    hintText: 'Скажите или напишите команду…',
                  ),
                  onChanged: (_) {
                    if (draft != null) {
                      setState(() {
                        draft = null;
                        saved = false;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: ai.recording
                          ? 'Завершить запись'
                          : 'Начать запись',
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              draft = null;
                              saved = false;
                              if (ai.recording) {
                                await ai.stopRecording();
                              } else {
                                await ai.startRecording();
                              }
                            }),
                      icon: Icon(
                        ai.recording
                            ? Icons.stop_rounded
                            : Icons.mic_none_rounded,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (ai.recording)
                      const Expanded(child: Text('Слушаю · до 30 секунд'))
                    else
                      Expanded(
                        child: FilledButton(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  final result = await ai.interpret(input.text);
                                  if (mounted) {
                                    setState(() {
                                      draft = result;
                                      saved = false;
                                    });
                                  }
                                }),
                          child: const Text('Предложить действие'),
                        ),
                      ),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(ai.status, style: const TextStyle(color: Palette.muted)),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                if (draft != null) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: context.accentColor.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: SelectableText(
                      draft!.summary,
                      style: const TextStyle(height: 1.6),
                    ),
                  ),
                  if (draft!.writes) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy || saved
                          ? null
                          : () => run(() async {
                              await ai.apply(draft!);
                              if (mounted) setState(() => saved = true);
                            }),
                      child: Text(
                        saved
                            ? 'Сохранено'
                            : draft!.action == 'plan'
                            ? 'Применить план'
                            : 'Сохранить',
                      ),
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 16),
              const Text(
                'Пилот · обработка на устройстве · без облачного AI',
                style: TextStyle(color: Palette.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
