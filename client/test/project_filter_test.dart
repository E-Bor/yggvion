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
    'sidebar projects filter today and planner in expanded and compact modes',
    (tester) async {
      const title = 'Разработка личного приложения и долгосрочные планы';
      const color = Color(0xff82b8a0);
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.saveProject(title, color.toARGB32());
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
      final projectId = repo.snapshot.projects.single.id;
      final project = find.byKey(ValueKey('sidebar-project-$projectId'));
      expect(find.byTooltip('Фильтр проектов'), findsNothing);
      expect(find.text('Все проекты'), findsNothing);
      await tester.tap(project);
      await settle(tester);
      expect(find.text('Встреча проекта'), findsOneWidget);
      expect(find.text('Личная встреча'), findsNothing);
      final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
      expect(paragraph.maxLines, 1);
      expect(paragraph.didExceedMaxLines, isTrue);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/project_filter_1440.png'),
      );

      await tester.drag(
        find.byKey(const ValueKey('sidebar-resize-handle')),
        const Offset(-150, 0),
      );
      await settle(tester);
      expect(find.byTooltip(title), findsOneWidget);
      expect(find.text(title), findsNothing);
      final button = tester.widget<IconButton>(project);
      expect((button.icon as Icon).color, color);
      expect(tester.getSize(project).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(project).height, greaterThanOrEqualTo(44));
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        projectId,
      );
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/project_filter_collapsed.png'),
      );

      await command(tester, LogicalKeyboardKey.digit2);
      expect(find.byTooltip('Фильтр проектов'), findsNothing);
      expect(find.byKey(const ValueKey('project-filter')), findsNothing);
      expect(find.text('Все проекты'), findsNothing);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(find.text('Личная идея'), findsNothing);
      // The entire indicator button is clickable; tapping it again resets.
      await tester.tapAt(tester.getTopLeft(project) + const Offset(6, 6));
      await settle(tester);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        '',
      );
      await tester.tap(project);
      await settle(tester);
      await tester.drag(
        find.byKey(const ValueKey('sidebar-resize-handle')),
        const Offset(150, 0),
      );
      await settle(tester);
      expect(tester.widget<ListTile>(project).selected, isTrue);
      expect(find.text('Личная идея'), findsNothing);
      await tester.tap(project);
      await settle(tester);
      expect(find.text('Личная идея'), findsOneWidget);
      // A remotely deleted project must not leave an invisible active filter.
      await tester.tap(project);
      await settle(tester);
      await tester.runAsync(
        () => repo.deleteProject(repo.snapshot.projects.single),
      );
      await settle(tester);
      expect(project, findsNothing);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('phone planner keeps a single project filter in the header', (
    tester,
  ) async {
    await workspace(
      tester,
      mobile: true,
      prepare: (repo) async {
        await repo.saveProject('Работа', 0xff82b8a0);
        await repo.createTask(
          'Рабочая идея',
          projectId: repo.snapshot.projects.single.id,
        );
        await repo.createTask('Личная идея');
      },
    );
    await tester.tap(find.byKey(const ValueKey('mobile-nav-planner')));
    await settle(tester);
    final filter = find.byTooltip('Фильтр проектов');
    expect(filter, findsOneWidget);
    expect(find.text('Все проекты'), findsNothing);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Работа'));
    await settle(tester);
    expect(find.text('Рабочая идея'), findsOneWidget);
    expect(find.text('Личная идея'), findsNothing);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Все проекты'));
    await settle(tester);
    expect(find.text('Личная идея'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
