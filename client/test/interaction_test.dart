import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/reminders.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/sync.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/recurrence.dart';
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/dashboard.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/repeat_editor.dart';
import 'package:yggvion/ui/settings.dart';
import 'package:yggvion/ui/theme.dart';
import 'package:yggvion/ui/task_card.dart';
import 'package:yggvion/ui/task_editor.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pumpAndSettle();
}

Future<Repository> workspace(
  WidgetTester tester, {
  bool mobile = false,
  Future<void> Function(Repository)? prepare,
}) async {
  debugDefaultTargetPlatformOverride = mobile
      ? TargetPlatform.iOS
      : TargetPlatform.macOS;
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1440, 960);
  tester.view.devicePixelRatio = 1;
  late Repository repo;
  late SyncService sync;
  late ReminderService reminders;
  await tester.runAsync(() async {
    repo = Repository(
      LocalDatabase(NativeDatabase.memory()),
      clock: () => DateTime.utc(2026, 10, 19, 12),
    );
    await repo.initialize();
    if (prepare != null) await prepare(repo);
    sync = SyncService(repo);
    reminders = ReminderService(repo);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appProvider.overrideWith((ref) => repo),
        syncProvider.overrideWithValue(sync),
        remindersProvider.overrideWithValue(reminders),
      ],
      child: const YggvionApp(),
    ),
  );
  await settle(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    reminders.dispose();
    sync.dispose();
    await tester.runAsync(() => repo.db.close());
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  return repo;
}

Future<void> command(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await settle(tester);
}

