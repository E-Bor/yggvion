import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/notes.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart'
    show workspace, settle, settleSearch, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  testInteraction(
    'planner blur keeps shortcuts and search opens notes by content',
    (tester) async {
      await workspace(
        tester,
        prepare: (repo) async {
          final note = await repo.createNote();
          await repo.saveNote(
            note.id,
            'Прежнее название',
            '# План поездки\n\nСписок вещей',
          );
        },
      );
      await command(tester, LogicalKeyboardKey.digit2);
      await tester.enterText(find.byType(TextField), 'Фильтр задач');
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('workspace-header'))) +
            const Offset(16, 4),
        kind: PointerDeviceKind.mouse,
      );
      await settle(tester);
      await command(tester, LogicalKeyboardKey.keyK);
      expect(find.byType(SearchDialog), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(SearchDialog),
          matching: find.byType(TextField),
        ),
        'поездки',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await settleSearch(tester);
      expect(find.text('Прежнее название'), findsOneWidget);
      await tester.tap(find.text('Прежнее название'));
      await settle(tester);
      expect(find.byType(NotesPage), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == null),
        findsNothing,
      );
      // Disposing a focused note while switching sections also retains shortcuts.
      await tester.tap(find.text('Список вещей', findRichText: true));
      await settle(tester);
      await command(tester, LogicalKeyboardKey.digit1);
      await command(tester, LogicalKeyboardKey.digit4);
      expect(find.byType(NotesPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(find.text('Горячие клавиши'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await command(tester, LogicalKeyboardKey.keyF);
      expect(find.byType(SearchDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final source in [false, true]) {
    testInteraction(
      'desktop shortcuts survive clicking outside a note (source: $source)',
      (tester) async {
        final repo = await workspace(
          tester,
          prepare: (repo) => repo.saveNote(
            'scratchpad',
            'Быстрая заметка',
            'Текст для редактирования',
          ),
        );
        await command(tester, LogicalKeyboardKey.digit4);
        if (source) {
          await tester.tap(find.byTooltip('Исходный Markdown'));
        } else {
          await tester.tap(
            find.text('Текст для редактирования', findRichText: true),
          );
        }
        await settle(tester);
        await tester.enterText(find.byType(TextField), 'Сохранённая правка');
        await settle(tester);
        // A real mouse click invokes TextField's default onTapOutside.
        await tester.tapAt(
          tester.getTopLeft(find.byKey(const ValueKey('workspace-header'))) +
              const Offset(16, 4),
          kind: PointerDeviceKind.mouse,
        );
        await settle(tester);
        expect(tester.testTextInput.isVisible, isFalse);
        await command(tester, LogicalKeyboardKey.keyF);
        expect(find.byType(SearchDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await command(tester, LogicalKeyboardKey.keyN);
        expect(find.byType(TaskEditor), findsOneWidget);
        // Workspace shortcuts must not navigate behind an open task dialog.
        await command(tester, LogicalKeyboardKey.digit2);
        expect(find.byType(NotesPage), findsOneWidget);
        await tester.tap(find.byTooltip('Закрыть'));
        await settle(tester);
        for (final digit in [
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit4,
        ]) {
          await command(tester, digit);
        }
        expect(find.byType(NotesPage), findsOneWidget);
        expect(
          repo.snapshot.notes.singleWhere((n) => n.id == 'scratchpad').content,
          'Сохранённая правка',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
