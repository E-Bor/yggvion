import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/statistics.dart';
import 'package:yggvion/ui/task_editor.dart';
import 'interaction_test.dart'
    show workspace, settle, settleSearch, command, testInteraction;

Future<void> statisticsFixture(Repository repo) async {
  await repo.saveProject('Разработка', 0xff9cb9ff);
  final project = repo.snapshot.projects.single;
  for (var offset = 10; offset < 365; offset += 3) {
    final start = DateTime.utc(
      2026,
      10,
      19,
      9,
    ).subtract(Duration(days: offset));
    final activity = await repo.db.beginActivity(start);
    await repo.db.endActivity(
      activity,
      start.add(Duration(minutes: [2, 8, 25, 75][(offset ~/ 3) % 4])),
    );
  }
  for (var i = 0; i < 7; i++) {
    final start = DateTime.utc(2026, 10, 13 + i, 9);
    final task = await repo.createTask(
      [
        'Проектирование интерфейса',
        'Работа над проектом',
        'Разобрать заметки',
      ][i % 3],
      projectId: i.isEven ? project.id : '',
      start: start,
      end: start.add(Duration(minutes: 90 + (i % 3) * 30)),
    );
    await repo.saveSession(
      task.id,
      start,
      start.add(Duration(minutes: 50 + i * 14)),
    );
    if (i.isEven) {
      await repo.status(repo.snapshot.task(task.id)!, TaskStatus.done);
    }
    final activity = await repo.db.beginActivity(start);
    await repo.db.endActivity(
      activity,
      start.add(Duration(minutes: 10 + i * 4)),
    );
  }
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

  testInteraction(
    'search tolerance autosaves and fuzzy results open the matching task',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask('Стоматолог');
        },
      );
      await command(tester, LogicalKeyboardKey.digit5);
      await tester.ensureVisible(find.byKey(const ValueKey('search-typos')));
      await tester.tap(find.text('2 ошибки'));
      await settle(tester);
      expect(repo.snapshot.settings.searchTypos, 2);
      await command(tester, LogicalKeyboardKey.keyF);
      final input = find.descendant(
        of: find.byType(SearchDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'С');
      await tester.pump(const Duration(milliseconds: 100));
      await settleSearch(tester);
      expect(find.text('Стоматолог'), findsOneWidget);
      expect(find.text('Одна буква — точный поиск'), findsOneWidget);
      for (final query in ['стам', 'стаматал', 'стаматалог']) {
        await tester.enterText(input, query);
        await tester.pump(const Duration(milliseconds: 200));
        await settleSearch(tester);
        expect(find.text('Стоматолог'), findsOneWidget, reason: query);
      }
      expect(find.text('Допуск: 2 опечатки в слове'), findsOneWidget);
      expect(find.text('Стоматолог'), findsOneWidget);
      await tester.tap(find.text('Стоматолог'));
      await settle(tester);
      expect(find.byType(TaskEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    testInteraction(
      'statistics chart, period navigation and empty state fit mobile=$mobile',
      (tester) async {
        await workspace(tester, mobile: mobile, prepare: statisticsFixture);
        await command(tester, LogicalKeyboardKey.digit5);
        await tester.tap(find.byKey(const ValueKey('open-statistics')));
        await tester.pump();
        await settle(tester);
        expect(find.byType(StatisticsPage), findsOneWidget);
        expect(
          find.textContaining('Не удалось рассчитать'),
          findsNothing,
          reason: tester
              .widgetList<Text>(find.textContaining('Не удалось рассчитать'))
              .map((w) => w.data)
              .join('\n'),
        );
        expect(find.text('План и факт'), findsOneWidget);
        expect(find.byKey(const ValueKey('work-line-chart')), findsOneWidget);
        expect(find.byKey(const ValueKey('usage-line-chart')), findsOneWidget);
        await expectLater(
          find.byType(StatisticsPage),
          matchesGoldenFile('goldens/statistics_${mobile ? 390 : 1440}.png'),
        );
        await tester.ensureVisible(find.text('Ошибка эстимейта'));
        await settle(tester);
        for (final entry in {
          'estimate-mean-error': '38,2%',
          'estimate-outside-tolerance': '4 из 4',
          'estimate-underestimated': '48,9%',
          'estimate-overestimated': '34,7%',
        }.entries) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey(entry.key)),
              matching: find.text(entry.value),
            ),
            findsOneWidget,
            reason: tester
                .widgetList<Text>(
                  find.descendant(
                    of: find.byKey(ValueKey(entry.key)),
                    matching: find.byType(Text),
                  ),
                )
                .map((text) => text.data)
                .join(' · '),
          );
        }
        await expectLater(
          find.byType(StatisticsPage),
          matchesGoldenFile(
            'goldens/estimate_accuracy_${mobile ? 390 : 1440}.png',
          ),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('estimate-task-details')),
        );
        await tester.tap(find.text('По задачам'));
        await settle(tester);
        expect(find.text('Недооценка 48,9%'), findsOneWidget);
        expect(find.text('Переоценка 48%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const ValueKey('work-point-6')));
        await tester.tap(find.byKey(const ValueKey('work-point-6')));
        await settle(tester);
        await tester.ensureVisible(find.byKey(const ValueKey('usage-point-6')));
        await tester.tap(find.byKey(const ValueKey('usage-point-6')));
        await settle(tester);
        expect(find.text('Активно 34 мин'), findsOneWidget);
        final calendar = find.byKey(const ValueKey('activity-calendar'));
        await tester.ensureVisible(calendar);
        await settle(tester);
        expect(find.text('Календарь активности'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('activity-day-2025-10-20')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('activity-day-2026-10-20')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('activity-day-2026-10-13')));
        await settle(tester);
        final details = find.byKey(const ValueKey('activity-day-details'));
        expect(
          find.descendant(of: details, matching: find.text('10 мин')),
          findsOneWidget,
        );
        await expectLater(
          calendar,
          matchesGoldenFile('goldens/activity_${mobile ? 390 : 1440}.png'),
        );
        await tester.tap(find.byKey(const ValueKey('activity-day-2026-10-12')));
        await settle(tester);
        expect(
          find.descendant(of: details, matching: find.text('Нет активности')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('statistics-period')),
        );
        await tester.tap(find.text('30 дней'));
        await settle(tester);
        expect(find.byKey(const ValueKey('work-point-29')), findsOneWidget);
        await tester.tap(find.text('90 дней'));
        await settle(tester);
        expect(find.byKey(const ValueKey('work-point-12')), findsOneWidget);
        expect(find.byKey(const ValueKey('work-point-13')), findsNothing);
        await tester.tap(find.byTooltip('Предыдущий период'));
        await settle(tester);
        expect(find.text('За этот период пока нет данных.'), findsWidgets);
        expect(find.byKey(const ValueKey('estimate-mean-error')), findsNothing);
        expect(
          find.byKey(const ValueKey('estimate-task-details')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('activity-day-2026-10-13')),
          findsOneWidget,
        );
        expect(
          find.text('Последние 365 дней · только это устройство'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await settle(tester);
        expect(find.byType(StatisticsPage), findsNothing);
      },
    );
  }

  testInteraction('empty activity history stays usable on phone', (
    tester,
  ) async {
    await workspace(tester, mobile: true);
    await command(tester, LogicalKeyboardKey.digit5);
    await tester.tap(find.byKey(const ValueKey('open-statistics')));
    await tester.pump();
    await settle(tester);
    final calendar = find.byKey(const ValueKey('activity-calendar'));
    await tester.ensureVisible(calendar);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('activity-day-2026-10-19')));
    await settle(tester);
    expect(
      find.descendant(of: calendar, matching: find.text('Пока нет данных')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: calendar, matching: find.text('0')),
      findsNWidgets(3),
    );
    final scroll = find.byKey(const ValueKey('activity-calendar-scroll'));
    await tester.drag(scroll, const Offset(1200, 0));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('activity-day-2025-10-20')));
    await settle(tester);
    expect(find.text('пн, 20 октября 2025'), findsOneWidget);
    expect(
      find.descendant(of: calendar, matching: find.text('Пока нет данных')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testInteraction(
    'desktop note list is compact and keeps selection and deletion usable',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          for (var i = 0; i < 10; i++) {
            final note = await repo.createNote();
            await repo.saveNote(
              note.id,
              '',
              '# Заметка $i с очень длинным названием, которое не должно увеличивать карточку',
            );
          }
        },
      );
      await command(tester, LogicalKeyboardKey.digit4);
      final note = repo.snapshot.notes.firstWhere((n) => n.pinned.isEmpty);
      final tile = find.byKey(ValueKey('note-list-${note.id}'));
      expect(tester.getSize(tile).height, lessThanOrEqualTo(44));
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(32));
      await tester.tap(tile);
      await settle(tester);
      expect(tester.widget<ListTile>(tile).selected, isTrue);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/compact_notes_1440.png'),
      );
      await tester.tap(
        find.descendant(
          of: tile,
          matching: find.byTooltip('Действия с заметкой'),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Удалить заметку'));
      await settle(tester);
      await tester.tap(find.text('Удалить').last);
      await settle(tester);
      expect(repo.snapshot.notes.any((n) => n.id == note.id), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
