// Optional native smoke check: dart run tool/ai_smoke.dart /path/to/model.gguf
// Uses synthetic commands only; never opens the app's database.
import 'dart:io';
import 'package:intl/date_symbol_data_local.dart';
import 'package:llamadart/llamadart.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/ai_actions.dart';
import 'package:yggvion/domain/models.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/ai_smoke.dart model.gguf');
    exitCode = 64;
    return;
  }
  tz.initializeTimeZones();
  await initializeDateFormatting('ru');
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(args.single)),
    params: const ModelParams(contextSize: 4096),
  );
  try {
    final answer = await engine
        .create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.system,
              text:
                  'Ты помощник календаря. Сейчас 2026-10-20, вторник, Europe/Moscow. Создание НОВОГО события, включая «запланируй поход к врачу», ВСЕГДА action task. action plan ТОЛЬКО для существующих task_ids. Список существующих задач пуст, action plan запрещён. Верни JSON: action task, title, date YYYY-MM-DD, time HH:mm, minutes. Для понедельника используй ближайшую будущую дату. Пример «Запланируй встречу 26 октября 2026 в 15:00 на час»: {"action":"task","title":"Встреча","date":"2026-10-26","time":"15:00","minutes":60}.',
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text:
                  'Запланируй на понедельник в 15:00 поход к стоматологу на час.',
            ),
          ],
          enableThinking: false,
          params: const GenerationParams(maxTokens: 256, temp: 0),
          responseFormat: {
            'type': 'json_schema',
            'json_schema': {'schema': AiActions.schema},
          },
        )
        .text();
    final snapshot = Snapshot([
      Entity(
        id: 'settings',
        kind: 'settings',
        data: {
          'default_minutes': 30,
          'reminders': [0],
          'timezone': 'Europe/Moscow',
        },
      ),
    ]);
    stdout.writeln('Synthetic model response: $answer');
    final result = AiActions.parse(
      answer,
      snapshot,
      DateTime.utc(2026, 10, 20),
      request: 'Запланируй на понедельник в 15:00 поход к стоматологу на час.',
    );
    if (result.action != 'task' ||
        result.data['start'] != '2026-10-26T12:00:00.000Z' ||
        result.data['end'] != '2026-10-26T13:00:00.000Z') {
      throw StateError('Unexpected synthetic command result: $answer');
    }
    stdout.writeln('Native local model smoke passed: ${result.summary}');
  } finally {
    await engine.dispose();
  }
}
