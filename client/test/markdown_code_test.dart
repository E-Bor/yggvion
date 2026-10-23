import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/ui/markdown_code_block.dart';
import 'package:yggvion/ui/markdown_editor.dart';
import 'package:yggvion/ui/theme.dart';
import 'interaction_test.dart' show testInteraction;

void main() {
  testInteraction(
    'code preserves whitespace; copy stays in visible corner after scrolling',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final code =
          '  final value = "${'long line '.padRight(800, 'x')}";\n\n\treturn value;';
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
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: MarkdownPreview(text: '```dart\n$code\n```'),
                ),
              ),
            ),
          ),
        ),
      );
      final block = find.byType(MarkdownCodeBlock);
      expect(block, findsOneWidget);
      final rendered = tester.widget<MarkdownCodeBlock>(block).code;
      expect(rendered.trimRight(), code);
      final copy = find.byTooltip('Скопировать код');
      final opacity = find
          .ancestor(of: copy, matching: find.byType(AnimatedOpacity))
          .first;
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      final before = tester.getCenter(copy);
      await tester.drag(
        find.descendant(
          of: block,
          matching: find.byType(SingleChildScrollView),
        ),
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(copy), before);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(before);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, rendered);
      expect(find.byTooltip('Скопировано'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testInteraction('phone code copy is available without hover', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
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
      MaterialApp(
        theme: appTheme(),
        home: const Scaffold(
          body: MarkdownCodeBlock(code: '  first\n\n\tlast', selectable: false),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Скопировать код'));
    await tester.pumpAndSettle();
    expect(copied, '  first\n\n\tlast');
    await tester.pumpWidget(const SizedBox());
  });

  testInteraction(
    'live preview keeps blank lines and nested shorter fences inside one code block',
    (tester) async {
      const markdown =
          '````markdown\n```dart\n\n# inside code\n~~~\n\n```\n````\n\n## Outside';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LiveMarkdownEditor(
                  value: markdown,
                  toolbar: false,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      final blocks = tester.widgetList<MarkdownCodeBlock>(
        find.byType(MarkdownCodeBlock),
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.code, contains('```dart\n\n# inside code\n~~~'));
      expect(
        find.textContaining('Outside', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
