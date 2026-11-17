import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/task_editor.dart';

import 'interaction_test.dart' show workspace, settle, testInteraction;

Finder get grid => find.byKey(const ValueKey('calendar-grid-gestures'));

Future<Offset> timePosition(WidgetTester tester, int minutes) async {
  final scroll = find.byKey(const ValueKey('calendar-scroll'));
  final controller = tester.widget<SingleChildScrollView>(scroll).controller!;
  final y = minutes * tester.getSize(grid).height / (24 * 60);
  controller.jumpTo(
    (y - tester.getSize(scroll).height / 2).clamp(
      0.0,
      controller.position.maxScrollExtent,
    ),
  );
  await tester.pumpAndSettle();
  return tester.getTopLeft(grid) + Offset(100, y);
}

Future<TestGesture> startSelection(
  WidgetTester tester,
  Offset point, {
  required bool mobile,
}) async {
  final gesture = await tester.startGesture(
    point,
    kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (mobile) await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
  });

  for (final mobile in [false, true]) {
    testInteraction(
      'projects wrap within the task editor and remain selectable (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            for (var i = 1; i <= 8; i++) {
              await repo.saveProject('Рабочий проект номер $i', 0xffb7a6e8);
            }
          },
        );
        unawaited(openTask(tester.element(find.byType(CalendarPane).first)));
        await settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('task-title')),
          'Задача с проектом',
        );
        final projects = find.byKey(const ValueKey('task-projects'));
        final chips = find.descendant(
          of: projects,
          matching: find.byType(ChoiceChip),
        );
        expect(chips, findsNWidgets(9));
        final bounds = tester.getRect(projects);
        final rows = <double>{};
        for (var i = 0; i < 9; i++) {
          final rect = tester.getRect(chips.at(i));
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
          rows.add(rect.top);
        }
        expect(rows.length, greaterThan(1));
        expect(
          find.ancestor(
            of: chips.first,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Scrollable &&
                  (w.axisDirection == AxisDirection.left ||
                      w.axisDirection == AxisDirection.right),
            ),
          ),
          findsNothing,
        );
        final lastProject = repo.snapshot.projects.last;
        final lastChip = find.byKey(ValueKey('task-project-${lastProject.id}'));
        await tester.ensureVisible(lastChip);
        await tester.tap(lastChip);
        await tester.pump();
        expect(tester.widget<ChoiceChip>(lastChip).selected, isTrue);
        await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
        await settle(tester);
        expect(find.byType(TaskEditor), findsNothing);
        expect(repo.snapshot.tasks.single.projectId, lastProject.id);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'new events snap to the nearest quarter hour and keep default duration (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(50, [15, 0], 'UTC');
            await repo.setView(CalendarView.day);
          },
        );
        for (final (minute, snapped) in [
          (7, 0),
          (8, 15),
          (23, 30),
          (38, 45),
          (53, 60),
        ]) {
          final point = await timePosition(tester, 12 * 60 + minute);
          final gesture = await startSelection(tester, point, mobile: mobile);
          await gesture.up();
          await settle(tester);
          final editor = tester.widget<TaskEditor>(find.byType(TaskEditor));
          final expected = DateTime.utc(2026, 10, 19, 12, snapped);
          expect(editor.start!.isAtSameMomentAs(expected), isTrue);
          expect(
            editor.end!.isAtSameMomentAs(
              expected.add(const Duration(minutes: 50)),
            ),
            isTrue,
          );
          Navigator.pop(tester.element(find.byType(TaskEditor)));
          await settle(tester);
        }
        expect(repo.snapshot.tasks, isEmpty);
      },
    );

    testInteraction(
      'drawing a new interval snaps both endpoints to quarter hours (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [15, 0], 'UTC');
            await repo.setView(CalendarView.day);
          },
        );
        final origin = await timePosition(tester, 12 * 60 + 8);
        final gesture = await startSelection(tester, origin, mobile: mobile);
        final pixelsPerMinute = tester.getSize(grid).height / (24 * 60);
        await gesture.moveBy(Offset(0, 30 * pixelsPerMinute));
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('calendar-time-label')))
              .data,
          '12:45',
        );
        await gesture.up();
        await settle(tester);
        final editor = tester.widget<TaskEditor>(find.byType(TaskEditor));
        expect(
          editor.start!.isAtSameMomentAs(DateTime.utc(2026, 10, 19, 12, 15)),
          isTrue,
        );
        expect(
          editor.end!.isAtSameMomentAs(DateTime.utc(2026, 10, 19, 12, 45)),
          isTrue,
        );
        await tester.enterText(
          find.byKey(const ValueKey('task-title')),
          'Новый интервал',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
        await settle(tester);
        expect(
          repo.snapshot.blocks.single.start.isAtSameMomentAs(editor.start!),
          isTrue,
        );
        expect(
          repo.snapshot.blocks.single.end.isAtSameMomentAs(editor.end!),
          isTrue,
        );
      },
    );

    testInteraction(
      'existing events still move and resize in five-minute steps (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [15, 0], 'UTC');
            await repo.setView(CalendarView.day);
            await repo.createTask(
              'Существующее событие',
              start: DateTime.utc(2026, 10, 19, 12, 10),
              end: DateTime.utc(2026, 10, 19, 13, 10),
            );
          },
        );
        final block = repo.snapshot.blocks.single;
        final pixelsPerMinute = tester.getSize(grid).height / (24 * 60);
        final origin = tester.getCenter(
          find.byKey(ValueKey('calendar-block-${block.id}')),
        );
        final gesture = await startSelection(tester, origin, mobile: mobile);
        // Cross the mouse gesture threshold, then return to a five-minute delta.
        await gesture.moveBy(Offset(0, 30 * pixelsPerMinute));
        await tester.pump();
        await gesture.moveTo(origin + Offset(0, 5 * pixelsPerMinute));
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('calendar-time-label')))
              .data,
          '12:15',
        );
        await gesture.up();
        await settle(tester);
        expect(
          repo.snapshot.blocks.single.start,
          DateTime.utc(2026, 10, 19, 12, 15),
        );
        expect(
          repo.snapshot.blocks.single.end,
          DateTime.utc(2026, 10, 19, 13, 15),
        );

        final handle = find.byKey(ValueKey('block-resize-end-${block.id}'));
        final handleOrigin = tester.getCenter(handle);
        final resize = await tester.startGesture(
          handleOrigin,
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await resize.moveBy(Offset(0, 30 * pixelsPerMinute));
        await tester.pump();
        await resize.moveTo(handleOrigin + Offset(0, 5 * pixelsPerMinute));
        await tester.pump();
        await resize.up();
        await settle(tester);
        expect(
          repo.snapshot.blocks.single.start,
          DateTime.utc(2026, 10, 19, 12, 15),
        );
        expect(
          repo.snapshot.blocks.single.end,
          DateTime.utc(2026, 10, 19, 13, 20),
        );
      },
    );
  }

  testInteraction('phone creation near midnight snaps to the next day', (
    tester,
  ) async {
    await workspace(
      tester,
      mobile: true,
      prepare: (repo) async {
        await repo.updateSettings(30, [15, 0], 'UTC');
        await repo.setView(CalendarView.day);
      },
    );
    final point = await timePosition(tester, 23 * 60 + 56);
    final gesture = await startSelection(tester, point, mobile: true);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('calendar-time-label')))
          .data,
      '24:00',
    );
    await gesture.up();
    await settle(tester);
    final editor = tester.widget<TaskEditor>(find.byType(TaskEditor));
    expect(editor.start!.isAtSameMomentAs(DateTime.utc(2026, 10, 20)), isTrue);
    expect(
      editor.end!.isAtSameMomentAs(DateTime.utc(2026, 10, 20, 0, 30)),
      isTrue,
    );
  });
}
