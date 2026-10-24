import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/notes.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

Finder editorField(Finder parent) => find.descendant(
  of: find.descendant(of: parent, matching: find.byType(LiveMarkdownEditor)),
  matching: find.byType(TextField),
);

Future<void> materials(Repository repo) async {
  final a = await repo.createNote(), b = await repo.createNote();
  await repo.saveNote(a.id, 'Материалы встречи', 'Повестка и решения');
  await repo.saveNote(b.id, 'Материалы проекта', 'Документация');
}

Iterable<TextSpan> textSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* textSpans(child);
    }
  }
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

  for (final mobile in [false, true]) {
    testInteraction(
      'wiki picker filters while typing and preserves editor focus (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: materials,
        );
        final a = repo.snapshot.notes.firstWhere(
          (n) => n.title == 'Материалы встречи',
        );
        final b = repo.snapshot.notes.firstWhere(
          (n) => n.title == 'Материалы проекта',
        );
        await command(tester, LogicalKeyboardKey.keyN, shift: true);
        final id = repo.snapshot.notes.last.id;
        final panel = find.byWidgetPredicate(
          (w) => w is NotePanel && w.noteId == id,
        );
        final field = editorField(panel);
        if (mobile) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(tester.view.resetViewInsets);
        }
        await tester.enterText(field, 'Ссылка [[');
        await settle(tester);
        expect(find.byKey(ValueKey('wiki-option-${a.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('wiki-option-${b.id}')), findsOneWidget);
        await tester.enterText(field, 'Ссылка [[материалы в');
        await settle(tester);
        final option = find.byKey(ValueKey('wiki-option-${a.id}'));
        expect(option, findsOneWidget);
        expect(find.byKey(ValueKey('wiki-option-${b.id}')), findsNothing);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile('goldens/wiki_picker_${mobile ? 390 : 1440}.png'),
        );
        if (mobile) {
          await tester.ensureVisible(option);
          await tester.tap(option);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        }
        await settle(tester);
        final input = tester.widget<TextField>(field);
        expect(input.controller!.text, 'Ссылка [[Материалы встречи]]');
        expect(input.focusNode!.hasFocus, isTrue);
        expect(
          input.controller!.selection.extentOffset,
          input.controller!.text.length,
        );
        expect(repo.snapshot.note(id)!.content, 'Ссылка [[Материалы встречи]]');
        expect(find.byKey(const ValueKey('wiki-suggestions')), findsNothing);
        await tester.enterText(field, 'Ссылка [[нет такой заметки');
        await settle(tester);
        expect(find.text('Заметок не найдено'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byKey(const ValueKey('wiki-suggestions')), findsNothing);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        await command(tester, LogicalKeyboardKey.digit2);
        expect(find.text('Планировщик'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'folder menu creates inside folder and focuses Markdown (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) => repo.saveNoteFolder('Работа'),
        );
        final folderId = repo.snapshot.noteFolders.single.id;
        await command(tester, LogicalKeyboardKey.digit4);
        if (mobile) {
          final folders = find.text('Папки и порядок');
          await tester.ensureVisible(folders);
          await tester.tap(folders);
          await settle(tester);
        }
        final folder = find.byKey(ValueKey('note-folder-$folderId'));
        await tester.ensureVisible(folder);
        await tester.tap(folder);
        await settle(tester);
        await tester.tap(
          find.descendant(
            of: folder,
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await settle(tester);
        await tester.tap(find.text('Создать заметку'));
        await settle(tester);
        final note = repo.snapshot.notesInFolder(folderId).single;
        final panel = find.byWidgetPredicate(
          (w) => w is NotePanel && w.noteId == note.id,
        );
        final field = editorField(panel);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(
          tester
              .widget<TextField>(find.byKey(ValueKey('note-title-${note.id}')))
              .focusNode!
              .hasFocus,
          isFalse,
        );
        await tester.enterText(field, 'Новая заметка в папке');
        await settle(tester);
        expect(repo.snapshot.note(note.id)!.content, 'Новая заметка в папке');
        expect(repo.snapshot.note(note.id)!.folderId, folderId);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'global create uses selected folder and root selection resets it',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) => repo.saveNoteFolder('Работа'),
      );
      final folder = repo.snapshot.noteFolders.single;
      await command(tester, LogicalKeyboardKey.digit4);
      await tester.tap(find.byKey(ValueKey('note-folder-${folder.id}')));
      await command(tester, LogicalKeyboardKey.keyN, shift: true);
      expect(repo.snapshot.notesInFolder(folder.id), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('note-folder-')));
      await command(tester, LogicalKeyboardKey.keyN, shift: true);
      expect(repo.snapshot.notesInFolder(''), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'wiki keyboard selection keeps an event draft and source text around caret',
    (tester) async {
      final repo = await workspace(tester, prepare: materials);
      await command(tester, LogicalKeyboardKey.keyN);
      await tester.enterText(
        find.byKey(const ValueKey('task-title')),
        'Обсудить проект',
      );
      await command(tester, LogicalKeyboardKey.enter);
      final field = editorField(find.byType(TaskEditor));
      await tester.enterText(field, 'До [[мат]] после');
      tester.widget<TextField>(field).controller!.selection =
          const TextSelection.collapsed(offset: 8);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(TaskEditor), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'До [[Материалы проекта]] после',
      );
      expect(repo.snapshot.tasks, isEmpty);
      await command(tester, LogicalKeyboardKey.keyA);
      final source = editorField(find.byType(TaskEditor));
      await tester.enterText(source, '[[материалы встречи');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(
        tester.widget<TextField>(source).controller!.text,
        '[[Материалы встречи]]',
      );
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      expect(repo.snapshot.tasks.single.description, '[[Материалы встречи]]');
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('wiki preview opens the note and explains missing targets', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await materials(repo);
        await repo.saveNoteContent(
          'scratchpad',
          '[[Материалы встречи]]\n\n[[Удалённая]]',
        );
      },
    );
    await command(tester, LogicalKeyboardKey.digit4);
    final link = find.descendant(
      of: find.byType(MarkdownPreview),
      matching: find.text('Материалы встречи'),
    );
    await tester.tap(link);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Повестка и решения', findRichText: true),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Закрыть'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(MarkdownPreview),
        matching: find.text('Удалённая'),
      ),
    );
    await settle(tester);
    expect(find.text('Заметка не найдена'), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await settle(tester);
    expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'inline wiki aliases render as links while code stays literal',
    (tester) async {
      await workspace(
        tester,
        prepare: (repo) async {
          await materials(repo);
          await repo.saveNoteContent(
            'scratchpad',
            'До [[Материалы встречи|открыть]] после\n\n`[[Материалы встречи]]`\n\n```\n[[Материалы встречи]]\n```',
          );
        },
      );
      await command(tester, LogicalKeyboardKey.digit4);
      final links = tester
          .widgetList<RichText>(
            find.descendant(
              of: find.byType(MarkdownPreview),
              matching: find.byType(RichText),
            ),
          )
          .expand((rich) => textSpans(rich.text))
          .where((span) => span.recognizer is TapGestureRecognizer)
          .toList();
      expect(links, hasLength(1));
      expect(links.single.toPlainText(), 'открыть');
      (links.single.recognizer as TapGestureRecognizer).onTap!();
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Повестка и решения', findRichText: true),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Закрыть'));
      await settle(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
