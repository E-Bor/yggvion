import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final mobile in [false, true]) {
    testInteraction(
      'note links can be attached to events and previewed (mobile: $mobile)',
      (tester) async {
        late String id;
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            final note = await repo.createNote();
            id = note.id;
            await repo.saveNote(id, 'Материалы встречи', 'Описание для превью');
          },
        );
        await command(tester, LogicalKeyboardKey.keyN);
        await tester.enterText(
          find.byKey(const ValueKey('task-title')),
          'Обсудить проект',
        );
        final link = find.descendant(
          of: find.byType(TaskEditor),
          matching: find.byTooltip('Ссылка на заметку'),
        );
        await tester.ensureVisible(link);
        await tester.tap(link);
        await settle(tester);
        await tester.tap(find.text('Материалы встречи'));
        await settle(tester);
        await tester.tap(find.text('Сохранить'));
        await settle(tester);
        expect(repo.snapshot.tasks.single.description, contains('(note:$id)'));
        await tester.runAsync(() async {
          await repo.saveNoteContent('scratchpad', '[Материалы](note:$id)');
        });
        await command(tester, LogicalKeyboardKey.digit4);
        final card = find.descendant(
          of: find.byType(MarkdownPreview),
          matching: find.text('Материалы встречи'),
        );
        await tester.ensureVisible(card.first);
        await tester.tap(card.first);
        await settle(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Описание для превью', findRichText: true),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Открыть заметку'));
        await settle(tester);
        expect(find.byKey(ValueKey('note-title-$id')), findsOneWidget);
        expect(find.byType(TaskEditor), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testInteraction('folder navigation and drag order use saved ranks', (
    tester,
  ) async {
    late String a, b;
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await repo.saveNoteFolder('Работа');
        final first = await repo.createNote(), second = await repo.createNote();
        a = first.id;
        b = second.id;
        await repo.saveNote(a, 'Первая', 'A');
        await repo.saveNote(b, 'Вторая', 'B');
      },
    );
    await command(tester, LogicalKeyboardKey.digit4);
    final first = find.byKey(ValueKey('note-list-$a'));
    final second = find.byKey(ValueKey('note-list-$b'));
    final handle = find.descendant(
      of: second,
      matching: find.byType(ReorderableDragStartListener),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getTopLeft(first) + const Offset(20, 21));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester
        .pumpAndSettle(); // Drop animation starts the asynchronous save.
    await settle(tester);
    expect(repo.snapshot.notesInFolder('').first.id, b);
    final menu = find.descendant(
      of: first,
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(menu);
    await settle(tester);
    await tester.tap(find.text('Переместить → Работа'));
    await settle(tester);
    expect(
      repo.snapshot
          .notesInFolder(repo.snapshot.noteFolders.single.id)
          .single
          .id,
      a,
    );
    await tester.tap(find.text('Работа'));
    await settle(tester);
    expect(find.byKey(ValueKey('note-list-$a')), findsNothing);
    await tester.tap(find.text('Работа'));
    await settle(tester);
    expect(find.byKey(ValueKey('note-list-$a')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testInteraction('opening a linked note preserves an unsaved event draft', (
    tester,
  ) async {
    late String id;
    final repo = await workspace(
      tester,
      mobile: true,
      prepare: (repo) async {
        final note = await repo.createNote();
        id = note.id;
        await repo.saveNote(id, 'Материалы', 'Текст');
      },
    );
    await command(tester, LogicalKeyboardKey.keyN);
    await tester.enterText(
      find.byKey(const ValueKey('task-title')),
      'Несохранённая встреча',
    );
    unawaited(showNotePreview(tester.element(find.byType(TaskEditor)), id));
    await settle(tester);
    await tester.tap(find.text('Открыть заметку'));
    await settle(tester);
    expect(find.byKey(ValueKey('note-title-$id')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('task-title')))
          .controller!
          .text,
      'Несохранённая встреча',
    );
    await tester.tap(find.text('Сохранить'));
    await settle(tester);
    expect(repo.snapshot.tasks.single.title, 'Несохранённая встреча');
    expect(tester.takeException(), isNull);
  });
}
