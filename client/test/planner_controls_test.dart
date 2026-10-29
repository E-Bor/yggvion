import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

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

  testInteraction('planner menu edits the task while card click selects it', (
    tester,
  ) async {
    late String id;
    final repo = await workspace(
      tester,
      prepare: (repo) async {
        id = (await repo.createTask('Разобрать планы')).id;
      },
    );
    await command(tester, LogicalKeyboardKey.digit2);
    await settle(tester);
    await tester.tap(find.text('Разобрать планы'));
    await settle(tester);
    expect(find.text('Выберите время: Разобрать планы'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('task-menu-$id')));
    await settle(tester);
    await tester.tap(find.text('Редактировать'));
    await settle(tester);
    expect(find.byType(TaskEditor), findsOneWidget);
    final title = find.widgetWithText(TextField, 'Разобрать планы');
    await tester.enterText(title, 'Обновлённый план');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    // The editor's primary action remains the same as in the calendar.
    if (find.byType(TaskEditor).evaluate().isNotEmpty) {
      await tester.tap(find.text('Сохранить').last);
      await settle(tester);
    }
    expect(repo.snapshot.task(id)!.title, 'Обновлённый план');
    expect(repo.snapshot.blocks, isEmpty);
  });

  testInteraction(
    'planner divider resizes both surfaces and persists locally',
    (tester) async {
      final repo = await workspace(tester);
      await command(tester, LogicalKeyboardKey.digit2);
      await settle(tester);
      final panel = find.byKey(const ValueKey('planner-task-panel'));
      final before = tester.getSize(panel).width;
      final outbox = await tester.runAsync(
        () => repo.db.customSelect('SELECT * FROM outbox').get(),
      );
      await tester.drag(
        find.byKey(const ValueKey('planner-calendar-divider')),
        const Offset(100, 0),
      );
      await settle(tester);
      expect(tester.getSize(panel).width, greaterThan(before + 60));
      final fraction = repo.plannerFraction;
      await command(tester, LogicalKeyboardKey.digit1);
      await command(tester, LogicalKeyboardKey.digit2);
      await settle(tester);
      expect(tester.getSize(panel).width, greaterThan(before + 60));
      await tester.runAsync(() => repo.initialize());
      expect(repo.plannerFraction, fraction);
      expect(
        (await tester.runAsync(
          () => repo.db.customSelect('SELECT * FROM outbox').get(),
        ))!.length,
        outbox!.length,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'phone offers two direct creation buttons in the requested order',
    (tester) async {
      final repo = await workspace(tester, mobile: true);
      final event = find.byKey(const ValueKey('create-event'));
      final note = find.byKey(const ValueKey('create-note'));
      expect(find.byKey(const ValueKey('create-menu')), findsNothing);
      expect(tester.getSize(event), const Size(64, 64));
      expect(tester.getSize(note), const Size(64, 64));
      expect(tester.getCenter(event).dy, lessThan(tester.getCenter(note).dy));
      await tester.tap(event);
      await settle(tester);
      expect(find.byType(TaskEditor), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(note);
      await settle(tester);
      expect(
        repo.snapshot.notes.where(
          (n) => n.id != 'scratchpad' && n.id != 'reference',
        ),
        hasLength(1),
      );
      expect(FocusManager.instance.primaryFocus?.context?.widget, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testInteraction(
      'phone creation buttons keep their position across tabs at $scale',
      (tester) async {
        await workspace(
          tester,
          mobile: true,
          prepare: (repo) => repo.setInterfaceScale(scale),
        );
        tester.view.padding = const FakeViewPadding(bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await settle(tester);
        final event = find.byKey(const ValueKey('create-event'));
        final note = find.byKey(const ValueKey('create-note'));
        final eventRect = tester.getRect(event);
        final noteRect = tester.getRect(note);
        final navRect = tester.getRect(find.byType(NavigationBar));
        for (final page in ['notes', 'planner', 'board', 'today']) {
          await tester.tap(find.byKey(ValueKey('mobile-nav-$page')));
          await settle(tester);
          expect(tester.getRect(event), eventRect, reason: page);
          expect(tester.getRect(note), noteRect, reason: page);
          expect(
            tester.getRect(find.byType(NavigationBar)),
            navRect,
            reason: page,
          );
          if (page == 'planner') {
            final mode = find.byKey(const ValueKey('planner-mode'));
            final control = tester.getRect(mode);
            expect(control.width, lessThan(navRect.width * .85));
            expect(control.center.dx, navRect.center.dx);
            expect(control.height, lessThanOrEqualTo(36 * scale));
            expect(
              navRect.top - control.bottom,
              inInclusiveRange(0, 4 * scale),
            );
            expect(control.overlaps(eventRect), isFalse);
            expect(control.overlaps(noteRect), isFalse);
            await tester.tap(find.byTooltip('Календарь'));
            await settle(tester);
            expect(tester.getRect(event), eventRect);
            expect(tester.getRect(note), noteRect);
            expect(tester.widget<SegmentedButton<bool>>(mode).selected, {
              false,
            });
            if (scale == 1) {
              await expectLater(
                find.byType(MaterialApp),
                matchesGoldenFile('goldens/planner_switcher_390.png'),
              );
            }
            await tester.tap(find.byTooltip('Задачи'));
            await settle(tester);
            expect(tester.widget<SegmentedButton<bool>>(mode).selected, {true});
          }
          expect(event.hitTestable(), findsOneWidget);
          expect(note.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
