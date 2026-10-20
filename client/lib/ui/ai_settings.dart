import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
            'Голос, планирование и команды работают локально. Для первой загрузки моделей нужен интернет. Предложения можно проверить перед сохранением.',
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
                        ai.processing ||
                        ai.recording ||
                        !(ai.hardware?.fits(model) ??
                            model == languageModels.first)
                    ? null
                    : () => guard(context, () => ai.select(model)),
              ),
            const Divider(),
            const Text(
              'Голосовые сообщения · русский · до 2 минут',
              style: TextStyle(color: Palette.muted),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.graphic_eq_rounded),
              title: const Text('Whisper Small'),
              subtitle: Text(
                '${(speechModel.bytes / 1048576).round()} МБ · транскрибация после записи',
              ),
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
                  onPressed: ai.busy || ai.processing || ai.recording
                      ? null
                      : () => guard(context, ai.install),
                  icon: Icon(
                    ai.ready ? Icons.verified_outlined : Icons.download_rounded,
                  ),
                  label: Text(ai.ready ? 'Проверить модели' : 'Скачать модели'),
                ),
                if (ai.downloading)
                  TextButton(
                    onPressed: ai.cancelDownload,
                    child: const Text('Отменить'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Qwen 3.5 · Apache 2.0. Whisper · MIT. Модели скачиваются с Hugging Face. Целостность проверяется по SHA-256.',
              style: TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ]),
        ],
      ],
    );
  }
}
