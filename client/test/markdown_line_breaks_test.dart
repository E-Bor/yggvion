import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/theme.dart';

import 'interaction_test.dart' show testInteraction;

Future<void> showPreview(WidgetTester tester, Widget child) =>
    tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: appTheme(),
          home: Scaffold(body: SizedBox(width: 600, child: child)),
        ),
      ),
    );

double lineTop(WidgetTester tester, String text) {
  final selectable = find.descendant(
    of: find.byType(MarkdownPreview),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is EditableText && widget.controller.text.contains(text),
    ),
  );
  if (selectable.evaluate().isNotEmpty) {
    final widget = tester.widget<EditableText>(selectable);
    final render = tester.state<EditableTextState>(selectable).renderEditable;
    final caret = render.getLocalRectForCaret(
      TextPosition(offset: widget.controller.text.indexOf(text)),
    );
    return render.localToGlobal(caret.topLeft).dy;
  }
  final richText = find.descendant(
    of: find.byType(MarkdownPreview),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(text),
    ),
  );
  final widget = tester.widget<RichText>(richText);
  final render = tester.renderObject<RenderParagraph>(richText);
  final start = widget.text.toPlainText().indexOf(text);
  final box = render
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + text.length),
      )
      .first;
  return render.localToGlobal(Offset(box.left, box.top)).dy;
}

void expectSeparateLines(WidgetTester tester) {
  final first = lineTop(tester, 'Morning train');
  final second = lineTop(tester, 'Hotel check-in');
  final third = lineTop(tester, 'Evening walk');
  expect(
    second,
    greaterThan(first),
    reason: 'The first Enter must stay visible',
  );
  expect(
    third,
    greaterThan(second),
    reason: 'The next Enter must stay visible',
  );
}

void main() {
  const examples = {
    'plain text': 'Morning train\nHotel check-in\nEvening walk',
    'pasted bullets': '• Morning train\n• Hotel check-in\n• Evening walk',
    'list continuation': '- Morning train\n  Hotel check-in\n- Evening walk',
    'numbered list': '1. Morning train\n   Hotel check-in\n2. Evening walk',
    'checklist': '- [ ] Morning train\n  Hotel check-in\n- [x] Evening walk',
    'inline formatting and links':
        '**Morning train**\n[Hotel check-in](https://example.com/route)\n_Evening walk_',
    'explicit Markdown breaks':
        'Morning train  \nHotel check-in\\\nEvening walk',
  };
  for (final selectable in [true, false]) {
    for (final example in examples.entries) {
      testWidgets(
        '${example.key} retains line breaks, selectable=$selectable',
        (tester) async {
          await showPreview(
            tester,
            MarkdownPreview(text: example.value, selectable: selectable),
          );
          expectSeparateLines(tester);
          if (example.key == 'plain text' ||
              example.key == 'explicit Markdown breaks') {
            expect(
              lineTop(tester, 'Hotel check-in') -
                  lineTop(tester, 'Morning train'),
              closeTo(
                lineTop(tester, 'Evening walk') -
                    lineTop(tester, 'Hotel check-in'),
                .1,
              ),
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    testInteraction(
      'finishing an edit preserves lines and source on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        var saved = '';
        await showPreview(
          tester,
          LiveMarkdownEditor(value: saved, onChanged: (value) => saved = value),
        );
        final editor = tester.state<LiveMarkdownEditorState>(
          find.byType(LiveMarkdownEditor),
        );
        editor.focusEditor();
        await tester.pumpAndSettle();
        const source =
            '• Morning train\n• Hotel check-in\n\nEvening walk\nNext day';
        await tester.enterText(find.byType(TextField), source);
        editor.finishEditing();
        await tester.pumpAndSettle();
        expect(saved, source);
        expectSeparateLines(tester);
        expect(
          lineTop(tester, 'Next day'),
          greaterThan(lineTop(tester, 'Evening walk')),
        );
        editor.focusEditor();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          source,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