void testInteraction(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  testInteraction(
    'desktop board drags immediately and excludes recurring instances',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask('Обычная задача');
          final repeat = await repo.createTask('Ежедневная', start: repo.now());
          await RecurrenceService(repo).create(
            repeat,
            repo.snapshot.taskBlocks(repeat.id).single,
            'FREQ=DAILY',
          );
        },
      );
      await command(tester, LogicalKeyboardKey.digit3);
      expect(find.text('Ежедневная'), findsNothing);
      expect(find.byType(BoardTask), findsOneWidget);
      final task = repo.snapshot.tasks.firstWhere(
        (t) => t.title == 'Обычная задача',
      );
      final from = tester.getCenter(find.text(task.title));
      final target =
          tester
              .getRect(find.byKey(const ValueKey('board-waiting')))
              .topCenter +
          const Offset(0, 150);
      final drag = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(25, 0));
      await tester.pump();
      await drag.moveTo(target);
      await tester.pump();
      await drag.up();
      await settle(tester);
      expect(repo.snapshot.task(task.id)!.status, TaskStatus.waiting);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'desktop splits persist, all pages have shortcuts, task and note creation work',
    (tester) async {
      final repo = await workspace(tester);
      await tester.drag(
        find.byKey(const ValueKey('calendar-notes-divider')),
        const Offset(0, -90),
      );
      await settle(tester);
      expect(repo.calendarFraction, lessThan(.64));
      await tester.drag(
        find.byKey(const ValueKey('scratchpad-reference-divider')),
        const Offset(-100, 0),
      );
      await settle(tester);
      expect(repo.scratchpadFraction, lessThan(.62));
      expect(
        await tester.runAsync(() => repo.db.meta('home_calendar_fraction')),
        isNotNull,
      );
      await command(tester, LogicalKeyboardKey.digit2);
      expect(find.text('Без расписания'), findsOneWidget);
      await command(tester, LogicalKeyboardKey.digit3);
      expect(find.byType(DragTarget<Task>), findsNWidgets(4));
      await command(tester, LogicalKeyboardKey.digit4);
      expect(find.text('Быстрая заметка'), findsWidgets);
      await command(tester, LogicalKeyboardKey.digit5);
      expect(find.byType(SettingsPage), findsOneWidget);
      await command(tester, LogicalKeyboardKey.digit1);
      expect(find.byType(Dashboard), findsOneWidget);
      await command(tester, LogicalKeyboardKey.keyN);
      await tester.enterText(find.byType(TextField).first, 'Из клавиатуры');
      await command(tester, LogicalKeyboardKey.enter);
      expect(repo.snapshot.tasks.single.title, 'Из клавиатуры');
      await command(tester, LogicalKeyboardKey.keyN, shift: true);
      expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), hasLength(1));
      await command(tester, LogicalKeyboardKey.keyF);
      expect(find.byType(SearchDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await command(tester, LogicalKeyboardKey.digit1);
      await tester.tap(find.text('Заметка').first);
      await settle(tester);
      expect(repo.snapshot.notes.where((n) => n.pinned.isEmpty), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction(
    'right click menu anchors at task, unschedule returns task to planner and delete removes it',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (r) async {
          await r.createTask(
            'Убрать блок',
            start: r.now(),
            end: r.now().add(const Duration(hours: 1)),
          );
        },
      );
      final block = repo.snapshot.blocks.single;
      final point =
          tester.getTopLeft(
            find.byKey(ValueKey('calendar-block-${block.id}')),
          ) +
          const Offset(24, 28);
      final mouse = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.text('Открыть задачу'));
      expect((menu.left - point.dx).abs(), lessThan(55));
      expect(menu.top, lessThan(point.dy + 60));
      await tester.tap(find.text('Убрать из плана'));
      await settle(tester);
      expect(repo.snapshot.blocks, isEmpty);
      expect(find.byType(CalendarBlock), findsNothing);
      await command(tester, LogicalKeyboardKey.digit2);
      expect(find.text('Убрать блок'), findsOneWidget);
      await tester.tap(find.text('Убрать блок'));
      await tester.pumpAndSettle();
      // Planner selects first; the card menu offers deletion without scheduling.
      final card = find.byType(TaskCard).first;
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await settle(tester);
      expect(repo.snapshot.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('calendar timer can be stopped and resumed from top bar', (
    tester,
  ) async {
    final repo = await workspace(
      tester,
      prepare: (r) async {
        await r.createTask(
          'Таймер',
          start: r.now(),
          end: r.now().add(const Duration(hours: 1)),
        );
      },
    );
    final block = repo.snapshot.blocks.single;
    await tester.tap(find.byKey(ValueKey('calendar-timer-${block.id}')));
    await settle(tester);
    expect(repo.lastCalendarTask!.id, block.taskId);
    expect(repo.snapshot.sessions.where((s) => s.running), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('global-timer')));
    await settle(tester);
    expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
    await command(tester, LogicalKeyboardKey.space, shift: true);
    expect(
      repo.snapshot.sessions.where((s) => s.running).single.taskId,
      block.taskId,
    );
  });

  testInteraction(
    'iPhone scroll stays scroll; hold and swipe creates, moves and resizes both edges',
    (tester) async {
      final repo = await workspace(tester, mobile: true);
      final grid = find.byKey(const ValueKey('calendar-grid-gestures'));
      final before = tester.getTopLeft(grid).dy;
      await tester.dragFrom(const Offset(200, 450), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(grid).dy, lessThan(before));
      expect(find.byType(TaskEditor), findsNothing);
      final location = tester.getTopLeft(grid) + const Offset(160, 13 * 72);
      final create = await tester.startGesture(location);
      await tester.pump(const Duration(milliseconds: 600));
      await create.moveBy(const Offset(0, 72));
      await tester.pump();
      await create.up();
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditor), findsOneWidget);
      expect(find.byType(TimezoneField), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Создано жестом');
      await tester.tap(find.text('Сохранить').last);
      await settle(tester);
      final block = repo.snapshot.blocks.single;
      expect(block.duration, const Duration(hours: 1));
      final blockFinder = find.byKey(ValueKey('calendar-block-${block.id}'));
      expect(
        find.byKey(ValueKey('block-handle-mark-start-${block.id}')),
        findsNothing,
      );
      final move = await tester.startGesture(tester.getCenter(blockFinder));
      await tester.pump(const Duration(milliseconds: 600));
      await move.moveBy(const Offset(0, 72));
      await tester.pump();
      await move.up();
      await settle(tester);
      expect(
        repo.snapshot.blocks.single.start,
        block.start.add(const Duration(hours: 1)),
      );
      final startHandle = find.byKey(
        ValueKey('block-resize-start-${block.id}'),
      );
      final endHandle = find.byKey(ValueKey('block-resize-end-${block.id}'));
      expect(
        find.byKey(ValueKey('block-handle-mark-start-${block.id}')),
        findsOneWidget,
      );
      expect(startHandle, findsOneWidget);
      expect(endHandle, findsOneWidget);
      final beforeResize = repo.snapshot.blocks.single;
      await tester.drag(startHandle, const Offset(0, -36));
      await settle(tester);
      expect(
        repo.snapshot.blocks.single.start.isBefore(beforeResize.start),
        isTrue,
      );
      final beforeEnd = repo.snapshot.blocks.single.end;
      await tester.drag(endHandle, const Offset(0, 36));
      await settle(tester);
      expect(repo.snapshot.blocks.single.end.isAfter(beforeEnd), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testInteraction('custom reminders use units and reject invalid amounts', (
    tester,
  ) async {
    await workspace(tester);
    int? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<int>(
                  context: context,
                  builder: (_) => const ReminderOffsetEditor(),
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('reminder-amount')), '-1');
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(find.text('От 0 до 8760'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reminder-unit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('недель').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('reminder-amount')), '3');
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(result, 30240);
  });

  testInteraction(
    'weekly custom repeat has weekdays and interval without date limits',
    (tester) async {
      await workspace(tester);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => RepeatEditor(
                      initial: '',
                      start: DateTime.utc(2026, 10, 19),
                      timezone: 'UTC',
                    ),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.text('Окончание'), findsNothing);
      expect(find.byType(DateTimeButton), findsNothing);
      expect(find.byType(FilterChip), findsNWidgets(7));
      await tester.enterText(
        find.byKey(const ValueKey('repeat-interval')),
        '0',
      );
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Интервал — от 1'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('repeat-interval')),
        '2',
      );
      await tester.tap(find.text('Ср'));
      await tester.pump();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(result, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE');
    },
  );

  testInteraction(
    'trackpad scroll never creates, moves or resizes a calendar event',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask(
            'Тачпад',
            start: repo.now().add(const Duration(hours: 1)),
            end: repo.now().add(const Duration(hours: 2)),
          );
        },
      );
      final block = repo.snapshot.blocks.single;
      final grid = find.byKey(const ValueKey('calendar-grid-gestures'));
      final event = find.byKey(ValueKey('calendar-block-${block.id}'));
      expect(
        find.byKey(ValueKey('block-handle-mark-start-${block.id}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('block-handle-mark-end-${block.id}')),
        findsNothing,
      );
      Future<void> scroll(Offset point) async {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(point);
        await gesture.panZoomUpdate(point, pan: const Offset(0, -35));
        await tester.pump();
        await gesture.panZoomUpdate(point, pan: const Offset(0, -65));
        await gesture.panZoomEnd();
        await settle(tester);
        expect(find.byType(TaskEditor), findsNothing);
        expect(repo.snapshot.blocks.single.start, block.start);
        expect(repo.snapshot.blocks.single.end, block.end);
      }

      final top = tester.getTopLeft(grid).dy;
      await scroll(const Offset(700, 250));
      expect(tester.getTopLeft(grid).dy, lessThan(top));
      await scroll(tester.getCenter(event));
      await scroll(
        tester.getCenter(find.byKey(ValueKey('block-resize-end-${block.id}'))),
      );
      // A physical click from a trackpad is delivered as a mouse event.
      final mouse = await tester.startGesture(
        const Offset(700, 460),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(0, 40));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditor), findsOneWidget);
    },
  );

  testInteraction(
    'planner hides all recurring instances including rolled-over and unscheduled ones',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.createTask('Обычная незапланированная');
          final at = repo.now().subtract(const Duration(days: 2));
          final task = await repo.createTask('Регулярная', start: at);
          await RecurrenceService(repo).create(
            task,
            repo.snapshot.taskBlocks(task.id).single,
            'FREQ=DAILY;COUNT=5',
          );
          await repo.rollover();
          final future = repo.snapshot.blocks.firstWhere(
            (b) => b.start.isAfter(repo.now()),
          );
          await repo.unschedule(future);
        },
      );
      expect(
        repo.snapshot.tasks.where((t) => t.seriesId.isNotEmpty),
        isNotEmpty,
      );
      await command(tester, LogicalKeyboardKey.digit2);
      expect(
        find.widgetWithText(TaskCard, 'Обычная незапланированная'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TaskCard, 'Регулярная'), findsNothing);
    },
  );

  testInteraction(
    'existing editor changes the clicked block, reminders and all day without touching another block',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          final task = await repo.createTask(
            'Два блока',
            start: repo.now(),
            reminders: [5],
          );
          await repo.schedule(
            task,
            repo.now().add(const Duration(hours: 1)),
            repo.now().add(const Duration(hours: 2)),
            reminders: [60],
          );
        },
      );
      final blocks = repo.snapshot.blocks
        ..sort((a, b) => a.start.compareTo(b.start));
      final first = blocks.first, second = blocks.last;
      await tester.tap(find.byKey(ValueKey('calendar-block-${second.id}')));
      await tester.pumpAndSettle();
      expect(find.text('ЗАДАЧА'), findsNothing);
      expect(find.byKey(const ValueKey('schedule-start-time')), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('reminder-choice-0')),
            )
            .value,
        60,
      );
      expect(
        find.byKey(const ValueKey('add-work-session')).hitTestable(),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('reminder-choice-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('За 15 мин').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('task-title')),
        'Исправлено',
      );
      await tester.tap(find.byKey(const ValueKey('schedule-all-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить').last);
      await settle(tester);
      final saved = repo.snapshot.blocks.firstWhere((b) => b.id == second.id);
      expect(saved.reminders, [15]);
      expect(saved.allDay, isTrue);
      expect(saved.duration, const Duration(days: 1));
      final untouched = repo.snapshot.blocks.firstWhere(
        (b) => b.id == first.id,
      );
      expect(untouched.entity.encoded, first.entity.encoded);
      expect(repo.snapshot.task(second.taskId)!.title, 'Исправлено');
      await tester.tap(find.byKey(ValueKey('calendar-block-${second.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('reminder-choice-0')),
            )
            .value,
        15,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('schedule-all-day')))
            .value,
        isTrue,
      );
    },
  );

  testInteraction(
    'changing reminders on a series can apply to following instances only',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          final at = repo.now().subtract(const Duration(days: 1));
          final task = await repo.createTask(
            'Серия',
            start: at,
            reminders: [0],
          );
          await RecurrenceService(repo).create(
            task,
            repo.snapshot.taskBlocks(task.id).single,
            'FREQ=DAILY;COUNT=3',
          );
        },
      );
      final today = repo.snapshot.blocks.firstWhere(
        (b) => b.start.isAtSameMomentAs(repo.now()),
      );
      await tester.tap(find.byKey(ValueKey('calendar-block-${today.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reminder-choice-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('За 30 мин').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Эту и последующие'));
      await settle(tester);
      for (final block in repo.snapshot.blocks) {
        expect(block.reminders, block.start.isBefore(repo.now()) ? [0] : [30]);
      }
    },
  );

  testInteraction(
    'default task color persists in settings and project color wins on opaque cards',
    (tester) async {
      final repo = await workspace(
        tester,
        prepare: (repo) async {
          await repo.saveProject('Проект', Palette.projects[3].toARGB32());
          await repo.createTask('Без проекта', start: repo.now());
          await repo.createTask(
            'С проектом',
            projectId: repo.snapshot.projects.single.id,
            start: repo.now().add(const Duration(hours: 1)),
          );
        },
      );
      await command(tester, LogicalKeyboardKey.digit5);
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-color-1')).first,
      );
      await tester.tap(find.byKey(const ValueKey('task-color-1')).first);
      await tester.ensureVisible(find.text('Сохранить настройки'));
      await tester.tap(find.text('Сохранить настройки'));
      await settle(tester);
      expect(repo.snapshot.settings.taskColor, Palette.projects[1].toARGB32());
      await command(tester, LogicalKeyboardKey.digit1);
      for (final task in repo.snapshot.tasks) {
        final block = repo.snapshot.taskBlocks(task.id).single;
        final color = task.projectId.isEmpty
            ? Palette.projects[1]
            : Palette.projects[3];
        expect(repo.snapshot.taskColor(task), color.toARGB32());
        final finder = find.descendant(
          of: find.byKey(ValueKey('calendar-block-${block.id}')),
          matching: find.byType(Container),
        );
        final panel = tester
            .widgetList<Container>(finder)
            .firstWhere(
              (w) =>
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).borderRadius ==
                      BorderRadius.circular(8),
            );
        expect(
          (panel.decoration as BoxDecoration).color,
          Palette.taskSurface(color),
        );
        expect((panel.decoration as BoxDecoration).color!.a, 1);
      }
    },
  );
  testInteraction(
    'compact creation edits time directly and existing events expose the same repeat options',
    (tester) async {
      final repo = await workspace(tester);
      await command(tester, LogicalKeyboardKey.keyN);
      expect(find.text('НОВАЯ ЗАДАЧА'), findsNothing);
      expect(find.text('Введите название'), findsOneWidget);
      await tester.tap(find.text('Запланировать'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-end-time')));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '14');
      await tester.enterText(fields.at(1), '45');
      final ok = MaterialLocalizations.of(
        tester.element(find.byType(TimePickerDialog)),
      ).okButtonLabel;
      await tester.tap(find.text(ok));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('task-title')),
        'Время и повторение',
      );
      await tester.tap(find.text('Сохранить').last);
      await settle(tester);
      final original = repo.snapshot.blocks.single;
      expect(original.end, DateTime.utc(2026, 10, 19, 14, 45));
      await tester.tap(find.byKey(ValueKey('calendar-block-${original.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(RepeatPicker));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Каждую неделю').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reminder-choice-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Без напоминания').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить').last);
      await settle(tester);
      final task = repo.snapshot.task(original.taskId)!;
      expect(task.seriesId, isNotEmpty);
      for (final block in repo.snapshot.blocks) {
        expect(block.reminders, isEmpty);
        expect(block.duration, const Duration(hours: 2, minutes: 45));
      }
    },
  );
}
