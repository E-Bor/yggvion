import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'interaction_test.dart' show workspace, settle, command, testInteraction;
import 'mobile_notes_test.dart' show phoneNoteField;

Future<void> tapLink(WidgetTester tester, String label) async {
  final text = find
      .byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(label),
      )
      .first;
  await tester.ensureVisible(text);
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final start = paragraph.text.toPlainText().indexOf(label);
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + label.length),
      )
      .first
      .toRect();
  await tester.tapAt(paragraph.localToGlobal(box.center));
  await settle(tester);
}

void main() {
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  final launched = <Map<Object?, Object?>>[];
  var launchSucceeds = true;
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  setUp(() {
    launched.clear();
    launchSucceeds = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, (call) async {
          if (call.method == 'launch') {
            launched.add(Map<Object?, Object?>.from(call.arguments as Map));
            return launchSucceeds;
          }
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, null);
  });

  const route =
      'https://2gis.ru/moscow/directions/tab/bus/points/'
      '37.6,55.7;123456789%7C37.7,55.8;987654321';
  const encoded = 'https://example.com/a%2Fb?next=%2Fdone%3Fx%3D1#part%20two';
  const literalPercent = 'https://example.com/a%252Fb?percent=%25&pipe=%7c';
  const cases = [
    (route, route, route),
    ('Маршрут ($route).', route, route),
    ('<$route>', route, route),
    ('[Маршрут]($route)', 'Маршрут', route),
    (encoded, encoded, encoded),
    (
      literalPercent,
      literalPercent,
      'https://example.com/a%252Fb?percent=%25&pipe=%7C',
    ),
    (
      'https://example.com/100%?invalid=%zz',
      'https://example.com/100%?invalid=%zz',
      'https://example.com/100%25?invalid=%25zz',
    ),
    (
      '[https://example.com/a%2Fb](https://example.com/a%252Fb)',
      'https://example.com/a%2Fb',
      'https://example.com/a%252Fb',
    ),
    (
      'www.example.com/a%20b',
      'www.example.com/a%20b',
      'http://www.example.com/a%20b',
    ),
    (
      'Открыть https://example.com/docs?q=1&mode=2#part сейчас',
      'https://example.com/docs?q=1&mode=2#part',
      'https://example.com/docs?q=1&mode=2#part',
    ),
    ('Сайт http://example.com.', 'http://example.com', 'http://example.com'),
    (
      'Сайт www.example.com/docs.',
      'www.example.com/docs',
      'http://www.example.com/docs',
    ),
    (
      'См. (https://example.com/a_(b)).',
      'https://example.com/a_(b)',
      'https://example.com/a_(b)',
    ),
    (
      '**https://example.com/a_b_c**',
      'https://example.com/a_b_c',
      'https://example.com/a_b_c',
    ),
    (
      '<https://example.com/page>',
      'https://example.com/page',
      'https://example.com/page',
    ),
    ('Почта mail@example.com.', 'mail@example.com', 'mailto:mail@example.com'),
    (
      '[https://example.com](https://other.example.com)',
      'https://example.com',
      'https://other.example.com',
    ),
  ];

  for (final mobile in [false, true]) {
    for (var i = 0; i < cases.length; i++) {
      final (source, label, url) = cases[i];
      testInteraction(
        'plain links launch externally without editing $i (mobile: $mobile)',
        (tester) async {
          final repo = await workspace(
            tester,
            mobile: mobile,
            prepare: (repo) => repo.saveNoteContent('scratchpad', source),
          );
          await command(tester, LogicalKeyboardKey.digit4);
          expect(launched, isEmpty);
          await tapLink(tester, label);
          expect(launched, hasLength(1));
          expect(launched.single['url'], url);
          expect(launched.single['useSafariVC'], isFalse);
          expect(launched.single['useWebView'], isFalse);
          expect(repo.snapshot.note('scratchpad')!.content, source);
          expect(tester.testTextInput.isVisible, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testInteraction(
    'holding an automatic link selects its source without the surrounding punctuation',
    (tester) async {
      const url = 'https://example.com/a_b?q=1#part';
      const source = 'Ссылка ($url). Ещё текст';
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) => repo.saveNoteContent('scratchpad', source),
      );
      await command(tester, LogicalKeyboardKey.digit4);
      await tester.longPress(find.text(url, findRichText: true));
      await settle(tester);
      final field = tester.widget<TextField>(phoneNoteField('scratchpad'));
      expect(
        field.controller!.selection.textInside(field.controller!.text),
        url,
      );
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(launched, isEmpty);
      expect(repo.snapshot.note('scratchpad')!.content, source);
      final selected = field.controller!.selection;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: source.replaceRange(
            selected.start,
            selected.end,
            'новый адрес',
          ),
          selection: TextSelection.collapsed(
            offset: selected.start + 'новый адрес'.length,
          ),
        ),
      );
      await settle(tester);
      expect(
        repo.snapshot.note('scratchpad')!.content,
        'Ссылка (новый адрес). Ещё текст',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('code and unsupported schemes stay plain text on a phone', (
    tester,
  ) async {
    const source =
        '`https://example.com/inline`\n\n```text\nhttps://example.com/fenced\n```\n\njavascript:alert(1) file:///tmp/a ftp://example.com/file';
    await workspace(
      tester,
      mobile: true,
      prepare: (repo) => repo.saveNoteContent('scratchpad', source),
    );
    await command(tester, LogicalKeyboardKey.digit4);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.link == true,
      ),
      findsNothing,
    );
    expect(launched, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testInteraction('launch failure shows an error and keeps the note intact', (
    tester,
  ) async {
    const url = 'https://example.com';
    final repo = await workspace(
      tester,
      mobile: true,
      prepare: (repo) => repo.saveNoteContent('scratchpad', url),
    );
    await command(tester, LogicalKeyboardKey.digit4);
    launchSucceeds = false;
    await tapLink(tester, url);
    expect(find.textContaining('Не удалось открыть ссылку'), findsOneWidget);
    expect(repo.snapshot.note('scratchpad')!.content, url);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });
}
