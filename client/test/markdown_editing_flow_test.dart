import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/domain/markdown_blocks.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/markdown_code_block.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show testInteraction;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // Deterministic glyphs in goldens; the app uses the platform's monospace font.
    await (FontLoader(
      'monospace',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
  });
  test('only trailing blank lines are normalized', () {
    expect(normalizeMarkdownEnding('A\n\nB\n\n \n\t'), 'A\n\nB\n');
    expect(normalizeMarkdownEnding('A\n'), 'A\n');
    expect(normalizeMarkdownEnding('A  '), 'A  ');
    expect(normalizeMarkdownEnding('\n\n\n'), '\n');
  });

  testInteraction('inline formatting closes without leaving the document', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var saved = '';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: LiveMarkdownEditor(
              value: '',
              toolbar: false,
              placeholder: 'Черновик',
              onChanged: (value) => saved = value,
            ),
          ),
        ),
      ),
    );
    final state = tester.state<LiveMarkdownEditorState>(
      find.byType(LiveMarkdownEditor),
    );
    state.focusEditor();
    await tester.pumpAndSettle();
    const source = '# Заголовок\n**слово** _курсив_ ~~зачёркнуто~~ `код` ';
    await tester.enterText(find.byType(TextField), source);
    await tester.pumpAndSettle();
    final span = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable
        .text!;
    final styled = <TextSpan>[];
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        styled.add(span);
        for (final child in span.children ?? <InlineSpan>[]) {
          visit(child);
        }
      }
    }

    visit(span);
    expect(styled.any((s) => s.style?.fontSize == 26), isTrue);
    expect(styled.any((s) => s.style?.fontWeight == FontWeight.w700), isTrue);
    expect(styled.any((s) => s.style?.fontStyle == FontStyle.italic), isTrue);
    expect(
      styled.any((s) => s.style?.decoration == TextDecoration.lineThrough),
      isTrue,
    );
    expect(
      styled.where((s) => s.text == '**').every((s) => s.style?.fontSize == 0),
      isTrue,
    );
    expect(span.toPlainText(), source);
    // Composition underlines only the new word; previous formatting must not
    // collapse to raw text when the phone's keyboard offers a candidate.
    final composing = '$sourceтекст';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: composing,
        selection: TextSelection.collapsed(offset: composing.length),
        composing: TextRange(start: source.length, end: composing.length),
      ),
    );
    await tester.pumpAndSettle();
    styled.clear();
    visit(
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable
          .text!,
    );
    expect(styled.any((s) => s.style?.fontSize == 26), isTrue);
    expect(styled.any((s) => s.style?.fontWeight == FontWeight.w700), isTrue);
    expect(
      styled.any(
        (s) =>
            s.text == 'текст' &&
            s.style?.decoration?.contains(TextDecoration.underline) == true,
      ),
      isTrue,
    );
    await tester.enterText(find.byType(TextField), source);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      source,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), '$source\n\n\n');
    await tester.pumpAndSettle();
    expect(saved, '$source\n');
    expect(find.text('Черновик'), findsNothing);
    state.finishEditing();
    await tester.pumpAndSettle();
    expect(find.text('Черновик'), findsNothing);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    testInteraction(
      'newlines keep exact source, geometry and IME selection on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        var saved = 'Первая\nВторая';
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: appTheme(),
              home: Scaffold(
                body: LiveMarkdownEditor(
                  value: saved,
                  onChanged: (value) => saved = value,
                ),
              ),
            ),
          ),
        );
        final state = tester.state<LiveMarkdownEditorState>(
          find.byType(LiveMarkdownEditor),
        );
        state.focusEditor();
        await tester.pumpAndSettle();
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        controller.selection = const TextSelection.collapsed(offset: 0);
        for (var count = 1; count <= 3; count++) {
          final source = '${'\n' * count}Первая\nВторая';
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: source,
              selection: TextSelection.collapsed(offset: count),
            ),
          );
          await tester.pumpAndSettle();
          expect(controller.text, source);
          expect(saved, source);
          expect(controller.selection.extentOffset, count);
          final render = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final top = render
              .getLocalRectForCaret(const TextPosition(offset: 0))
              .top;
          final line = render
              .getLocalRectForCaret(TextPosition(offset: count))
              .top;
          final next = render
              .getLocalRectForCaret(TextPosition(offset: count + 7))
              .top;
          expect(line - top, closeTo((next - line) * count, .1));
        }
        // A phone's Backspace edits the native full document too.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n\nПервая\nВторая',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pumpAndSettle();
        expect(saved, '\n\nПервая\nВторая');
        state.finishEditing();
        await tester.pumpAndSettle();
        // Clicking below the content must not append phantom newlines.
        final editor = tester.getRect(find.byType(LiveMarkdownEditor));
        if (platform == TargetPlatform.macOS) {
          await tester.tapAt(Offset(editor.center.dx, editor.bottom - 10));
          await tester.pumpAndSettle();
          expect(controller.text, saved);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'closed code block previews and copies while typing the next line',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var saved = '';
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: LiveMarkdownEditor(
                value: '',
                onChanged: (value) => saved = value,
              ),
            ),
          ),
        ),
      );
      tester
          .state<LiveMarkdownEditorState>(find.byType(LiveMarkdownEditor))
          .focusEditor();
      await tester.pumpAndSettle();
      const source = '```dart\nfinal value = 1;\n```\nДальше';
      await tester.enterText(find.byType(TextField), source);
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownCodeBlock), findsOneWidget);
      expect(saved, source);
      await tester.tap(find.byTooltip('Скопировать код'));
      await tester.pumpAndSettle();
      expect(copied?.trimRight(), 'final value = 1;');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      expect(controller.selection.extentOffset, source.length);
      controller.selection = const TextSelection.collapsed(offset: 12);
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownCodeBlock), findsNothing);
      expect(controller.text, source);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testInteraction('live document appearance mobile=$mobile', (tester) async {
      debugDefaultTargetPlatformOverride = mobile
          ? TargetPlatform.iOS
          : TargetPlatform.macOS;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(mobile ? 390 : 960, 844);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Заметка')),
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: LiveMarkdownEditor(
                    value: '',
                    toolbar: false,
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      tester
          .state<LiveMarkdownEditorState>(find.byType(LiveMarkdownEditor))
          .focusEditor();
      await tester.pumpAndSettle();
      const source =
          '# План на неделю\n\n**Самое важное** — оставить время для себя.\nКороткая строка, _курсив_ и `код`.\n\n- [x] Подготовить материалы\n- [ ] Обсудить план\n\n```dart\nfinal duration = Duration(minutes: 30);\n```\n\nПродолжаю писать ';
      await tester.enterText(find.byType(TextField), source);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        source,
      );
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.byType(MarkdownCodeBlock), findsOneWidget);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/markdown_live_${mobile ? 390 : 960}.png'),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testInteraction(
      'arrows and deletion cross paragraph boundaries on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        var saved = 'Первая\n\nВторая';
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: appTheme(),
              home: Scaffold(
                body: LiveMarkdownEditor(
                  value: saved,
                  toolbar: false,
                  onChanged: (value) => saved = value,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Вторая', findRichText: true));
        await tester.pumpAndSettle();
        TextEditingController controller() =>
            tester.widget<TextField>(find.byType(TextField)).controller!;
        controller().selection = const TextSelection.collapsed(offset: 8);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(controller().text, 'Первая\n\nВторая');
        expect(controller().selection.extentOffset, 7);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(controller().text, 'Первая\n\nВторая');
        expect(controller().selection.extentOffset, 8);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(controller().text, 'Первая\n\nВторая');
        expect(controller().selection.extentOffset, 7);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(controller().text, 'Первая\n\nВторая');
        expect(controller().selection.extentOffset, 8);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(saved, 'Первая\nВторая');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(saved, 'ПерваяВторая');
        expect(controller().selection.extentOffset, 6);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final native in [false, true]) {
    testInteraction('document undo/redo after block reflow (native=$native)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = native
          ? TargetPlatform.iOS
          : TargetPlatform.macOS;
      var saved = '';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: LiveMarkdownEditor(
                value: '',
                onChanged: (value) => saved = value,
              ),
            ),
          ),
        ),
      );
      final state = tester.state<LiveMarkdownEditorState>(
        find.byType(LiveMarkdownEditor),
      );
      state.focusEditor();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(TextField), 'Первый\n\nВторой');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      if (native) {
        UndoManager.client!.handlePlatformUndo(UndoDirection.undo);
      } else {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.pumpAndSettle();
      expect(saved, '');
      if (native) {
        UndoManager.client!.handlePlatformUndo(UndoDirection.redo);
      } else {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      }
      await tester.pumpAndSettle();
      expect(saved, 'Первый\n\nВторой');
      expect(tester.takeException(), isNull);
    });
  }
}
