import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/workday.dart';
import 'package:yggvion/ui/calendar.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });
  for (final direction in [-1, 1]) {
    testInteraction(
      'holding a dragged event at edge pages a week ($direction)',
      (tester) async {
        final repo = await workspace(
          tester,
          prepare: (repo) async {
            await repo.setView(CalendarView.week);
            await repo.createTask(
              'Перенести через неделю',
              start: DateTime.utc(2026, 10, direction > 0 ? 25 : 19, 12),
              end: DateTime.utc(2026, 10, direction > 0 ? 25 : 19, 13),
            );
          },
        );
        final block = repo.snapshot.blocks.single;
        final card = find.byKey(ValueKey('calendar-block-${block.id}'));
        final origin = tester.getTopLeft(card) + const Offset(20, 25);
        final bounds = tester.getRect(find.byType(CalendarPane));
        final edge = Offset(
          // The left edge of the day grid is AFTER the time-label gutter.
          direction > 0 ? bounds.right - 8 : bounds.left + 48 + 8,
          origin.dy,
        );
        final gesture = await tester.startGesture(
          origin,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump();
        await gesture.moveTo(edge);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
          19,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(
          tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
          direction > 0 ? 26 : 12,
        );
        expect(repo.snapshot.blocks.single.start, block.start);
        await gesture.up();
        await settle(tester);
        expect(repo.snapshot.blocks.single.start.day, direction > 0 ? 1 : 12);
        expect(
          repo.snapshot.blocks.single.start.month,
          direction > 0 ? 11 : 10,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final collapsed in [false, true]) {
    for (final section in ['today', 'notes']) {
      testInteraction(
        'dragging over sidebar pages back without opening $section (collapsed: $collapsed)',
        (tester) async {
          final repo = await workspace(
            tester,
            prepare: (repo) async {
              await repo.setView(CalendarView.week);
              await repo.setSidebarCollapsed(collapsed);
              await repo.createTask(
                'Через боковое меню',
                start: repo.now(),
                end: repo.now().add(const Duration(hours: 1)),
              );
            },
          );
          final block = repo.snapshot.blocks.single;
          final origin =
              tester.getTopLeft(
                find.byKey(ValueKey('calendar-block-${block.id}')),
              ) +
              const Offset(20, 25);
          final target = tester.getCenter(find.byKey(ValueKey('nav-$section')));
          expect(
            target.dx,
            lessThan(tester.getRect(find.byType(CalendarPane)).left - 24),
          );
          final gesture = await tester.startGesture(
            origin,
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveBy(const Offset(0, 10));
          await tester.pump();
          await gesture.moveTo(target);
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            tester
                .widget<CalendarToolbar>(find.byType(CalendarToolbar))
                .date
                .day,
            19,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(
            tester
                .widget<CalendarToolbar>(find.byType(CalendarToolbar))
                .date
                .day,
            12,
          );
          expect(repo.snapshot.blocks.single.start, block.start);

          // Releasing over a navigation item must finish the calendar gesture,
          // not switch sections or discard the move.
          await gesture.up();
          await settle(tester);
          expect(find.byType(CalendarPane), findsOneWidget);
          final moved = repo.snapshot.blocks.single;
          expect(moved.start.day, 12);
          expect(moved.start.month, 10);
          expect(moved.end.difference(moved.start), const Duration(hours: 1));
          await tester.pump(const Duration(milliseconds: 700));
          expect(
            tester
                .widget<CalendarToolbar>(find.byType(CalendarToolbar))
                .date
                .day,
            12,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testInteraction('leaving sidebar or app window cancels delayed paging', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await repo.setView(CalendarView.week);
        await repo.createTask(
          'Не листать',
          start: repo.now(),
          end: repo.now().add(const Duration(hours: 1)),
        );
      },
    );
    final block = repo.snapshot.blocks.single;
    final origin =
        tester.getTopLeft(find.byKey(ValueKey('calendar-block-${block.id}'))) +
        const Offset(20, 25);
    final target = tester.getCenter(find.byKey(const ValueKey('nav-notes')));
    final bounds = tester.getRect(find.byType(CalendarPane));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();

    for (final exit in [
      Offset(bounds.center.dx, origin.dy),
      Offset(-10, target.dy),
    ]) {
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(exit);
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
        19,
      );
    }
    await gesture.cancel();
    await settle(tester);
    expect(repo.snapshot.blocks.single.start, block.start);
    expect(tester.takeException(), isNull);
  });

  testInteraction('moving away from an edge cancels delayed paging', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await repo.setView(CalendarView.week);
        await repo.createTask(
          'Остаться',
          start: repo.now(),
          end: repo.now().add(const Duration(hours: 1)),
        );
      },
    );
    final block = repo.snapshot.blocks.single;
    final origin =
        tester.getTopLeft(find.byKey(ValueKey('calendar-block-${block.id}'))) +
        const Offset(20, 25);
    final bounds = tester.getRect(find.byType(CalendarPane));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(bounds.right - 8, origin.dy));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(origin);
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
      19,
    );
    await gesture.cancel();
    await settle(tester);
    expect(repo.snapshot.blocks.single.start, block.start);
  });

  for (final direction in [-1, 1]) {
    testInteraction(
      'phone edge first reveals hidden days and then changes week ($direction)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: true,
          prepare: (repo) async {
            await repo.setView(CalendarView.week);
            await repo.createTask(
              'Мобильный перенос',
              start: DateTime.utc(2026, 10, direction > 0 ? 25 : 19, 12),
              end: DateTime.utc(2026, 10, direction > 0 ? 25 : 19, 13),
            );
          },
        );
        final horizontal = tester
            .widget<SingleChildScrollView>(
              find.byWidgetPredicate(
                (w) =>
                    w is SingleChildScrollView &&
                    w.scrollDirection == Axis.horizontal,
              ),
            )
            .controller!;
        horizontal.jumpTo(
          direction > 0 ? horizontal.position.maxScrollExtent - 50 : 50,
        );
        await settle(tester);
        final block = repo.snapshot.blocks.single;
        final origin =
            tester.getTopLeft(
              find.byKey(ValueKey('calendar-block-${block.id}')),
            ) +
            const Offset(15, 25);
        final bounds = tester.getRect(find.byType(CalendarPane));
        final gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(
          Offset(
            direction > 0 ? bounds.right - 10 : bounds.left + 10,
            origin.dy,
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          horizontal.offset,
          direction > 0 ? horizontal.position.maxScrollExtent : 0,
        );
        expect(
          tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
          19,
        );
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();
        expect(
          tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
          direction > 0 ? 26 : 12,
        );
        await gesture.cancel();
        await settle(tester);
        expect(repo.snapshot.blocks.single.start, block.start);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction('workday end crosses Sunday into next week', (tester) async {
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await repo.setView(CalendarView.week);
        await repo.updateWorkdaySettings(540, 1410, [1, 2, 3, 4, 5, 6, 7]);
      },
    );
    final scrollFinder = find.byKey(const ValueKey('calendar-scroll'));
    final scroll = tester
        .widget<SingleChildScrollView>(scrollFinder)
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await settle(tester);
    final handle = find.byKey(const ValueKey('workday-end-2026-10-25'));
    final origin = tester.getCenter(handle);
    final bounds = tester.getRect(find.byType(CalendarPane));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(bounds.right - 8, origin.dy - 20));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(
      tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date.day,
      26,
    );
    scroll.jumpTo(0);
    await tester.pump();
    final grid = tester.getRect(scrollFinder);
    await gesture.moveTo(Offset(bounds.left + 95, grid.top + 72 - 15));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    expect(
      WorkdaySchedule(
        repo.snapshot,
      ).forDate(DateTime.utc(2026, 10, 25))!.end.toUtc(),
      DateTime.utc(2026, 10, 26, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testInteraction('planner keeps newest first when an older task is edited', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        await repo.createTask('Старая задача');
        await repo.createTask('Новая задача');
      },
    );
    await command(tester, LogicalKeyboardKey.digit2);
    expect(
      tester.getTopLeft(find.text('Новая задача')).dy,
      lessThan(tester.getTopLeft(find.text('Старая задача')).dy),
    );
    final old = repo.snapshot.tasks.first;
    await tester.runAsync(
      () => repo.commit([
        old.entity.change({'title': 'Изменённая старая'}),
      ]),
    );
    await settle(tester);
    expect(
      tester.getTopLeft(find.text('Новая задача')).dy,
      lessThan(tester.getTopLeft(find.text('Изменённая старая')).dy),
    );
  });
}
