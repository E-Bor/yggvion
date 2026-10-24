import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/workday.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final mobile in [false, true]) {
    testInteraction(
      'workday icons only drag; taps and cancellation leave data intact mobile=$mobile',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) => repo.updateSettings(30, [0], 'UTC'),
        );
        final date = DateTime.utc(2026, 10, 19);
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('calendar-scroll')),
            )
            .controller!;
        scroll.jumpTo(8 * 72);
        await settle(tester);
        final start = find.byKey(const ValueKey('workday-start-2026-10-19'));
        expect(tester.getSize(start), const Size(24, 24));
        expect(
          find.descendant(of: start, matching: find.byType(Text)),
          findsNothing,
        );
        final tooltip = tester.widget<Tooltip>(
          find.ancestor(of: start, matching: find.byType(Tooltip)).first,
        );
        expect(tooltip.message, contains('Начало дня · 09:00'));
        if (!mobile) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(start));
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.text(tooltip.message!), findsOneWidget);
          await mouse.removePointer();
          await settle(tester);
        }
        await tester.tap(start);
        await settle(tester);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(find.byType(TaskEditor), findsNothing);
        expect(WorkdaySchedule(repo.snapshot).records, isEmpty);
        final origin = tester.getCenter(start);
        var gesture = await tester.createGesture(
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await gesture.down(origin);
        if (mobile) await tester.pump(const Duration(milliseconds: 650));
        await gesture.moveTo(origin + const Offset(0, 72));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('calendar-time-guide')),
          findsOneWidget,
        );
        await gesture.up();
        await settle(tester);
        expect(
          WorkdaySchedule(repo.snapshot).forDate(date)!.start.toUtc().hour,
          10,
        );
        expect(repo.snapshot.tasks, isEmpty);
        expect(find.byType(TaskEditor), findsNothing);
        final moved = tester.getCenter(start);
        gesture = await tester.createGesture(
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await gesture.down(moved);
        if (mobile) await tester.pump(const Duration(milliseconds: 650));
        await gesture.moveTo(moved + const Offset(0, 72));
        await tester.pump();
        await gesture.cancel();
        await settle(tester);
        expect(
          WorkdaySchedule(repo.snapshot).forDate(date)!.start.toUtc().hour,
          10,
        );
        expect(find.byKey(const ValueKey('calendar-time-guide')), findsNothing);

        await tester.tap(start);
        await settle(tester);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(find.byType(TaskEditor), findsNothing);
        expect(
          WorkdaySchedule(repo.snapshot).forDate(date)!.start.toUtc().hour,
          10,
        );

        scroll.jumpTo(math.min(16 * 72, scroll.position.maxScrollExtent));
        await settle(tester);
        final end = find.byKey(const ValueKey('workday-end-2026-10-19'));
        final endOrigin = tester.getCenter(end);
        gesture = await tester.createGesture(
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await gesture.down(endOrigin);
        if (mobile) await tester.pump(const Duration(milliseconds: 650));
        await gesture.moveTo(endOrigin - const Offset(0, 72));
        await tester.pump();
        await gesture.up();
        await settle(tester);
        expect(
          WorkdaySchedule(repo.snapshot).forDate(date)!.end.toUtc().hour,
          17,
        );
        expect(repo.snapshot.blocks, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'workday handle never blocks event completion or timer mobile=$mobile',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [0], 'UTC');
            await repo.createTask(
              'Короткая задача',
              start: DateTime.utc(2026, 10, 19, 9),
              end: DateTime.utc(2026, 10, 19, 9, 5),
            );
          },
        );
        final task = repo.snapshot.tasks.single;
        final block = repo.snapshot.taskBlocks(task.id).single;
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('calendar-scroll')),
            )
            .controller!;
        scroll.jumpTo(8 * 72);
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('calendar-timer-${block.id}')));
        await settle(tester);
        expect(
          repo.snapshot.sessions.where((s) => s.running).single.taskId,
          task.id,
        );
        await tester.tap(find.byKey(ValueKey('calendar-complete-${block.id}')));
        await settle(tester);
        expect(repo.snapshot.task(task.id)!.done, isTrue);
        expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'workday settings autosave; statistics info only appears on hover mobile=$mobile',
      (tester) async {
        final repo = await workspace(tester, mobile: mobile);
        await command(tester, LogicalKeyboardKey.digit5);
        final saturday = find.byKey(const ValueKey('workday-weekday-6'));
        await tester.ensureVisible(saturday);
        await settle(tester);
        await tester.tap(saturday);
        await settle(tester);
        expect(repo.snapshot.settings.workdays, contains(6));
        final schedule = WorkdaySchedule(repo.snapshot);
        expect(schedule.forDate(DateTime.utc(2026, 10, 17)), isNull);
        expect(schedule.forDate(DateTime.utc(2026, 10, 24)), isNotNull);
        expect(
          find.textContaining('действуют со вчерашнего дня'),
          findsOneWidget,
        );
        final setting = find.byKey(const ValueKey('workday-start-setting'));
        await tester.ensureVisible(setting);
        await settle(tester);
        await tester.tap(setting);
        await settle(tester);
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('open-statistics')),
        );
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('open-statistics')));
        await tester.pump();
        await settle(tester);
        expect(find.byKey(const ValueKey('statistics-info')), findsNothing);
        for (final entry in {
          'plan-fact': 'План и факт',
          'estimate': 'Ошибка эстимейта',
          'projects': 'Куда уходит время',
          'workday': 'Работа в течение дня',
          'boundaries': 'Начало и конец дня',
          'usage': 'Использование приложения',
          'activity': 'Календарь активности',
        }.entries) {
          final info = find.byKey(ValueKey('statistics-info-${entry.key}'));
          await tester.ensureVisible(info);
          await settle(tester);
          final tooltip = tester.widget<Tooltip>(
            find.ancestor(of: info, matching: find.byType(Tooltip)).first,
          );
          expect(tooltip.message, isNotEmpty);
          expect(tooltip.triggerMode, TooltipTriggerMode.manual);
          if (!mobile) {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: Offset.zero);
            await mouse.moveTo(tester.getCenter(info));
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.text(tooltip.message!), findsOneWidget);
            await mouse.removePointer();
            await settle(tester);
          }
          await tester.tap(info);
          await settle(tester);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text(tooltip.message!), findsNothing);
          if (mobile) {
            await tester.longPress(info);
            await settle(tester);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.text(tooltip.message!), findsNothing);
          }
        }
        await tester.ensureVisible(find.text('За всё время'));
        await settle(tester);
        await tester.tap(find.text('За всё время'));
        await settle(tester);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Предыдущий период',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(find.text('Как считаются показатели'), findsNothing);
        expect(find.textContaining('Не удалось рассчитать'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
