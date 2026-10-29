import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/task_card.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart'
    show workspace, settle, settleSearch, command, testInteraction;

Future<void> searchFor(WidgetTester tester, String query) async {
  await command(tester, LogicalKeyboardKey.keyF);
  await tester.enterText(
    find.descendant(
      of: find.byType(SearchDialog),
      matching: find.byType(TextField),
    ),
    query,
  );
  await tester.pump(const Duration(milliseconds: 250));
  await settleSearch(tester);
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting();
  });

  testInteraction('phone plans successive tasks and keeps calendar position', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      mobile: true,
      prepare: (repo) async {
        await repo.updateSettings(30, [], 'UTC');
        await repo.createTask('Первый план');
        await repo.createTask('Следующий план');
      },
    );
    await command(tester, LogicalKeyboardKey.digit2);
    expect(find.text('Без расписания'), findsNothing);
    final switcher = find.byKey(const ValueKey('planner-mode'));
    expect(tester.getTopLeft(switcher).dy, greaterThan(650));
    expect(tester.getSize(switcher).height, lessThanOrEqualTo(48));
    await tester.tap(find.widgetWithText(TaskCard, 'Первый план'));
    await settle(tester);
    final paneState = tester.state(find.byType(CalendarPane));
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('calendar-scroll')),
        )
        .controller!;
    scroll.jumpTo(12 * 72);
    await settle(tester);
    final grid = find.byKey(const ValueKey('calendar-grid-gestures'));
    final gesture = await tester.startGesture(
      tester.getTopLeft(grid) + const Offset(130, 13 * 72),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 36));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    expect(repo.snapshot.blocks, hasLength(1));
    expect(find.widgetWithText(TaskCard, 'Следующий план'), findsOneWidget);
    expect(find.widgetWithText(TaskCard, 'Первый план'), findsNothing);
    expect(tester.widget<SegmentedButton<bool>>(switcher).selected, {true});
    await tester.tap(find.widgetWithText(TaskCard, 'Следующий план'));
    await settle(tester);
    expect(tester.state(find.byType(CalendarPane)), same(paneState));
    expect(scroll.offset, closeTo(12 * 72, 1));
    // Switching back cancels placement, so the same task can be picked again.
    await tester.tap(find.text('Задачи'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TaskCard, 'Следующий план'));
    await settle(tester);
    expect(find.text('Выберите время: Следующий план'), findsOneWidget);
    final last = await tester.startGesture(
      tester.getTopLeft(grid) + const Offset(130, 14 * 72),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await last.moveBy(const Offset(0, 36));
    await tester.pump();
    await last.up();
    await settle(tester);
    expect(repo.snapshot.blocks, hasLength(2));
    expect(tester.widget<SegmentedButton<bool>>(switcher).selected, {false});
    expect(find.byType(CalendarPane), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'narrow overlapping phone events retain actions in the menu',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          await repo.updateSettings(30, [], 'UTC');
          for (var i = 0; i < 4; i++) {
            await repo.createTask(
              'Совпадение $i',
              start: repo.now(),
              end: repo.now().add(const Duration(minutes: 5)),
            );
          }
        },
      );
      final block = repo.snapshot.blocks.first;
      await command(tester, LogicalKeyboardKey.digit2);
      await tester.tap(find.text('Календарь'));
      await settle(tester);
      expect(find.byKey(ValueKey('calendar-timer-${block.id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('calendar-menu-${block.id}')));
      await settle(tester);
      await tester.tap(find.text('Начать работу'));
      await settle(tester);
      expect(
        repo.snapshot.sessions.where((s) => s.running).single.taskId,
        block.taskId,
      );
      await tester.tap(find.byKey(ValueKey('calendar-menu-${block.id}')));
      await settle(tester);
      await tester.tap(find.text('Завершить'));
      await settle(tester);
      expect(repo.snapshot.task(block.taskId)!.done, isTrue);
      expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
      expect(repo.snapshot.blocks, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  for (final view in [CalendarView.day, CalendarView.month]) {
    testInteraction('phone event menu unschedules from $view', (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          await repo.updateSettings(30, [], 'UTC');
          await repo.setView(view, planner: true);
          await repo.createTask(
            'Короткое событие',
            start: repo.now(),
            end: repo.now().add(const Duration(minutes: 5)),
          );
        },
      );
      final block = repo.snapshot.blocks.single;
      await command(tester, LogicalKeyboardKey.digit2);
      await tester.tap(find.text('Календарь'));
      await settle(tester);
      if (view == CalendarView.day) {
        final card = find.byKey(ValueKey('calendar-block-${block.id}'));
        final hold = await tester.startGesture(
          tester.getTopLeft(card) + const Offset(15, 11),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await hold.up();
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('calendar-timer-${block.id}')));
        await settle(tester);
        expect(repo.snapshot.sessions.where((s) => s.running), hasLength(1));
        await tester.tap(find.byKey(ValueKey('calendar-complete-${block.id}')));
        await settle(tester);
        expect(repo.snapshot.task(block.taskId)!.done, isTrue);
        // Return it to work before testing the planner list.
        await tester.tap(find.byKey(ValueKey('calendar-complete-${block.id}')));
        await settle(tester);
      }
      final menu = find.byKey(ValueKey('calendar-menu-${block.id}'));
      await tester.ensureVisible(menu);
      await settle(tester);
      await tester.tap(menu);
      await settle(tester);
      expect(find.byType(TaskEditor), findsNothing);
      await tester.tap(find.text('Убрать из плана'));
      await settle(tester);
      expect(repo.snapshot.taskBlocks(block.taskId), isEmpty);
      await tester.tap(find.text('Задачи'));
      await settle(tester);
      expect(find.widgetWithText(TaskCard, 'Короткое событие'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mobile in [false, true]) {
    testInteraction(
      'search jump reveals the correct time and weekday ($mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [], 'Asia/Tokyo');
            await repo.setView(CalendarView.week);
            await repo.setView(CalendarView.threeDays, planner: true);
            await repo.createTask(
              'Субботняя встреча',
              start: DateTime.utc(2026, 10, 23, 23, 45),
              end: DateTime.utc(2026, 10, 24, 0, 15),
            );
            await repo.createTask('Без даты');
            final note = await repo.createNote();
            await repo.saveNote(note.id, 'Встреча в заметке', 'Текст');
          },
        );
        final block = repo.snapshot.blocks.single;
        await searchFor(tester, 'Субботняя');
        await tester.tap(find.byKey(ValueKey('search-result-${block.taskId}')));
        await settle(tester);
        expect(find.byType(TaskEditor), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        for (var attempt = 0; attempt < 2; attempt++) {
          await searchFor(tester, 'Субботняя');
          await tester.tap(find.byKey(ValueKey('search-go-${block.taskId}')));
          await settle(tester);
          expect(find.byType(TaskEditor), findsNothing);
          expect(find.byType(SearchDialog), findsNothing);
          final pane = tester.widget<CalendarPane>(find.byType(CalendarPane));
          expect(pane.initialDate!.day, 24);
          expect(pane.initialDate!.hour, 8);
          final event = find.byKey(ValueKey('calendar-block-${block.id}'));
          expect(event.hitTestable(), findsOneWidget);
          expect(
            tester
                .widget<CalendarBlock>(find.byType(CalendarBlock))
                .highlighted,
            isTrue,
          );
          final scroll = tester
              .widget<SingleChildScrollView>(
                find.byKey(const ValueKey('calendar-scroll')),
              )
              .controller!;
          expect(scroll.offset, closeTo(8.75 * 72 - 32, 1));
          scroll.jumpTo(0);
          await settle(tester);
        }
        expect(repo.calendarView, CalendarView.week);
        expect(repo.plannerView, CalendarView.threeDays);
        await searchFor(tester, 'Без даты');
        expect(find.text('Перейти'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await searchFor(tester, 'заметке');
        expect(find.text('Перейти'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'project tags create and edit project assignment ($mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            for (var i = 0; i < 5; i++) {
              await repo.saveProject(
                'Проект с длинным названием $i',
                0xffb7a6e8,
              );
            }
          },
        );
        await command(tester, LogicalKeyboardKey.keyN);
        await tester.enterText(
          find.byKey(const ValueKey('task-title')),
          'Выбор проекта',
        );
        final project = repo.snapshot.projects.last;
        final tag = find.byKey(ValueKey('task-project-${project.id}'));
        await tester.ensureVisible(tag);
        await settle(tester);
        await tester.tap(tag);
        await settle(tester);
        expect(tester.widget<ChoiceChip>(tag).selected, isTrue);
        await tester.tap(find.text('Сохранить').last);
        await settle(tester);
        expect(repo.snapshot.tasks.single.projectId, project.id);
        await searchFor(tester, 'Выбор проекта');
        await tester.tap(
          find.byKey(
            ValueKey('search-result-${repo.snapshot.tasks.single.id}'),
          ),
        );
        await settle(tester);
        expect(tester.widget<ChoiceChip>(tag).selected, isTrue);
        expect(tag.hitTestable(), findsOneWidget);
        final none = find.byKey(const ValueKey('task-project-'));
        await tester.ensureVisible(none);
        await settle(tester);
        await tester.tap(none);
        await tester.tap(find.text('Сохранить').last);
        await settle(tester);
        expect(repo.snapshot.tasks.single.projectId, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'search from month reveals nearest block and then last past block',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.updateSettings(30, [], 'UTC');
          await repo.setView(CalendarView.month);
          final task = await repo.createTask('Несколько блоков');
          for (final day in [17, 18, 20, 22]) {
            await repo.schedule(
              task,
              DateTime.utc(2026, 10, day, 14),
              DateTime.utc(2026, 10, day, 15),
            );
          }
        },
      );
      final task = repo.snapshot.tasks.single;
      await searchFor(tester, task.title);
      await tester.tap(find.byKey(ValueKey('search-go-${task.id}')));
      await settle(tester);
      expect(repo.calendarView, CalendarView.day);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).initialDate!.day,
        20,
      );
      await tester.runAsync(() async {
        for (final block
            in repo.snapshot
                .taskBlocks(task.id)
                .where((b) => b.start.isAfter(repo.now()))) {
          await repo.unschedule(block);
        }
      });
      await searchFor(tester, task.title);
      await tester.tap(find.byKey(ValueKey('search-go-${task.id}')));
      await settle(tester);
      expect(
        tester.widget<CalendarPane>(find.byType(CalendarPane)).initialDate!.day,
        18,
      );
      expect(
        find
            .byKey(ValueKey('calendar-block-${repo.snapshot.blocks.last.id}'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('phone planner dock and search actions fit at 200 percent', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      mobile: true,
      prepare: (repo) async {
        await repo.setInterfaceScale(2);
        await repo.updateSettings(30, [], 'UTC');
        await repo.createTask('Новая встреча');
        await repo.createTask(
          'Встреча завтра',
          start: DateTime.utc(2026, 10, 20, 14),
        );
      },
    );
    await command(tester, LogicalKeyboardKey.digit2);
    await tester.tap(find.widgetWithText(TaskCard, 'Новая встреча'));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('planner-mode')).hitTestable(),
      findsOneWidget,
    );
    await searchFor(tester, 'завтра');
    final task = repo.snapshot.tasks.firstWhere(
      (t) => t.title == 'Встреча завтра',
    );
    await tester.tap(find.byKey(ValueKey('search-go-${task.id}')));
    await settle(tester);
    expect(
      tester.widget<CalendarPane>(find.byType(CalendarPane)).initialDate!.day,
      20,
    );
    expect(tester.takeException(), isNull);
  });
}
