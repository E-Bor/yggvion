import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'interaction_test.dart' show workspace, settle, testInteraction, command;

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

  testInteraction(
    'long project names fit the calendar toolbar after selection and filter the planner',
    (tester) async {
      const title = 'Разработка личного приложения и долгосрочные планы';
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.saveProject(title, 0xff82b8a0);
          final project = repo.snapshot.projects.single;
          await repo.createTask('Личная встреча', start: repo.now());
          await repo.createTask(
            'Встреча проекта',
            projectId: project.id,
            start: repo.now().add(const Duration(hours: 1)),
          );
          await repo.createTask('Идея проекта', projectId: project.id);
          await repo.createTask('Личная идея');
        },
      );
      final picker = find.byKey(const ValueKey('project-filter'));
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.text(title),
        ),
      );
      await settle(tester);

      expect(find.text('Встреча проекта'), findsOneWidget);
      expect(find.text('Личная встреча'), findsNothing);
      final label = find.descendant(of: picker, matching: find.text(title));
      final paragraph = tester.renderObject<RenderParagraph>(label);
      expect(paragraph.maxLines, 1);
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(paragraph.size.height, lessThan(20));
      final day = find.descendant(
        of: find.byKey(const ValueKey('calendar-view-picker')),
        matching: find.text('День'),
      );
      expect(tester.getCenter(label).dy, closeTo(tester.getCenter(day).dy, .5));
      expect(find.byTooltip(title), findsOneWidget);
      expect(tester.getSize(picker).width, lessThanOrEqualTo(150));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/project_filter_1440.png'),
      );

      // Reopening the menu and cancelling must preserve the filter.
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        repo.snapshot.projects.single.id,
      );

      await command(tester, LogicalKeyboardKey.digit2);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(find.text('Личная идея'), findsNothing);
      await tester.tap(picker.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Все проекты'));
      await settle(tester);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
