import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/month_planning.dart';
import 'package:yggvion/ui/task_card.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

Finder inside(Finder finder) =>
    find.descendant(of: find.byType(MonthPlanningEditor), matching: finder);
Finder get grid => inside(find.byKey(const ValueKey('calendar-grid-gestures')));
Finder get confirm => find.byKey(const ValueKey('confirm-month-plan'));

Future<Repository> setupPlanner(
  WidgetTester tester, {
  required bool mobile,
  int minutes = 30,
  String timezone = 'UTC',
}) async {
  final repo = await workspace(
    tester,
    mobile: mobile,
    prepare: (repo) async {
      await repo.updateSettings(minutes, [15, 0], timezone);
      await repo.setView(CalendarView.month, planner: true);
      await repo.createTask('Подготовить презентацию');
      await repo.saveProject('Другой проект', 0xffb7a6e8);
      final zone = tz.getLocation(timezone);
      await repo.createTask(
        'Встреча с командой',
        projectId: repo.snapshot.projects.single.id,
        start: tz.TZDateTime(zone, 2026, 10, 20, 10),
        end: tz.TZDateTime(zone, 2026, 10, 20, 11),
      );
    },
  );
  await command(tester, LogicalKeyboardKey.digit2);
  await tester.tap(find.widgetWithText(TaskCard, 'Подготовить презентацию'));
  await settle(tester);
  return repo;
}

Future<void> openDay(WidgetTester tester, {String day = '2026-10-20'}) async {
  final cell = find.byKey(ValueKey('calendar-month-day-$day'));
  await tester.ensureVisible(cell);
  // The date remains a target even if the cell contains an existing event.
  await tester.tapAt(tester.getTopLeft(cell) + const Offset(12, 12));
  await settle(tester);
  expect(find.byType(MonthPlanningEditor), findsOneWidget);
}

