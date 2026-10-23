import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/notes.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

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
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == null,
      );
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/note_creation_390.png'),
      );
      await tester.enterText(field, '# Новая идея\n\nТекст');
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('finish-note-$id')));
      await settle(tester);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      expect(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
        findsNothing,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.text('Новая идея', findRichText: true), findsOneWidget);
      expect(
        repo.snapshot.notes.singleWhere((note) => note.id == id).content,
        '# Новая идея\n\nТекст',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['scratchpad', 'reference', 'regular']) {
    testInteraction(
      'phone $kind note edits only on hold and saves before dismissal',
      (tester) async {
        late String id;
        final repo = await workspace(
          tester,
          mobile: true,
          prepare: (repo) async {
            id = kind == 'regular' ? (await repo.createNote()).id : kind;
            await repo.saveNote(
              id,
              'Тестовая заметка',
              'Первый абзац\n\nВторой абзац',
            );
          },
        );
        await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
        await settle(tester);
        final second = find.text('Второй абзац', findRichText: true);
        await tester.scrollUntilVisible(
          second,
          120,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('mobile-notes-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(second);
        await settle(tester);
        expect(
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
          findsNothing,
        );
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byTooltip('Вставить из буфера обмена'), findsNothing);

        await tester.longPress(second);
        await settle(tester);
        var field = find.byWidgetPredicate(
          (w) => w is TextField && w.maxLines == null,
        );
        expect(field, findsOneWidget);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Второй абзац',
        );
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        // Tapping inside the active input must still position the cursor.
        await tester.tap(field);
        await settle(tester);
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.enterText(field, 'Второй абзац с правкой');
        await settle(tester);
        expect(
          repo.snapshot.notes.singleWhere((n) => n.id == id).content,
          'Первый абзац\n\nВторой абзац с правкой',
        );

        await tester.tap(find.text('Первый абзац', findRichText: true));
        await settle(tester);
        expect(
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
          findsNothing,
        );
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.longPress(
          find.text('Второй абзац с правкой', findRichText: true),
        );
        await settle(tester);
        await tester.tapAt(
          tester.getTopLeft(
                find.byWidgetPredicate(
                  (widget) => widget is NotePanel && widget.noteId == id,
                ),
              ) +
              const Offset(12, 8),
        );
        await settle(tester);
        expect(
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
          findsNothing,
        );
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.longPress(
          find.text('Второй абзац с правкой', findRichText: true),
        );
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('finish-note-$id')));
        await settle(tester);
        expect(
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
          findsNothing,
        );
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.runAsync(repo.reload);
        expect(
          repo.snapshot.notes.singleWhere((n) => n.id == id).content,
          'Первый абзац\n\nВторой абзац с правкой',
        );
        await command(tester, LogicalKeyboardKey.digit1);
        expect(find.byType(CalendarPane), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'phone Markdown toolbar stays interactive and source mode closes on outside tap',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          await repo.saveNote('scratchpad', 'Быстрая заметка', 'Текст заметки');
        },
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
      await settle(tester);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/notes_reading_390.png'),
      );
      await tester.longPress(find.text('Текст заметки', findRichText: true));
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/notes_editing_390.png'),
      );
      await tester.ensureVisible(find.byTooltip('Исходный Markdown'));
      await tester.tap(find.byTooltip('Исходный Markdown'));
      await settle(tester);
      expect(find.byTooltip('Live Preview'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
        '# Заголовок\n\nТекст',
      );
      await settle(tester);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('workspace-header'))) +
            const Offset(16, 16),
      );
      await settle(tester);
      expect(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
        findsNothing,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        repo.snapshot.notes.singleWhere((n) => n.id == 'scratchpad').content,
        '# Заголовок\n\nТекст',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
