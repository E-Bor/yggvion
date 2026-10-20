import 'package:flutter/material.dart';
import 'theme.dart';

Future<void> showShortcutHelp(BuildContext context, {bool aiEnabled = false}) =>
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Горячие клавиши'),
        content: SizedBox(
          width: 470,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'На Mac — ⌘, на Windows и Linux — Ctrl.',
                    style: TextStyle(color: Palette.muted),
                  ),
                ),
                for (final item in [
                  ('Поиск по всему пространству', '⌘ / Ctrl + F'),
                  ('Поиск · альтернативная комбинация', '⌘ / Ctrl + K'),
                  ('Новая задача', '⌘ / Ctrl + N'),
                  ('Новая заметка', '⌘ / Ctrl + Shift + N'),
                  ('Сегодня', '⌘ / Ctrl + 1'),
                  ('Планировщик', '⌘ / Ctrl + 2'),
                  ('Канбан', '⌘ / Ctrl + 3'),
                  ('Заметки', '⌘ / Ctrl + 4'),
                  ('Настройки', '⌘ / Ctrl + 5 или ,'),
                  if (aiEnabled) ('AI', '⌘ / Ctrl + 6'),
                  ('Пауза / продолжить таймер', '⌘ / Ctrl + Shift + Space'),
                  ('Сохранить задачу из названия', 'Enter'),
                  ('Перейти в описание задачи', '⌘ / Ctrl + Enter'),
                  ('Закрыть окно / отменить выбор', 'Esc'),
                  ('Эта справка', 'F1'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.$1,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          item.$2,
                          style: TextStyle(color: c.accentColor, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
