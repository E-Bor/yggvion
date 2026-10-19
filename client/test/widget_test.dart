import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:yggvion/ui/task_editor.dart';
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
import 'package:yggvion/ui/app.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/notes.dart';

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('ru');
    final loader = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final size in [const Size(1440, 960), const Size(390, 844)]) {
    testWidgets('workspace and task editor fit ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Repository repo;
      late SyncService sync;
      late ReminderService reminders;
      await tester.runAsync(() async {
        repo = Repository(
          LocalDatabase(NativeDatabase.memory()),
          clock: () => DateTime.utc(2026, 10, 19, 7),
        );
        await repo.initialize(timezone: 'Europe/Moscow');
        await repo.saveProject('Личное', 0xff80adee);
        final now = repo.now();
        final start = now;
        await repo.createTask(
          'Спланировать неделю',
          description: 'Время для важного',
          projectId: repo.snapshot.projects.first.id,
          start: start,
          end: start.add(const Duration(hours: 1)),
        );
        await repo.createTask('Идея для нового проекта');
        await repo.saveNote(
          'scratchpad',
          'Быстрая заметка',
          '## Сегодня\n\nОставить место для глубокого фокуса.\n\n- Продумать следующую неделю\n- Записать новые идеи',
        );
        await repo.saveNote(
          'reference',
          'Под рукой',
          '**Рабочий ритм**\n\nУтро — важные задачи.\nПосле обеда — встречи и мелочи.',
        );
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/workspace_${size.width.toInt()}.png'),
      );
      if (size.width >= 1000) {
        await tester.drag(
          find.byKey(const ValueKey('sidebar-resize-handle')),
          const Offset(-150, 0),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile('goldens/workspace_collapsed.png'),
        );
        await tester.drag(
          find.byKey(const ValueKey('sidebar-resize-handle')),
          const Offset(150, 0),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
      }
      if (size.width >= 1000) {
        await tester.tap(find.byKey(const ValueKey('calendar-view-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Неделя').last);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(YggvionApp),
          matchesGoldenFile('goldens/workspace_week_1440.png'),
        );
        await tester.runAsync(() => repo.setView(CalendarView.day));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Спланировать неделю').first);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/task_editor_${size.width.toInt()}.png'),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('task-sessions')));
      await tester.tap(find.text('Потраченное время'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('add-work-session')),
      );
      await tester.tap(find.byKey(const ValueKey('add-work-session')));
      await tester.pumpAndSettle();
      expect(find.byType(SessionEditor), findsOneWidget);
      final grid = find.descendant(
        of: find.byType(SessionEditor),
        matching: find.byKey(const ValueKey('calendar-grid-gestures')),
      );
      final gesture = await tester.startGesture(
        tester.getTopLeft(grid) + const Offset(100, 9.5 * 72),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 36));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(YggvionApp),
        matchesGoldenFile('goldens/time_entry_${size.width.toInt()}.png'),
      );
      await tester.tap(find.byKey(const ValueKey('save-time-entries')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(repo.snapshot.sessions.single.end, repo.now());
      expect(
        repo.snapshot.spent(repo.snapshot.sessions.single.taskId, repo.now()),
        const Duration(minutes: 30),
      );
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => repo.createTask(
          'Пять минут',
          start: repo.now().add(const Duration(hours: 1)),
          end: repo.now().add(const Duration(hours: 1, minutes: 5)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (size.width > 1000) {
        await tester.tap(find.text('Задача').first);
      } else {
        await tester.tap(find.byTooltip('Создать'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Незапланированная задача'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Введите название'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byType(TextField).first,
        'Новая задача из интерфейса',
      );
      await tester.tap(find.text('Сохранить').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(
        repo.snapshot.tasks.any((t) => t.title == 'Новая задача из интерфейса'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Планировщик').last);
      await tester.pumpAndSettle();
      expect(find.text('Без расписания'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Заметки').last);
      await tester.pumpAndSettle();
      expect(find.byType(NotePanel), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      reminders.dispose();
      await tester.runAsync(() => repo.db.close());
    });
  }
  test('entity JSON preserves null running session end', () {
    final e = WorkSession.create(
      'id',
      'task',
      'device',
      DateTime.utc(2026),
      null,
    );
    expect(Entity.fromJson(e.toJson()).data['end'], isNull);
  });
}
