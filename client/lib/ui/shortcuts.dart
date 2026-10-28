import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

Future<void> showShortcutHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: Text(tr("Горячие клавиши")),
    content: SizedBox(
      width: 470,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                tr("На Mac — ⌘, на Windows и Linux — Ctrl."),
                style: TextStyle(color: context.palette.muted),
              ),
            ),
            for (final item in [
              (tr("Поиск по всему пространству"), '⌘ / Ctrl + F'),
              (tr("Поиск · альтернативная комбинация"), '⌘ / Ctrl + K'),
              (tr("Новая задача"), '⌘ / Ctrl + N'),
              (tr("Новая заметка"), '⌘ / Ctrl + Shift + N'),
              (tr("Сегодня"), '⌘ / Ctrl + 1'),
              (tr("Планировщик"), '⌘ / Ctrl + 2'),
              (tr("Канбан"), '⌘ / Ctrl + 3'),
              (tr("Заметки"), '⌘ / Ctrl + 4'),
              (tr("Настройки"), tr("⌘ / Ctrl + 5 или ,")),
              (tr("Пауза / продолжить таймер"), '⌘ / Ctrl + Shift + Space'),
              (tr("Сохранить задачу из названия"), 'Enter'),
              (tr("Перейти в описание задачи"), '⌘ / Ctrl + Enter'),
              (tr("Закрыть окно / отменить выбор"), 'Esc'),
              (tr("Эта справка"), 'F1'),
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
      TextButton(onPressed: () => Navigator.pop(c), child: Text(tr("Готово"))),
    ],
  ),
);
