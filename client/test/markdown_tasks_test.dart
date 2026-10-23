import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/markdown_tasks.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/markdown_tasks.dart';
import 'package:yggvion/ui/notes.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'package:yggvion/ui/theme.dart';

import 'interaction_test.dart' show settle, testInteraction, workspace;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  test('changes only the real checkbox, preserving code and exact source', () {
    const text =
        '📋 План\r\n\r\n'
        '````md\r\n- [ ] Одинаковая\r\n```\r\n````\r\n\r\n'
        '    - [ ] Одинаковая\r\n\r\n'
        '<!--\r\n- [ ] Одинаковая\r\n-->\r\n\r\n'
        '- [ ] Одинаковая\r\n\r\n'
        '`- [ ] Одинаковая`\r\n';
    final offset = text.lastIndexOf('- [ ] Одинаковая\r\n') + 3;
    final expected = text.replaceRange(offset, offset + 1, 'x');
    expect(setMarkdownTaskChecked(text, 0, true), expected);
    expect(setMarkdownTaskChecked(expected, 0, false), text);
    expect(setMarkdownTaskChecked(text, -1, true), text);
    expect(setMarkdownTaskChecked(text, 10, true), text);
  });

  test('nested and loose lists map to their own markers', () {
    const text = '- [ ] Родитель\n  - [X] Ребёнок\n\n- [ ] Другой';
    expect(
      setMarkdownTaskChecked(text, 0, false),
      '- [ ] Родитель\n  - [ ] Ребёнок\n\n- [ ] Другой',
    );
    expect(
      setMarkdownTaskChecked(text, 1, true),
      '- [x] Родитель\n  - [X] Ребёнок\n\n- [ ] Другой',
    );
    expect(
      setMarkdownTaskChecked(text, 2, true),
      '- [ ] Родитель\n  - [X] Ребёнок\n\n- [x] Другой',
    );
    const quoted = '> - [ ] Цитата\n\n1. [ ] Номер';
    expect(
      setMarkdownTaskChecked(quoted, 1, true),
      '> - [ ] Цитата\n\n1. [x] Номер',
    );
  });

  const formatter = MarkdownTaskInputFormatter();
  TextEditingValue enter(String text, {int? at}) {
    final caret = at ?? text.length;
    return formatter.formatEditUpdate(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
      TextEditingValue(
        text: text.replaceRange(caret, caret, '\n'),
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );
  }

  test('Enter continues unchecked items and leaves an empty item', () {
    expect(enter('- [x] Готово').text, '- [x] Готово\n- [ ] ');
    final nested = enter('- Родитель\n  - [ ] Дочерняя');
    expect(nested.text, '- Родитель\n  - [ ] Дочерняя\n  - [ ] ');
    expect(nested.selection.extentOffset, nested.text.length);
    expect(enter('- [ ] Один\n- [ ] ').text, '- [ ] Один\n');
    expect(enter('- [ ] Один два', at: 10).text, '- [ ] Один\n- [ ]  два');
  });

  test('Enter leaves code, pasted lists and selections alone', () {
    for (final text in ['```md\n- [ ] Код', '    - [ ] Код', '[ ] Текст']) {
      expect(enter(text).text, '$text\n');
    }
    const old = TextEditingValue(
      text: '- [ ] Один',
      selection: TextSelection.collapsed(offset: 10),
    );
    const pasted = TextEditingValue(
      text: '- [ ] Один\n- [ ] Два',
      selection: TextSelection.collapsed(offset: 20),
    );
    expect(formatter.formatEditUpdate(old, pasted), pasted);
    const replaced = TextEditingValue(
      text: '- [ ] \n',
      selection: TextSelection.collapsed(offset: 7),
    );
    expect(
      formatter.formatEditUpdate(
        old.copyWith(
          selection: const TextSelection(baseOffset: 6, extentOffset: 10),
        ),
        replaced,
      ),
      replaced,
    );
  });

  Future<void> preview(WidgetTester tester, Widget child) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: appTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );

  testInteraction('nested and loose preview checkboxes toggle the right item', (
    tester,
  ) async {
    var text = '- [ ] Родитель\n  - [x] Ребёнок\n\n- [ ] **Другой**';
    await preview(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          return MarkdownPreview(
            text: text,
            onChanged: (value) => set(() => text = value),
          );
        },
      ),
    );
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.text('Родитель', findRichText: true), findsOneWidget);
    expect(find.text('Ребёнок', findRichText: true), findsOneWidget);
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pumpAndSettle();
    expect(text, '- [x] Родитель\n  - [x] Ребёнок\n\n- [ ] **Другой**');
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    expect(text, '- [x] Родитель\n  - [ ] Ребёнок\n\n- [ ] **Другой**');
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pumpAndSettle();
    expect(text, '- [x] Родитель\n  - [ ] Ребёнок\n\n- [x] **Другой**');
    expect(find.text('Другой', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'checkbox tap on a phone saves without opening the keyboard',
    (tester) async {
      var text = 'Вступление\n\n- [ ] Подзадача\n\nЗаключение';
      await preview(
        tester,
        StatefulBuilder(
          builder: (context, set) {
            return LiveMarkdownEditor(
              value: text,
              toolbar: false,
              editOnLongPress: true,
              onChanged: (value) => set(() => text = value),
            );
          },
        ),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(text, 'Вступление\n\n- [x] Подзадача\n\nЗаключение');
      expect(find.byType(TextField), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(text, 'Вступление\n\n- [ ] Подзадача\n\nЗаключение');
    },
  );

  testInteraction('read-only content shows disabled task checkboxes', (
    tester,
  ) async {
    await preview(
      tester,
      LiveMarkdownEditor(
        value: '- [ ] Защищённая\n- [x] Готовая',
        readOnly: true,
        onChanged: (_) => fail('Read-only content changed'),
      ),
    );
    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checkboxes.map((c) => c.value), [false, true]);
    expect(checkboxes.every((c) => c.onChanged == null), isTrue);
  });

  testInteraction(
    'live preview keeps nested tasks after a blank line in the list',
    (tester) async {
      var text = '- [ ] Родитель\n\n    - [ ] Ребёнок\n\nОбычный абзац';
      await preview(
        tester,
        StatefulBuilder(
          builder: (context, set) {
            return LiveMarkdownEditor(
              value: text,
              toolbar: false,
              onChanged: (value) => set(() => text = value),
            );
          },
        ),
      );
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(text, '- [ ] Родитель\n\n    - [x] Ребёнок\n\nОбычный абзац');
      expect(find.text('Обычный абзац', findRichText: true), findsOneWidget);
    },
  );

  for (final source in [false, true]) {
    testInteraction(
      'Enter continues tasks in the actual editor (source: $source)',
      (tester) async {
        var text = '- [x] Готово';
        await preview(
          tester,
          StatefulBuilder(
            builder: (context, set) {
              return LiveMarkdownEditor(
                value: text,
                onChanged: (value) => set(() => text = value),
              );
            },
          ),
        );
        if (source) {
          await tester.tap(find.byTooltip('Исходный Markdown'));
        } else {
          await tester.tap(find.textContaining('Готово', findRichText: true));
        }
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        await tester.showKeyboard(field);
        await tester.enterText(field, text);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '$text\n',
            selection: TextSelection.collapsed(offset: text.length + 1),
          ),
        );
        await tester.pumpAndSettle();
        expect(text, '- [x] Готово\n- [ ] ');
        expect(
          tester.widget<TextField>(field).controller!.selection.extentOffset,
          text.length,
        );
      },
    );
  }

  testInteraction('toggling another block preserves the active text edits', (
    tester,
  ) async {
    var text = 'Вступление\n\n- [ ] Подзадача';
    await preview(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          return LiveMarkdownEditor(
            value: text,
            toolbar: false,
            onChanged: (value) => set(() => text = value),
          );
        },
      ),
    );
    await tester.tap(find.text('Вступление', findRichText: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Новый текст\n\nЕщё абзац');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(text, 'Новый текст\n\nЕщё абзац\n\n- [x] Подзадача');
  });

  testInteraction(
    'event description saves checkbox changes without completing the event',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask(
            'Список встречи',
            description: '- [ ] Подготовить материалы',
          );
        },
      );
      final task = repo.snapshot.tasks.single;
      final context = tester.element(find.byType(Scaffold).first);
      final closed = openTask(context, task: task);
      await settle(tester);
      final checkbox = find.descendant(
        of: find.byType(LiveMarkdownEditor),
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      await closed;
      expect(
        repo.snapshot.task(task.id)!.description,
        '- [x] Подготовить материалы',
      );
      expect(repo.snapshot.task(task.id)!.done, isFalse);
      expect(repo.snapshot.tasks, hasLength(1));
    },
  );

  testInteraction(
    'note checkbox persists across navigation without text editing',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) => repo.saveNote(
          'scratchpad',
          'Быстрая заметка',
          '- [ ] Проверить список',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NotePanel).first,
          matching: find.byType(Checkbox),
        ),
      );
      await settle(tester);
      expect(
        repo.snapshot.note('scratchpad')!.content,
        '- [x] Проверить список',
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
    },
  );
}
