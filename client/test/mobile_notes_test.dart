import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/attachments.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/notes.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

Finder phoneNoteField(String id) => find.descendant(
  of: find.byWidgetPredicate((w) => w is NotePanel && w.noteId == id),
  matching: find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
);

EditableTextState phoneNoteInput(WidgetTester tester, String id) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: phoneNoteField(id),
        matching: find.byType(EditableText),
      ),
    );

Offset phoneNotePosition(WidgetTester tester, String id, int offset) {
  final render = phoneNoteInput(tester, id).renderEditable;
  final caret = render.getLocalRectForCaret(TextPosition(offset: offset));
  return render.localToGlobal(caret.center + const Offset(1, 0));
}

void showPhoneKeyboard(WidgetTester tester) {
  tester.view.viewInsets = const FakeViewPadding(bottom: 280);
  addTearDown(tester.view.resetViewInsets);
}

void main() {
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

  testInteraction(
    'phone library actions stay visible above long notes and restore scroll',
    (tester) async {
      late String noteId;
      await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          await repo.saveNote(
            'scratchpad',
            '',
            List.generate(60, (i) => 'Строка черновика $i').join('\n'),
          );
          await repo.saveNoteFolder('Работа');
          final note = await repo.createNote(
            folderId: repo.snapshot.noteFolders.single.id,
          );
          noteId = note.id;
          await repo.saveNote(note.id, 'Материалы встречи', 'План обсуждения');
        },
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      final attachments = find.byKey(
        const ValueKey('mobile-notes-attachments'),
      );
      final folders = find.byKey(const ValueKey('mobile-notes-folders'));
      final toolbar = find.byKey(const ValueKey('mobile-notes-toolbar'));
      expect(find.text('Вложения').hitTestable(), findsOneWidget);
      expect(find.text('Папки').hitTestable(), findsOneWidget);
      final toolbarBounds = tester.getRect(toolbar);
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('mobile-notes-list')))
          .controller!;
      scroll.jumpTo(700);
      await tester.pumpAndSettle();
      expect(tester.getRect(toolbar), toolbarBounds);
      expect(attachments.hitTestable(), findsOneWidget);
      expect(folders.hitTestable(), findsOneWidget);
      final offset = scroll.offset;

      await tester.runAsync(() async {
        await tester.tap(attachments);
        await tester.pump();
      });
      await settle(tester);
      expect(find.byType(AttachmentsPage), findsOneWidget);
      expect(find.text('Пока нет картинок'), findsOneWidget);
      await tester.tap(find.text('Файлы'));
      await settle(tester);
      expect(find.text('Пока нет файлов'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(scroll.offset, closeTo(offset, 1));
      expect(tester.testTextInput.isVisible, isFalse);

      tester.view.physicalSize = const Size(320, 700);
      await tester.pumpAndSettle();
      expect(attachments.hitTestable(), findsOneWidget);
      expect(folders.hitTestable(), findsOneWidget);
      expect(tester.getSize(attachments).height, greaterThanOrEqualTo(44));
      await tester.tap(folders);
      await settle(tester);
      expect(find.byType(NoteLibrary), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('note-list-$noteId')));
      await settle(tester);
      expect(find.byType(NoteLibrary), findsNothing);
      expect(
        find.byKey(ValueKey('note-title-$noteId')).hitTestable(),
        findsOneWidget,
      );
      expect(scroll.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'opening attachments from a phone note dismisses the keyboard and preserves edits',
    (tester) async {
      final repo = await workspace(tester, mobile: true);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      final field = phoneNoteField('scratchpad');
      const content = '# Записать\n\nПоследние изменения';
      await tester.enterText(field, content);
      showPhoneKeyboard(tester);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isTrue);
      final attachments = find.byKey(
        const ValueKey('mobile-notes-attachments'),
      );
      expect(attachments.hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(attachments);
        await tester.pump();
      });
      tester.view.resetViewInsets();
      await settle(tester);
      expect(find.byType(AttachmentsPage), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(tester.widget<TextField>(field).controller!.text, content);
      await tester.runAsync(repo.reload);
      expect(repo.snapshot.note('scratchpad')!.content, content);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('phone navigation keeps Today as home in the new order', (
    tester,
  ) async {
    await workspace(tester, mobile: true);
    NavigationBar navigation() => tester.widget(find.byType(NavigationBar));
    expect(
      navigation().destinations.cast<NavigationDestination>().map(
        (d) => d.label,
      ),
      ['Канбан', 'Планировщик', 'Заметки', 'Сегодня'],
    );
    expect(navigation().selectedIndex, 3);
    expect(find.byType(CalendarPane), findsOneWidget);
    for (final name in ['board', 'planner', 'notes', 'today']) {
      await tester.tap(find.byKey(ValueKey('mobile-nav-$name')));
      await settle(tester);
      expect(
        navigation().selectedIndex,
        ['board', 'planner', 'notes', 'today'].indexOf(name),
      );
      if (name == 'board') {
        expect(find.byType(CalendarPane), findsNothing);
        expect(find.text('Канбан'), findsWidgets);
      } else if (name == 'planner') {
        expect(find.text('Без расписания'), findsOneWidget);
        expect(find.text('Новая задача'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('create-event')));
        await settle(tester);
        expect(find.byType(TaskEditor), findsOneWidget);
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
      } else if (name == 'notes') {
        expect(find.byType(NotesPage), findsOneWidget);
      } else {
        expect(find.byType(CalendarPane), findsOneWidget);
      }
    }
    await command(tester, LogicalKeyboardKey.digit5);
    expect(navigation().selectedIndex, 3);
    await tester.tap(find.byKey(const ValueKey('mobile-nav-board')));
    await settle(tester);
    expect(navigation().selectedIndex, 0);
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'phone note can be deleted from its card after confirmation without losing other notes',
    (tester) async {
      late String otherId;
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          final other = await repo.createNote();
          otherId = other.id;
          await repo.saveNote(other.id, 'Оставить', 'Важный текст');
        },
      );
      await tester.tap(find.byKey(const ValueKey('create-note')));
      await settle(tester);
      final id = repo.snapshot.notes
          .singleWhere((note) => note.pinned.isEmpty && note.id != otherId)
          .id;
      final field = phoneNoteField(id);
      await tester.enterText(field, '# Черновик\n\nПоследняя правка');
      await settle(tester);
      showPhoneKeyboard(tester);
      await tester.pumpAndSettle();
      final actions = find.byKey(ValueKey('note-actions-$id'));
      expect(actions.hitTestable(), findsOneWidget);
      await tester.tap(actions);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить заметку'));
      await settle(tester);
      expect(find.text('Удалить заметку?'), findsOneWidget);
      expect(find.text('Черновик'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect(repo.snapshot.note(id)!.content, '# Черновик\n\nПоследняя правка');
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tap(actions);
      await settle(tester);
      await tester.tap(find.text('Удалить заметку'));
      await settle(tester);
      await tester.runAsync(() => tester.tap(find.text('Удалить')));
      await settle(tester);
      expect(repo.snapshot.note(id), isNull);
      expect(find.byKey(ValueKey('note-title-$id')), findsNothing);
      await tester.runAsync(repo.reload);
      final deleted = await tester.runAsync(() => repo.db.entity(id));
      expect(deleted!.deleted, isTrue);
      expect(repo.snapshot.note(otherId)!.content, 'Важный текст');
      await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      expect(repo.snapshot.note(id), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final id in ['scratchpad', 'reference']) {
    testInteraction(
      'phone pinned note $id clears only its content after confirmation',
      (tester) async {
        const content = 'Содержимое закреплённой заметки';
        final otherId = id == 'scratchpad' ? 'reference' : 'scratchpad';
        final repo = await workspace(
          tester,
          mobile: true,
          prepare: (repo) async {
            await repo.saveNote(id, '', content);
            await repo.saveNote(otherId, '', 'Сохранить соседнюю заметку');
          },
        );
        await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
        await settle(tester);
        final actions = find.byKey(ValueKey('note-actions-$id'));
        await tester.ensureVisible(actions);
        await tester.tap(actions);
        await settle(tester);
        expect(find.text('Удалить заметку'), findsNothing);
        await tester.tap(find.text('Очистить содержимое'));
        await settle(tester);
        expect(find.text('Очистить заметку?'), findsOneWidget);
        await tester.tap(find.text('Отмена'));
        await settle(tester);
        expect(repo.snapshot.note(id)!.content, content);
        await tester.tap(actions);
        await settle(tester);
        await tester.tap(find.text('Очистить содержимое'));
        await settle(tester);
        await tester.runAsync(() => tester.tap(find.text('Очистить')));
        await settle(tester);
        await tester.runAsync(repo.reload);
        expect(repo.snapshot.note(id)!.content, isEmpty);
        expect(repo.snapshot.note(id)!.pinned, isNotEmpty);
        expect(
          repo.snapshot.note(otherId)!.content,
          'Сохранить соседнюю заметку',
        );
        expect(find.byKey(ValueKey('note-actions-$id')), findsOneWidget);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'new phone note opens above long notes and focuses only once',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) => repo.saveNote(
          'scratchpad',
          'Быстрая заметка',
          List.generate(40, (i) => 'Строка черновика $i').join('\n\n'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('create-note')));
      await settle(tester);
      final id = repo.snapshot.notes
          .singleWhere((note) => note.pinned.isEmpty)
          .id;
      final field = phoneNoteField(id);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      showPhoneKeyboard(tester);
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/note_creation_390.png'),
      );
      await tester.enterText(field, '# Новая идея\n\nТекст');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('notes-keyboard-done')));
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      expect(
        tester.widget<TextField>(phoneNoteField(id)).focusNode!.hasFocus,
        isFalse,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(repo.snapshot.note(id)!.content, '# Новая идея\n\nТекст');
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['scratchpad', 'reference', 'regular']) {
    testInteraction(
      'phone $kind note places the caret on tap and saves on dismissal',
      (tester) async {
        late String id;
        const source = 'Первый абзац\n\nВторой абзац';
        final repo = await workspace(
          tester,
          mobile: true,
          prepare: (repo) async {
            id = kind == 'regular' ? (await repo.createNote()).id : kind;
            await repo.saveNote(id, 'Тестовая заметка', source);
          },
        );
        await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
        await settle(tester);
        final field = phoneNoteField(id);
        await tester.ensureVisible(field);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);

        final start = source.indexOf('Второй');
        await tester.tapAt(phoneNotePosition(tester, id, start));
        await settle(tester);
        final controller = tester.widget<TextField>(field).controller!;
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(controller.selection.isCollapsed, isTrue);
        expect(
          controller.selection.extentOffset,
          inInclusiveRange(start, start + 6),
        );

        showPhoneKeyboard(tester);
        await tester.pumpAndSettle();
        await tester.enterText(field, '$source с правкой');
        await settle(tester);
        expect(repo.snapshot.note(id)!.content, '$source с правкой');
        await tester.tap(find.byKey(const ValueKey('notes-keyboard-done')));
        await settle(tester);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);

        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.ensureVisible(field);
        // Tapping below the document resumes at the end without adding a line.
        final editor = find.ancestor(
          of: field,
          matching: find.byType(LiveMarkdownEditor),
        );
        final bounds = tester.getRect(editor);
        await tester.tapAt(Offset(bounds.center.dx, bounds.bottom - 15));
        await settle(tester);
        expect(controller.selection.extentOffset, controller.text.length);
        expect(controller.text, '$source с правкой');
        await tester.runAsync(repo.reload);
        expect(repo.snapshot.note(id)!.content, '$source с правкой');
        await command(tester, LogicalKeyboardKey.digit1);
        expect(find.byType(CalendarPane), findsOneWidget);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction('phone hold selects a word; copying can span paragraphs', (
    tester,
  ) async {
    const source = 'Первый абзац\n\nВторой абзац';
    await workspace(
      tester,
      mobile: true,
      prepare: (repo) => repo.saveNote('scratchpad', '', source),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
    await settle(tester);
    await tester.longPressAt(
      phoneNotePosition(tester, 'scratchpad', source.indexOf('Второй') + 2),
    );
    await settle(tester);
    final input = phoneNoteInput(tester, 'scratchpad');
    final controller = tester
        .widget<TextField>(phoneNoteField('scratchpad'))
        .controller!;
    expect(controller.selection.isCollapsed, isFalse);
    expect(controller.selection.textInside(controller.text).trim(), 'Второй');

    await command(tester, LogicalKeyboardKey.keyA);
    expect(controller.selection.textInside(controller.text), source);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    input.copySelection(SelectionChangedCause.toolbar);
    await settle(tester);
    expect(copied, source);
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'phone links and checkboxes work without opening the keyboard',
    (tester) async {
      const source = 'См. [[Документ|подробности]] здесь\n\n- [ ] Проверить';
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          final target = await repo.createNote();
          await repo.saveNote(
            target.id,
            'Документ',
            'Содержимое связанной заметки',
          );
          await repo.saveNote('scratchpad', '', source);
        },
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      final checkbox = find.descendant(
        of: phoneNoteField('scratchpad'),
        matching: find.byType(Checkbox),
      );
      await tester.tap(checkbox);
      await settle(tester);
      expect(
        repo.snapshot.note('scratchpad')!.content,
        contains('- [x] Проверить'),
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.text('подробности', findRichText: true));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(
            'Содержимое связанной заметки',
            findRichText: true,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.text('Закрыть'));
      await settle(tester);
      expect(
        tester
            .widget<TextField>(phoneNoteField('scratchpad'))
            .focusNode!
            .hasFocus,
        isFalse,
      );
      await tester.longPress(find.text('подробности', findRichText: true));
      await settle(tester);
      final controller = tester
          .widget<TextField>(phoneNoteField('scratchpad'))
          .controller!;
      expect(controller.selection.textInside(controller.text), 'подробности');
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'phone Done remains above keyboard when a long note is scrolled',
    (tester) async {
      final source = List.generate(60, (i) => 'Строка $i').join('\n');
      await workspace(
        tester,
        mobile: true,
        prepare: (repo) => repo.saveNote('scratchpad', '', source),
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      await tester.tapAt(phoneNotePosition(tester, 'scratchpad', 0));
      await settle(tester);
      showPhoneKeyboard(tester);
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('mobile-notes-list')))
          .controller!;
      scroll.jumpTo(400);
      await tester.pumpAndSettle();
      final done = find.byKey(const ValueKey('notes-keyboard-done'));
      expect(done.hitTestable(), findsOneWidget);
      final bar = tester.getRect(
        find.byKey(const ValueKey('notes-keyboard-bar')),
      );
      expect(bar.bottom, closeTo(844 - 280, 1));
      expect(find.byKey(const ValueKey('create-note')), findsNothing);
      expect(find.byKey(const ValueKey('create-event')), findsNothing);
      await tester.tap(done);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(400, 1));
      expect(
        tester.widget<TextField>(phoneNoteField('scratchpad')).controller!.text,
        source,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'Done closes both title and body without refocusing the other input',
    (tester) async {
      await workspace(tester, mobile: true);
      await tester.tap(find.byKey(const ValueKey('create-note')));
      await settle(tester);
      final panel = tester.widgetList<NotePanel>(find.byType(NotePanel)).first;
      showPhoneKeyboard(tester);
      await tester.pumpAndSettle();
      final title = find.byKey(ValueKey('note-title-${panel.noteId}'));
      final body = phoneNoteField(panel.noteId);
      final done = find.byKey(const ValueKey('notes-keyboard-done'));
      await tester.tap(title);
      await settle(tester);
      await tester.tap(body);
      await settle(tester);
      await tester.tap(done);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(title).focusNode!.hasFocus, isFalse);
      expect(tester.widget<TextField>(body).focusNode!.hasFocus, isFalse);
      await tester.tap(title);
      await settle(tester);
      await tester.enterText(title, 'Название');
      await settle(tester);
      await tester.tap(done);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(body).focusNode!.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'phone landscape keeps native note gestures and keyboard controls',
    (tester) async {
      await workspace(
        tester,
        mobile: true,
        prepare: (repo) =>
            repo.saveNote('scratchpad', '', 'Заметка в горизонтальном режиме'),
      );
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      expect(find.byKey(const ValueKey('mobile-notes-list')), findsOneWidget);
      await tester.tap(phoneNoteField('scratchpad'));
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 162);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final done = find.byKey(const ValueKey('notes-keyboard-done'));
      expect(done.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('notes-keyboard-bar'))).bottom,
        closeTo(390 - 162, 1),
      );
      await tester.tap(done);
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'phone Markdown keyboard bar is minimal and outside tap dismisses editing',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) =>
            repo.saveNote('scratchpad', 'Быстрая заметка', 'Текст заметки'),
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/notes_reading_390.png'),
      );
      await tester.tap(phoneNoteField('scratchpad'));
      await settle(tester);
      showPhoneKeyboard(tester);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/notes_editing_390.png'),
      );
      expect(find.byTooltip('Исходный Markdown'), findsNothing);
      expect(find.byTooltip('Ссылка на заметку'), findsNothing);
      expect(find.byTooltip('Прикрепить изображение или файл'), findsNothing);
      expect(find.byTooltip('Вставить из буфера обмена'), findsNothing);
      expect(find.byKey(const ValueKey('notes-keyboard-done')), findsOneWidget);
      await tester.enterText(
        phoneNoteField('scratchpad'),
        '# Заголовок\n\nТекст',
      );
      await settle(tester);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('workspace-header'))) +
            const Offset(16, 16),
      );
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(repo.snapshot.note('scratchpad')!.content, '# Заголовок\n\nТекст');
      expect(tester.takeException(), isNull);
    },
  );
}
