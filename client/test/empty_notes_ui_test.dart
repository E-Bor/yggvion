import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/notes.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  testInteraction(
    'quick return waits for queued cleanup before reopening notes',
    (tester) async {
      final repo = await workspace(tester, mobile: true);
      await command(tester, LogicalKeyboardKey.keyN, shift: true);
      final gate = Completer<void>();
      final blocked = repo.serial(() => gate.future);
      try {
        await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('mobile-nav-notes')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('note-cleanup-progress')),
          findsOneWidget,
        );
        expect(find.byType(NotePanel), findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is TextField && w.maxLines == null && w.focusNode!.hasFocus,
          ),
          findsNothing,
        );
      } finally {
        gate.complete();
        await settle(tester);
        await tester.runAsync(() => blocked);
      }
      expect(find.byType(NotesPage), findsOneWidget);
      expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), isEmpty);
      await command(tester, LogicalKeyboardKey.keyN, shift: true);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.maxLines == null && w.focusNode!.hasFocus,
        ),
        'Сохранить',
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-today')));
      await settle(tester);
      expect(
        repo.snapshot.notes.where((n) => n.pinned.isEmpty).single.content,
        'Сохранить',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    testInteraction(
      'leaving notes discards blanks and keeps significant text (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(tester, mobile: mobile);
        final saved = <String, String>{};
        Future<void> navigate(String page, LogicalKeyboardKey key) async {
          if (mobile) {
            await tester.tap(find.byKey(ValueKey('mobile-nav-$page')));
            await settle(tester);
          } else {
            await command(tester, key);
          }
        }

        Future<void> leaveAndReturn() async {
          await navigate('today', LogicalKeyboardKey.digit1);
          await tester.runAsync(repo.reload);
          await navigate('notes', LogicalKeyboardKey.digit4);
        }

        for (final content in [
          '',
          '\n\n',
          ' \n\t  \n ',
          '  x  \n',
          ' \n🌱  ',
        ]) {
          await command(tester, LogicalKeyboardKey.keyN, shift: true);
          final field = find.byWidgetPredicate(
            (w) =>
                w is TextField && w.maxLines == null && w.focusNode!.hasFocus,
          );
          expect(field, findsOneWidget);
          final id = tester
              .widget<NotePanel>(
                find.ancestor(of: field, matching: find.byType(NotePanel)),
              )
              .noteId;
          expect(repo.snapshot.notes.any((note) => note.id == id), isTrue);
          await tester.enterText(field, content);
          // Leave immediately; do not wait for autosave before navigating.
          await leaveAndReturn();
          if (content.trim().isNotEmpty) saved[id] = content;
          expect({
            for (final note in repo.snapshot.notes.where(
              (n) => n.pinned.isEmpty,
            ))
              note.id: note.content,
          }, saved);
          if (content.trim().isEmpty) {
            expect(
              find.byWidgetPredicate((w) => w is NotePanel && w.noteId == id),
              findsNothing,
            );
            expect(
              find.byWidgetPredicate(
                (w) => w is NotePanel && w.noteId == 'scratchpad',
              ),
              findsOneWidget,
            );
          }
        }

        // Erasing a previously saved note follows the same rule.
        final text = find.descendant(
          of: find.byType(NotePanel),
          matching: find.text('🌱', findRichText: true),
        );
        if (mobile) {
          final field = find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                w.maxLines == null &&
                w.controller!.text.contains('🌱'),
          );
          await tester.ensureVisible(field);
          await tester.tap(field);
        } else {
          await tester.tap(text);
        }
        await settle(tester);
        await tester.enterText(
          find.byWidgetPredicate(
            (w) =>
                w is TextField && w.maxLines == null && w.focusNode!.hasFocus,
          ),
          '  \n\n ',
        );
        await leaveAndReturn();
        saved.removeWhere((id, content) => content.contains('🌱'));
        expect({
          for (final note in repo.snapshot.notes.where((n) => n.pinned.isEmpty))
            note.id: note.content,
        }, saved);
        expect(
          repo.snapshot.notes
              .where((note) => note.pinned.isNotEmpty)
              .map((n) => n.id),
          unorderedEquals(['scratchpad', 'reference']),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
