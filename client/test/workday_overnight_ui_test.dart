import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/workday.dart';
import 'package:yggvion/ui/statistics.dart';
import 'interaction_test.dart' show workspace, settle, command, testInteraction;

Future<void> chooseTime(WidgetTester tester, int hour, int minute) async {
  final picker = find.byType(TimePickerDialog);
  var fields = find.descendant(of: picker, matching: find.byType(TextField));
  if (fields.evaluate().isEmpty) {
    await tester.tap(
      find.descendant(
        of: picker,
        matching: find.byIcon(Icons.keyboard_outlined),
      ),
    );
    await settle(tester);
    fields = find.descendant(of: picker, matching: find.byType(TextField));
  }
  await tester.enterText(fields.at(0), '$hour');
  await tester.enterText(fields.at(1), '$minute');
  final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
  await tester.tap(find.text(ok));
  await settle(tester);
}

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

  for (final mobile in [false, true]) {
    testInteraction(
      'overnight icon can be adjusted in day view mobile=$mobile',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [0], 'UTC');
            await repo.updateWorkdaySettings(540, 1500, [1, 2, 3, 4, 5]);
          },
        );
        await tester.tap(find.byTooltip('Вперёд'));
        await settle(tester);
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('calendar-scroll')),
            )
            .controller!;
        scroll.jumpTo(0);
        await settle(tester);
        final end = find.byKey(const ValueKey('workday-end-2026-10-19'));
        expect(find.text('20 октября 2026'), findsWidgets);
        expect(tester.getSize(end), const Size(24, 24));
        expect(
          find.descendant(of: end, matching: find.byType(Text)),
          findsNothing,
        );
        final tooltip = tester.widget<Tooltip>(
          find.ancestor(of: end, matching: find.byType(Tooltip)).first,
        );
        expect(tooltip.message, contains('Конец 19 окт. · 01:00 +1'));
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile(
            'goldens/workday_overnight_${mobile ? 390 : 1440}.png',
          ),
        );
        await tester.tap(end);
        await settle(tester);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(WorkdaySchedule(repo.snapshot).records, isEmpty);
        final origin = tester.getCenter(end);
        final gesture = await tester.createGesture(
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        await gesture.down(origin);
        if (mobile) await tester.pump(const Duration(milliseconds: 650));
        await gesture.moveTo(origin + const Offset(0, 72));
        await tester.pump();
        await gesture.up();
        await settle(tester);
        expect(
          WorkdaySchedule(
            repo.snapshot,
          ).forDate(DateTime.utc(2026, 10, 19))!.end.toUtc(),
          DateTime.utc(2026, 10, 20, 2),
        );
        expect(repo.snapshot.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testInteraction('drag end into the next date mobile=$mobile', (
      tester,
    ) async {
      final repo = await workspace(
        tester,
        mobile: mobile,
        prepare: (repo) async {
          await repo.updateSettings(30, [0], 'UTC');
          await repo.updateWorkdaySettings(540, 1410, [1, 2, 3, 4, 5]);
          await repo.setView(CalendarView.threeDays);
        },
      );
      final calendar = find.byKey(const ValueKey('calendar-scroll'));
      final scroll = tester.widget<SingleChildScrollView>(calendar).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await settle(tester);
      final end = find.byKey(const ValueKey('workday-end-2026-10-19'));
      final origin = tester.getCenter(end);
      final next = tester.getCenter(
        find.byKey(const ValueKey('workday-end-2026-10-20')),
      );
      final gesture = await tester.createGesture(
        kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
      );
      await gesture.down(origin);
      if (mobile) {
        await tester.pump(const Duration(milliseconds: 650));
      } else {
        await gesture.moveTo(origin - const Offset(0, 20));
        await tester.pump();
      }
      scroll.jumpTo(0);
      await tester.pump();
      // End handles are 15 px above their line. Keep that grab offset while
      // moving from 23:30 to 01:00 in the next column.
      await gesture.moveTo(
        Offset(next.dx, tester.getTopLeft(calendar).dy + 72 - 15),
      );
      await tester.pump();
      expect(find.text('01:00'), findsWidgets);
      await gesture.up();
      await settle(tester);
      expect(
        WorkdaySchedule(
          repo.snapshot,
        ).forDate(DateTime.utc(2026, 10, 19))!.end.toUtc(),
        DateTime.utc(2026, 10, 20, 1),
      );
      expect(tester.getCenter(end).dx, greaterThan(origin.dx));
      expect(repo.snapshot.tasks, isEmpty);
      expect(repo.snapshot.blocks, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testInteraction(
      'overnight averages show the next-day label mobile=$mobile',
      (tester) async {
        await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await repo.updateSettings(30, [0], 'UTC');
            await repo.updateWorkdaySettings(540, 1440, [1, 2, 3, 4, 5]);
            for (final day in [15, 16]) {
              final date = DateTime.utc(2026, 10, day);
              await repo.setWorkdayBoundary(
                date,
                start: true,
                value: DateTime.utc(2026, 10, day, 9),
              );
              await repo.setWorkdayBoundary(
                date,
                start: false,
                value: day == 15
                    ? DateTime.utc(2026, 10, day, 23)
                    : DateTime.utc(2026, 10, day + 1, 1),
              );
            }
          },
        );
        await command(tester, LogicalKeyboardKey.digit5);
        await tester.tap(find.byKey(const ValueKey('open-statistics')));
        await tester.pump();
        await settle(tester);
        await tester.ensureVisible(find.text('Начало и конец дня'));
        await settle(tester);
        expect(find.text('00:00 +1'), findsWidgets);
        expect(
          find.byKey(const ValueKey('statistics-info-boundaries')),
          findsOneWidget,
        );
        await expectLater(
          find.byType(StatisticsPage),
          matchesGoldenFile(
            'goldens/workday_overnight_chart_${mobile ? 390 : 1440}.png',
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testInteraction('default overnight time saves from settings', (tester) async {
    final repo = await workspace(tester);
    await command(tester, LogicalKeyboardKey.digit5);
    final end = find.byKey(const ValueKey('workday-end-setting'));
    await tester.ensureVisible(end);
    await settle(tester);
    await tester.tap(end);
    await settle(tester);
    await chooseTime(tester, 1, 0);
    expect(repo.snapshot.settings.workdayEnd, 1500);
    expect(find.text('Конец · 01:00 · следующий день'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
