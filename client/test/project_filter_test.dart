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
        isNull,
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
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'unassigned filter follows Today, Planner and Kanban in both sidebar sizes',
    (tester) async {
      const accent = Color(0xffd99aaa);
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.commit([
            repo.snapshot.settings.entity.change({
              'task_color': accent.toARGB32(),
            }),
          ]);
          await repo.saveProject('Работа', 0xff82b8a0);
          final project = repo.snapshot.projects.single;
          final personal = await repo.createTask(
            'Личная встреча',
            start: repo.now(),
          );
          final work = await repo.createTask(
            'Встреча проекта',
            projectId: project.id,
            start: repo.now().add(const Duration(hours: 1)),
          );
          await repo.createTask('Личная идея');
          await repo.createTask('Идея проекта', projectId: project.id);
          await repo.saveSession(
            personal.id,
            repo.now().subtract(const Duration(hours: 1)),
            repo.now().subtract(const Duration(minutes: 30)),
          );
          await repo.saveSession(
            work.id,
            repo.now().subtract(const Duration(minutes: 30)),
            repo.now(),
          );
        },
      );
      final withoutProject = find.byKey(
        const ValueKey('sidebar-without-project'),
      );
      final project = find.byKey(
        ValueKey('sidebar-project-${repo.snapshot.projects.single.id}'),
      );
      final personalTime = find.byTooltip('Личная встреча · 30 мин');
      final projectTime = find.byTooltip('Встреча проекта · 30 мин');
      expect(
        (tester.widget<ListTile>(withoutProject).leading as Icon).color,
        accent,
      );
      expect(personalTime, findsOneWidget);
      expect(projectTime, findsOneWidget);
      await tester.tap(withoutProject);
      await settle(tester);
      expect(tester.widget<ListTile>(withoutProject).selected, isTrue);
      expect(tester.widget<ListTile>(project).selected, isFalse);
      expect(find.text('Личная встреча'), findsOneWidget);
      expect(find.text('Встреча проекта'), findsNothing);
      expect(personalTime, findsOneWidget);
      expect(projectTime, findsNothing);

      await command(tester, LogicalKeyboardKey.digit2);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(find.text('Идея проекта'), findsNothing);
      expect(find.text('Личная встреча'), findsOneWidget);
      expect(find.text('Встреча проекта'), findsNothing);
      await tester.tap(project);
      await settle(tester);
      expect(tester.widget<ListTile>(withoutProject).selected, isFalse);
      expect(find.text('Личная идея'), findsNothing);
      expect(find.text('Идея проекта'), findsOneWidget);
      // Changing the filter also cancels placement of a now-hidden task.
      await tester.tap(find.text('Идея проекта'));
      await settle(tester);
      expect(find.text('Выберите время: Идея проекта'), findsOneWidget);
      await tester.tap(withoutProject);
      await settle(tester);
      expect(find.text('Выберите время: Идея проекта'), findsNothing);
      expect(find.text('Идея проекта'), findsNothing);
      expect(find.text('Личная идея'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('sidebar-resize-handle')),
        const Offset(-150, 0),
      );
      await settle(tester);
      final button = tester.widget<IconButton>(withoutProject);
      expect(button.tooltip, 'Без проекта');
      expect((button.icon as Icon).color, accent);
      expect(
        button.style!.backgroundColor!.resolve({}),
        accent.withValues(alpha: .14),
      );
      expect(tester.getSize(withoutProject).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(withoutProject).height, greaterThanOrEqualTo(44));
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/without_project_collapsed.png'),
      );

      await command(tester, LogicalKeyboardKey.digit3);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(find.text('Идея проекта'), findsNothing);
      expect(find.text('Личная встреча'), findsOneWidget);
      expect(find.text('Встреча проекта'), findsNothing);
      // Repository notifications must preserve the empty-ID filter.
      await tester.runAsync(() => repo.createTask('Новая личная идея'));
      await settle(tester);
      expect(find.text('Новая личная идея'), findsOneWidget);
      expect(find.text('Идея проекта'), findsNothing);
      await tester.tap(withoutProject);
      await settle(tester);
      expect(find.text('Идея проекта'), findsOneWidget);
      expect(find.text('Встреча проекта'), findsOneWidget);
      expect(find.text('Личная идея'), findsOneWidget);
      await command(tester, LogicalKeyboardKey.digit1);
      expect(find.text('Встреча проекта'), findsOneWidget);
      expect(find.text('Личная встреча'), findsOneWidget);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'unassigned filter works without projects and clears planner search on reset',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask('Личная идея');
          await repo.createTask('Другая идея');
        },
      );
      final withoutProject = find.byKey(
        const ValueKey('sidebar-without-project'),
      );
      expect(repo.snapshot.projects, isEmpty);
      expect(withoutProject, findsOneWidget);
      await tester.tap(withoutProject);
      await settle(tester);
      await command(tester, LogicalKeyboardKey.digit2);
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Найти задачу',
      );
      await tester.enterText(search, 'Личная');
      await settle(tester);
      expect(find.text('Другая идея'), findsNothing);
      await tester.runAsync(() async {
        await repo.saveProject('Временный проект', 0xff82b8a0);
        await repo.deleteProject(repo.snapshot.projects.single);
      });
      await settle(tester);
      expect(tester.widget<ListTile>(withoutProject).selected, isTrue);
      await tester.tap(withoutProject);
      await settle(tester);
      expect(tester.widget<ListTile>(withoutProject).selected, isFalse);
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.text('Личная идея'), findsOneWidget);
      expect(find.text('Другая идея'), findsOneWidget);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).projectId,
        isNull,
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
    await tester.tap(find.text('Без проекта'));
    await settle(tester);
    expect(find.text('Рабочая идея'), findsNothing);
    expect(find.text('Личная идея'), findsOneWidget);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Все проекты'));
    await settle(tester);
    expect(find.text('Личная идея'), findsOneWidget);
    expect(find.text('Рабочая идея'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