Future<void> tapTime(
  WidgetTester tester,
  int minutes, {
  required bool mobile,
}) async {
  await tester.tapAt(
    tester.getTopLeft(grid) + Offset(100, minutes * 72 / 60),
    kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  await settle(tester);
}

Future<void> extendDraft(
  WidgetTester tester,
  double pixels, {
  required bool mobile,
}) async {
  final block = tester
      .widget<CalendarBlock>(inside(find.byType(CalendarBlock)))
      .block;
  final handle = inside(find.byKey(ValueKey('block-resize-end-${block.id}')));
  final gesture = await tester.startGesture(
    tester.getCenter(handle),
    kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 36));
  await tester.pump();
  await gesture.moveBy(Offset(0, pixels - 36));
  await tester.pump();
  await gesture.up();
  await settle(tester);
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await initializeDateFormatting('ru');
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final mobile in [false, true]) {
    testInteraction(
      'month planning requires confirmation and uses chosen time and duration (mobile: $mobile)',
      (tester) async {
        final repo = await setupPlanner(tester, mobile: mobile, minutes: 50);
        final task = repo.snapshot.tasks.firstWhere(
          (t) => t.title == 'Подготовить презентацию',
        );
        final occupied = repo.snapshot.blocks.single;
        await openDay(tester);
        expect(repo.snapshot.taskBlocks(task.id), isEmpty);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('month-plan-duration')))
              .data,
          '50 мин',
        );
        expect(inside(find.byType(TextField)), findsNothing);
        expect(inside(find.byType(ChoiceChip)), findsNothing);
        expect(
          find.byKey(ValueKey('planning-busy-${occupied.id}')),
          findsOneWidget,
        );
        await tapTime(tester, 10 * 60 + 15, mobile: mobile);
        await extendDraft(tester, 12, mobile: mobile);
        expect(
          inside(find.byKey(const ValueKey('month-plan-time'))),
          findsOneWidget,
        );
        expect(find.text('10:15 — 11:15'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('month-plan-hint')))
              .data,
          contains('Встреча с командой'),
        );
        expect(repo.snapshot.taskBlocks(task.id), isEmpty);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/month_planning_${mobile ? 390 : 1440}.png',
          ),
        );
        await extendDraft(tester, 6, mobile: mobile);
        expect(find.text('10:15 — 11:20'), findsOneWidget);
        await tester.tap(confirm);
        await settle(tester);
        final block = repo.snapshot.taskBlocks(task.id).single;
        expect(block.start, DateTime.utc(2026, 10, 20, 10, 15));
        expect(block.end, DateTime.utc(2026, 10, 20, 11, 20));
        expect(block.reminders, [15, 0]);
        expect(repo.snapshot.estimate(task.id), const Duration(minutes: 65));
        expect(repo.snapshot.task(task.id)!.status, TaskStatus.todo);
        expect(
          repo.snapshot.blocks
              .firstWhere((b) => b.id == occupied.id)
              .entity
              .encoded,
          occupied.entity.encoded,
        );
        expect(repo.plannerView, CalendarView.month);
        expect(repo.calendarView, CalendarView.day);
        expect(find.byType(MonthPlanningEditor), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'month draft can be replaced resized and cancelled without saving (mobile: $mobile)',
      (tester) async {
        final repo = await setupPlanner(tester, mobile: mobile);
        final task = repo.snapshot.tasks.firstWhere(
          (t) => t.title == 'Подготовить презентацию',
        );
        await openDay(tester);
        await tapTime(tester, 9 * 60, mobile: mobile);
        await tapTime(tester, 9 * 60 + 45, mobile: mobile);
        expect(inside(find.byType(CalendarBlock)), findsOneWidget);
        final draft = tester
            .widget<CalendarBlock>(inside(find.byType(CalendarBlock)))
            .block;
        final handle = inside(
          find.byKey(ValueKey('block-resize-end-${draft.id}')),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(handle),
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, 36));
        await tester.pump();
        await gesture.up();
        await settle(tester);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('month-plan-duration')))
              .data,
          '1 ч',
        );
        expect(find.text('09:45 — 10:45'), findsOneWidget);
        await tester.drag(
          inside(find.byType(CalendarBlock)),
          const Offset(400, 18),
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await settle(tester);
        final moved = tester
            .widget<CalendarBlock>(inside(find.byType(CalendarBlock)))
            .block;
        expect(moved.start, DateTime.utc(2026, 10, 20, 10));
        expect(moved.end, DateTime.utc(2026, 10, 20, 11));
        expect(find.text('10:00 — 11:00'), findsOneWidget);
        expect(repo.snapshot.taskBlocks(task.id), isEmpty);
        await tester.tap(inside(find.text('Отмена')));
        await settle(tester);
        expect(repo.snapshot.taskBlocks(task.id), isEmpty);
        expect(find.text('Выберите время: ${task.title}'), findsOneWidget);
        await openDay(tester);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.tap(find.byTooltip('Закрыть выбор времени'));
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'month selection supports hold and drag without typing (mobile: $mobile)',
      (tester) async {
        final repo = await setupPlanner(tester, mobile: mobile);
        final task = repo.snapshot.tasks.firstWhere(
          (t) => t.title == 'Подготовить презентацию',
        );
        await openDay(tester);
        final origin = tester.getTopLeft(grid) + const Offset(160, 9.25 * 72);
        final gesture = await tester.startGesture(
          origin,
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (mobile) await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveBy(const Offset(0, 54));
        await tester.pump();
        await gesture.up();
        await settle(tester);
        expect(find.text('09:15 — 10:00'), findsOneWidget);
        await tester.tap(confirm);
        await settle(tester);
        expect(
          repo.snapshot.taskBlocks(task.id).single.duration,
          const Duration(minutes: 45),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'phone scroll does not select time and overnight plan uses settings timezone',
    (tester) async {
      final repo = await setupPlanner(
        tester,
        mobile: true,
        minutes: 120,
        timezone: 'Europe/Moscow',
      );
      final task = repo.snapshot.tasks.firstWhere(
        (t) => t.title == 'Подготовить презентацию',
      );
      await openDay(tester);
      final scroller = inside(find.byKey(const ValueKey('calendar-scroll')));
      final controller = tester
          .widget<SingleChildScrollView>(scroller)
          .controller!;
      final before = controller.offset;
      await tester.dragFrom(
        tester.getTopLeft(scroller) + const Offset(100, 150),
        const Offset(0, -120),
      );
      await settle(tester);
      expect(controller.offset, greaterThan(before));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle(tester);
      await tapTime(tester, 23 * 60 + 30, mobile: true);
      expect(find.text('23:30 — 01:30'), findsOneWidget);
      expect(find.text('Окончание 21 октября'), findsOneWidget);
      await tester.tap(confirm);
      await settle(tester);
      final block = repo.snapshot.taskBlocks(task.id).single;
      expect(block.start, DateTime.utc(2026, 10, 20, 20, 30));
      expect(block.end, DateTime.utc(2026, 10, 20, 22, 30));
      expect(block.timezone, 'Europe/Moscow');
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('month duration remains elapsed time across DST', (
    tester,
  ) async {
    final repo = await setupPlanner(
      tester,
      mobile: false,
      minutes: 120,
      timezone: 'Europe/Berlin',
    );
    final task = repo.snapshot.tasks.firstWhere(
      (t) => t.title == 'Подготовить презентацию',
    );
    await openDay(tester, day: '2026-10-25');
    final controller = tester
        .widget<SingleChildScrollView>(
          inside(find.byKey(const ValueKey('calendar-scroll'))),
        )
        .controller!;
    controller.jumpTo(0);
    await settle(tester);
    await tapTime(tester, 90, mobile: false);
    await tester.tap(confirm);
    await settle(tester);
    final block = repo.snapshot.taskBlocks(task.id).single;
    expect(block.start, DateTime.utc(2026, 10, 24, 23, 30));
    expect(block.end, DateTime.utc(2026, 10, 25, 1, 30));
    expect(block.duration, const Duration(hours: 2));
    expect(tester.takeException(), isNull);
  });

  testInteraction('month without a selected task still opens task creation', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (repo) => repo.setView(CalendarView.month),
    );
    final cell = find.byKey(const ValueKey('calendar-month-day-2026-10-20'));
    await tester.tapAt(tester.getTopLeft(cell) + const Offset(12, 12));
    await settle(tester);
    expect(find.byType(TaskEditor), findsOneWidget);
    expect(find.byType(MonthPlanningEditor), findsNothing);
    expect(repo.snapshot.tasks, isEmpty);
    await tester.tap(find.byTooltip('Закрыть'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
