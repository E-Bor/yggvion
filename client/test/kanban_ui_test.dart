import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/models.dart';

import 'interaction_test.dart' show workspace, settle, command, testInteraction;

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  for (final mobile in [false, true]) {
    testInteraction(
      'Done period filters history without deleting tasks ($mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.commit([
              for (final item in [('new', 0), ('older', 10), ('oldest', 40)])
                Task.create(item.$1, item.$1).change({
                  'status': 'done',
                  'completed_at': wireTime(
                    repo.now().subtract(Duration(days: item.$2)),
                  ),
                }),
              Task.create('undated', 'Без даты').change({'status': 'done'}),
            ]);
          },
        );
        await command(tester, LogicalKeyboardKey.digit3);
        final done = find.byKey(const ValueKey('board-done'));
        await tester.ensureVisible(done);
        await settle(tester);
        final count = find.byKey(const ValueKey('board-count-done'));
        final period = find.byKey(const ValueKey('board-done-period'));
        expect(tester.widget<Text>(count).data, '1');
        expect(find.byKey(const ValueKey('board-task-new')), findsOneWidget);
        expect(find.byKey(const ValueKey('board-task-older')), findsNothing);
        expect(find.byKey(const ValueKey('board-task-undated')), findsNothing);

        await tester.tap(period);
        await settle(tester);
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is CheckedPopupMenuItem<int> && w.value == 30,
          ),
        );
        await settle(tester);
        expect(tester.widget<Text>(count).data, '2');
        expect(find.byKey(const ValueKey('board-task-older')), findsOneWidget);

        await tester.tap(period);
        await settle(tester);
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is CheckedPopupMenuItem<int> && w.value == 0,
          ),
        );
        await settle(tester);
        expect(tester.widget<Text>(count).data, '4');
        final undated = find.byKey(const ValueKey('board-task-undated'));
        await tester.ensureVisible(undated);
        await settle(tester);
        expect(undated, findsOneWidget);
        expect(repo.snapshot.tasks, hasLength(4));

        final older = find.byKey(const ValueKey('board-task-older'));
        await tester.ensureVisible(older);
        await tester.tap(
          find.descendant(of: older, matching: find.byType(Checkbox)),
        );
        await settle(tester);
        expect(repo.snapshot.task('older')!.status, TaskStatus.todo);
        expect(repo.snapshot.task('older')!.completedAt, isNull);
        expect(tester.widget<Text>(count).data, '3');

        await command(tester, LogicalKeyboardKey.digit1);
        await command(tester, LogicalKeyboardKey.digit3);
        await tester.ensureVisible(done);
        await settle(tester);
        expect(tester.widget<Text>(count).data, '1');
        expect(
          find.descendant(of: period, matching: find.text('7 дней')),
          findsOneWidget,
        );
        expect(repo.snapshot.task('oldest')!.done, isTrue);
        expect(repo.snapshot.task('undated')!.done, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'Done offers additional tasks in batches and resets when the period changes',
    (tester) async {
      await workspace(
        tester,
        prepare: (repo) async {
          await repo.commit([
            for (var i = 0; i < 55; i++)
              Task.create('done-$i', 'Завершено $i').change({
                'status': 'done',
                'completed_at': wireTime(
                  repo.now().subtract(Duration(minutes: i)),
                ),
              }),
          ]);
        },
      );
      await command(tester, LogicalKeyboardKey.digit3);
      final done = find.byKey(const ValueKey('board-done'));
      final scroll = find.descendant(
        of: done,
        matching: find.byType(Scrollable),
      );
      final more = find.byKey(const ValueKey('board-done-more'));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('board-count-done')))
            .data,
        '55',
      );
      await scrollDownTo(tester, scroll, more);
      await settle(tester);
      expect(find.text('Показано 50 из 55'), findsOneWidget);
      expect(find.text('Показать ещё 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('board-task-done-54')), findsNothing);
      await tester.tap(more);
      await settle(tester);
      final last = find.byKey(const ValueKey('board-task-done-54'));
      await scrollDownTo(tester, scroll, last);
      expect(last, findsOneWidget);
      expect(more, findsNothing);

      await tester.tap(find.byKey(const ValueKey('board-done-period')));
      await settle(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<int> && w.value == 30,
        ),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey('board-task-done-0')).hitTestable(),
        findsOneWidget,
      );
      await scrollDownTo(tester, scroll, more);
      expect(find.text('Показать ещё 5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> scrollDownTo(
  WidgetTester tester,
  Finder scrollable,
  Finder target,
) async {
  // Desktop cards start dragging immediately; scroll with a wheel/trackpad.
  for (var i = 0; i < 30 && target.hitTestable().evaluate().isEmpty; i++) {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(scrollable),
        scrollDelta: const Offset(0, 500),
      ),
    );
    await tester.pump();
  }
  expect(target.hitTestable(), findsOneWidget);
}
