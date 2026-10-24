import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show testInteraction;

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final index in [0, 1, 2]) {
      testInteraction(
        'Select all covers every Markdown block on $platform from block $index',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          const original = '# Заголовок\n\nВторой абзац\n\n- [ ] Подзадача\n';
          var text = original;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: appTheme(),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: LiveMarkdownEditor(
                      value: original,
                      toolbar: false,
                      onChanged: (v) => text = v,
                    ),
                  ),
                ),
              ),
            ),
          );
          final state = tester.state<LiveMarkdownEditorState>(
            find.byType(LiveMarkdownEditor),
          );
          if (index == 0) {
            state.focusEditor();
          } else {
            await tester.tap(
              find.text(
                index == 1 ? 'Второй абзац' : 'Подзадача',
                findRichText: true,
              ),
            );
          }
          await tester.pumpAndSettle();
          final field = find.byType(TextField);
          expect(field, findsOneWidget);
          final modifier = platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft;
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          final controller = tester.widget<TextField>(field).controller!;
          expect(controller.text, original);
          expect(
            controller.selection,
            const TextSelection(baseOffset: 0, extentOffset: original.length),
          );
          expect(text, original);
          expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
          // Typing replaces the entire selected note, not just one paragraph.
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'Заменено',
              selection: TextSelection.collapsed(offset: 8),
            ),
          );
          await tester.pumpAndSettle();
          expect(text, 'Заменено');
          state.finishEditing();
          await tester.pumpAndSettle();
          expect(find.text('Заменено', findRichText: true), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
