import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/birthdays.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'package:yggvion/ui/app.dart';
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
    'phone swipes navigate day, week and month without creating tasks',
    (tester) async {
      final repo = await workspace(tester, mobile: true);
      DateTime date() =>
          tester.widget<CalendarToolbar>(find.byType(CalendarToolbar)).date;
      final scroll = find.byKey(const ValueKey('calendar-scroll'));
      await tester.drag(scroll, const Offset(-230, 0));
      await settle(tester);
      expect(date().day, 20);
      expect(find.text('20 октября 2026'), findsOneWidget);
      await tester.drag(scroll, const Offset(230, 0));
      await settle(tester);
      expect(date().day, 19);
      final before = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!
          .offset;
      await tester.drag(scroll, const Offset(0, -120));
      await settle(tester);
      expect(date().day, 19);
      expect(
        tester.widget<SingleChildScrollView>(scroll).controller!.offset,
        greaterThan(before),
      );
      await tester.runAsync(() => repo.setView(CalendarView.week));
      await settle(tester);
      await tester.dragFrom(
        tester.getTopLeft(scroll) + const Offset(100, 220),
        const Offset(230, 0),
      );
      await settle(tester);
      expect(date().day, 12);
      await settle(tester);
      final horizontal = tester
          .widget<SingleChildScrollView>(
            find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          )
          .controller!;
      expect(horizontal.offset, horizontal.position.maxScrollExtent);
      await tester.dragFrom(const Offset(260, 400), const Offset(-220, 0));
      await settle(tester);
      await settle(tester);
      expect(date().day, 19);
      expect(horizontal.offset, horizontal.position.minScrollExtent);
      await tester.runAsync(() => repo.setView(CalendarView.threeDays));
      await settle(tester);
      await tester.dragFrom(const Offset(260, 400), const Offset(-220, 0));
      await settle(tester);
      await settle(tester);
      expect(date().day, 22);
      await tester.runAsync(() => repo.setView(CalendarView.month));
      await settle(tester);
      await tester.drag(find.byType(GridView), const Offset(-230, 0));
      await settle(tester);
      expect(date().month, 11);
      expect(repo.snapshot.tasks, isEmpty);
      expect(find.byType(TaskEditor), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    testInteraction(
      'short task buttons remain clickable during touch editing (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.createTask(
              'Пять минут',
              start: repo.now(),
              end: repo.now().add(const Duration(minutes: 5)),
            );
          },
        );
        final block = repo.snapshot.blocks.single;
        final card = find.byKey(ValueKey('calendar-block-${block.id}'));
        if (mobile) {
          final hold = await tester.startGesture(
            tester.getTopLeft(card) + const Offset(15, 11),
          );
          await tester.pump(const Duration(milliseconds: 600));
          await hold.up();
          await settle(tester);
          expect(
            find.byKey(ValueKey('block-resize-end-${block.id}')),
            findsOneWidget,
          );
        }
        await tester.tap(find.byKey(ValueKey('calendar-timer-${block.id}')));
        await settle(tester);
        expect(repo.snapshot.sessions.where((s) => s.running), hasLength(1));
        await tester.tap(find.byKey(ValueKey('calendar-complete-${block.id}')));
        await settle(tester);
        expect(repo.snapshot.task(block.taskId)!.done, isTrue);
        expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
        expect(repo.snapshot.blocks.single.start, block.start);
        expect(repo.snapshot.blocks.single.end, block.end);
        expect(find.byType(TaskEditor), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'time calendar previews plans, keeps multiple ranges and commits only on OK (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            final task = await repo.createTask(
              'Фокус',
              start: DateTime.utc(2026, 10, 19, 9),
              end: DateTime.utc(2026, 10, 19, 10),
            );
            await repo.schedule(
              task,
              DateTime.utc(2026, 10, 19, 10, 30),
              DateTime.utc(2026, 10, 19, 11),
            );
            await repo.createTask(
              'Другая задача',
              start: DateTime.utc(2026, 10, 19, 9),
              end: DateTime.utc(2026, 10, 19, 11),
            );
          },
        );
        final task = repo.snapshot.tasks.firstWhere((t) => t.title == 'Фокус');
        editSession(tester.element(find.byType(CalendarPane)), task);
        await settle(tester);
        final editor = find.byType(SessionEditor);
        expect(
          find.descendant(of: editor, matching: find.text('Другая задача')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: editor,
            matching: find.text('09:00 — 10:00 · план'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('use-planned-time')));
        await settle(tester);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('time-entry-total')))
              .data,
          '1 ч 30 мин',
        );
        expect(repo.snapshot.sessions, isEmpty);
        await tester.tap(find.byKey(const ValueKey('save-time-entries')));
        await settle(tester);
        expect(repo.snapshot.sessions, hasLength(2));
        expect(
          repo.snapshot.spent(task.id, repo.now()),
          const Duration(minutes: 90),
        );

        editSession(tester.element(find.byType(CalendarPane)), task);
        await settle(tester);
        final grid = find.descendant(
          of: editor,
          matching: find.byKey(const ValueKey('calendar-grid-gestures')),
        );
        for (final minute in [9 * 60, 10 * 60]) {
          final origin =
              tester.getTopLeft(grid) + Offset(100, minute * 72 / 60);
          final gesture = await tester.startGesture(
            origin,
            kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
          );
          if (mobile) await tester.pump(const Duration(milliseconds: 600));
          await gesture.moveBy(const Offset(0, 24));
          await tester.pump();
          expect(
            find.descendant(
              of: editor,
              matching: find.byKey(const ValueKey('calendar-time-label')),
            ),
            findsOneWidget,
          );
          await gesture.up();
          await settle(tester);
        }
        expect(
          find.descendant(of: editor, matching: find.byType(CalendarBlock)),
          findsNWidgets(2),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('time-entry-total')))
              .data,
          '40 мин',
        );
        expect(repo.snapshot.sessions, hasLength(2));
        await tester.tap(find.text('Отмена').last);
        await settle(tester);
        expect(repo.snapshot.sessions, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction(
      'birthday settings create annual top-row tasks and completion stays out of planner (mobile: $mobile)',
      (tester) async {
        final repo = await workspace(tester, mobile: mobile);
        await command(tester, LogicalKeyboardKey.digit5);
        expect(find.byKey(const ValueKey('add-birthday')), findsNothing);
        final open = find.byKey(const ValueKey('open-birthdays'));
        await tester.ensureVisible(open);
        await settle(tester);
        await tester.tap(open);
        await settle(tester);
        expect(find.byType(BirthdayPage), findsOneWidget);
        final add = find.byKey(const ValueKey('add-birthday'));
        await tester.ensureVisible(add);
        await settle(tester);
        await tester.tap(add);
        await settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('birthday-name')),
          'Саша',
        );
        await tester.enterText(
          find.byKey(const ValueKey('birthday-date')),
          '19.10.1990',
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/birthday_editor_${mobile ? 390 : 1440}.png',
          ),
        );
        await tester.tap(find.byKey(const ValueKey('save-birthday')));
        await settle(tester);
        expect(repo.snapshot.birthdays, hasLength(1));
        expect(repo.snapshot.tasks, hasLength(3));
        expect(find.text('Сегодня · 36 лет'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('back-from-birthdays')));
        await settle(tester);
        expect(find.byType(BirthdayPage), findsNothing);
        await command(tester, LogicalKeyboardKey.digit1);
        expect(
          find.byKey(const ValueKey('birthday-calendar-row')),
          findsOneWidget,
        );
        expect(find.byType(CalendarBlock), findsNothing);
        final current = repo.snapshot.tasks.firstWhere(
          (t) => t.entity.data['birthday_year'] == 2026,
        );
        expect(current.title, 'Саша — день рождения · 36 лет');
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile(
            'goldens/birthday_calendar_${mobile ? 390 : 1440}.png',
          ),
        );
        final rowY = tester
            .getTopLeft(find.byKey(const ValueKey('birthday-calendar-row')))
            .dy;
        await tester.drag(
          find.byKey(const ValueKey('calendar-scroll')),
          const Offset(0, -150),
        );
        await settle(tester);
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('birthday-calendar-row')))
              .dy,
          rowY,
        );
        await tester.tap(find.byType(BirthdayChip));
        await settle(tester);
        expect(find.byType(TaskEditor), findsNothing);
        await tester.tap(find.text('Закрыть').last);
        await settle(tester);
        await tester.tap(
          find.byKey(ValueKey('birthday-complete-${current.id}')),
        );
        await settle(tester);
        expect(repo.snapshot.task(current.id)!.done, isTrue);
        expect(repo.snapshot.tasks.where((t) => !t.done), hasLength(2));
        expect(find.byType(BirthdayChip), findsNothing);
        expect(
          find.byKey(const ValueKey('birthday-calendar-row')),
          findsNothing,
        );
        await tester.runAsync(() => repo.setView(CalendarView.month));
        await settle(tester);
        expect(find.byType(BirthdayChip), findsNothing);
        await tester.runAsync(
          () => repo.status(repo.snapshot.task(current.id)!, TaskStatus.todo),
        );
        await settle(tester);
        expect(find.byType(BirthdayChip), findsOneWidget);
        await command(tester, LogicalKeyboardKey.digit3);
        expect(find.text(current.title), findsNothing);
        await command(tester, LogicalKeyboardKey.digit2);
        expect(find.text(current.title), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction(
    'available time preset clips ongoing events and is disabled for future events',
    (tester) async {
      final repo = await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          final task = await repo.createTask(
            'Сейчас',
            start: repo.now().subtract(const Duration(minutes: 35)),
            end: repo.now().add(const Duration(minutes: 25)),
          );
          await repo.schedule(
            task,
            repo.now().add(const Duration(days: 1)),
            repo.now().add(const Duration(days: 1, hours: 1)),
          );
          await repo.createTask(
            'Завтра',
            start: repo.now().add(const Duration(days: 1)),
          );
        },
      );
      final task = repo.snapshot.tasks.firstWhere((t) => t.title == 'Сейчас');
      editSession(tester.element(find.byType(CalendarPane)), task);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('use-planned-time')));
      await settle(tester);
      expect(find.text('35 мин'), findsWidgets);
      expect(repo.snapshot.sessions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('save-time-entries')));
      await settle(tester);
      expect(find.byType(SessionEditor), findsNothing);
      expect(repo.snapshot.sessions.single.end, repo.now());
      expect(
        repo.snapshot.spent(task.id, repo.now()),
        const Duration(minutes: 35),
      );
      final future = repo.snapshot.tasks.firstWhere((t) => t.title == 'Завтра');
      editSession(tester.element(find.byType(CalendarPane)), future);
      await settle(tester);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('use-planned-time')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save-time-entries')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Отмена').last);
      await settle(tester);
      expect(repo.snapshot.sessions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'many birthdays stay in their own scrollable settings screen',
    (tester) async {
      await workspace(
        tester,
        mobile: true,
        prepare: (repo) async {
          for (var day = 1; day <= 30; day++) {
            await BirthdayService(
              repo,
            ).save('Человек $day', DateTime(1990, 11, day));
          }
        },
      );
      await command(tester, LogicalKeyboardKey.digit5);
      expect(find.text('Человек 1'), findsNothing);
      final open = find.byKey(const ValueKey('open-birthdays'));
      await tester.ensureVisible(open);
      await settle(tester);
      await tester.tap(open);
      await settle(tester);
      expect(find.text('Человек 1'), findsOneWidget);
      expect(find.text('Человек 30'), findsNothing);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/birthday_settings_390.png'),
      );
      await tester.scrollUntilVisible(
        find.text('Человек 30'),
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('birthday-people')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Человек 30'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-birthday')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('back-from-birthdays')));
      await settle(tester);
      expect(find.byType(BirthdayPage), findsNothing);
      expect(find.text('Человек 30'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'drag guide displays the exact snapped time and disappears after cancel',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask(
            'Перенести',
            start: repo.now(),
            end: repo.now().add(const Duration(hours: 1)),
          );
        },
      );
      final block = repo.snapshot.blocks.single;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('calendar-block-${block.id}'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 18));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calendar-time-label')))
            .data,
        '12:15',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/calendar_drag_1440.png'),
      );
      expect(repo.snapshot.blocks.single.start, block.start);
      await gesture.cancel();
      await settle(tester);
      expect(find.byKey(const ValueKey('calendar-time-guide')), findsNothing);
      expect(repo.snapshot.blocks.single.start, block.start);
    },
  );
}
