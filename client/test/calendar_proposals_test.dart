import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/calendar.dart';
import 'package:yggvion/ui/calendar_sharing.dart';

import 'interaction_test.dart' show workspace, settle, testInteraction;

Future<Task> proposal(Repository repo, {DateTime? start}) async {
  start ??= repo.now().add(const Duration(days: 1));
  final entity =
      Task.create(
        repo.newId(),
        'Встреча с гостем',
        description: 'Обсудить проект',
      ).change({
        'proposal': {
          'pending': true,
          'start': start.toUtc().toIso8601String(),
          'end': start
              .add(const Duration(minutes: 45))
              .toUtc()
              .toIso8601String(),
          'timezone': 'Europe/Moscow',
        },
      });
  await repo.commit([entity]);
  return repo.snapshot.task(entity.id)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  group('calendar proposals', () {
    late Repository repo;
    setUp(() async {
      repo = Repository(
        LocalDatabase(NativeDatabase.memory()),
        clock: () => DateTime.utc(2026, 10, 22, 9),
      );
      await repo.initialize();
    });
    tearDown(() async {
      await repo.db.close();
      repo.dispose();
    });

    test('accept uses requested time and duration once', () async {
      final task = await proposal(repo);
      expect(repo.snapshot.blocks, isEmpty);
      expect(repo.snapshot.unscheduled(task, repo.now()), isTrue);
      await Future.wait([repo.acceptProposal(task), repo.acceptProposal(task)]);
      final block = repo.snapshot.blocks.single;
      expect(block.start, task.proposedStart);
      expect(block.end, task.proposedEnd);
      expect(block.timezone, 'Europe/Moscow');
      expect(block.end.difference(block.start), const Duration(minutes: 45));
      expect(repo.snapshot.task(task.id)!.isProposed, isFalse);
      await repo.acceptProposal(task);
      expect(repo.snapshot.blocks, hasLength(1));
    });
    test(
      'manual planning replaces the proposed interval without an estimate',
      () async {
        final task = await proposal(repo);
        final start = repo.now().add(const Duration(days: 2));
        await repo.schedule(
          task,
          start,
          start.add(const Duration(minutes: 30)),
        );
        expect(repo.snapshot.task(task.id)!.isProposed, isFalse);
        expect(repo.snapshot.blocks.single.start, start);
        expect(
          repo.snapshot.blocks.single.end,
          start.add(const Duration(minutes: 30)),
        );
      },
    );
    test('acceptance rechecks availability after queued local edits', () async {
      final task = await proposal(repo);
      final occupied = await repo.createTask('Concurrent plan');
      final placing = repo.schedule(
        occupied,
        task.proposedStart!,
        task.proposedEnd!,
      );
      await expectLater(repo.acceptProposal(task), throwsStateError);
      await placing;
      expect(repo.snapshot.task(task.id)!.isProposed, isTrue);
      expect(repo.snapshot.blocks, hasLength(1));
    });
    test(
      'past or newly busy proposed time is rejected without losing proposal',
      () async {
        final past = await proposal(
          repo,
          start: repo.now().subtract(const Duration(hours: 2)),
        );
        await expectLater(repo.acceptProposal(past), throwsStateError);
        final future = await proposal(repo);
        final busy = await repo.createTask('Already occupied');
        await repo.schedule(busy, future.proposedStart!, future.proposedEnd!);
        await expectLater(repo.acceptProposal(future), throwsStateError);
        expect(repo.snapshot.task(past.id)!.isProposed, isTrue);
        expect(repo.snapshot.task(future.id)!.isProposed, isTrue);
        expect(repo.snapshot.blocks, hasLength(1));
        // The owner can still choose a different free time.
        final start = repo.now().add(const Duration(days: 3));
        await repo.schedule(
          future,
          start,
          start.add(const Duration(minutes: 30)),
        );
        expect(repo.snapshot.task(future.id)!.isProposed, isFalse);
      },
    );
  });

  for (final mobile in [false, true]) {
    testInteraction(
      'proposal card selects and schedules another time on ${mobile ? "phone" : "desktop"}',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async => proposal(repo),
        );
        final task = repo.snapshot.tasks.single;
        await tester.tap(find.text('Планировщик').first);
        await settle(tester);

        await tester.tap(find.byTooltip('Действия с предложением'));
        await settle(tester);
        expect(find.text('Открыть предложение'), findsOneWidget);
        expect(
          tester
              .widget<ProposedTaskCard>(find.byType(ProposedTaskCard))
              .selected,
          isFalse,
        );
        await tester.tapAt(const Offset(8, 8));
        await settle(tester);
        expect(repo.snapshot.blocks, isEmpty);

        await tester.tap(find.text(task.title));
        await settle(tester);
        expect(find.text('Выберите время: ${task.title}'), findsOneWidget);
        expect(
          tester
              .widget<CalendarPane>(find.byType(CalendarPane))
              .selectedTask
              ?.id,
          task.id,
        );
        expect(repo.snapshot.task(task.id)!.isProposed, isTrue);
        expect(repo.snapshot.blocks, isEmpty);
        if (mobile) {
          expect(find.byType(ProposedTaskCard), findsNothing);
        } else {
          expect(
            tester
                .widget<ProposedTaskCard>(find.byType(ProposedTaskCard))
                .selected,
            isTrue,
          );
          await tester.tap(find.text(task.title));
          await settle(tester);
          expect(
            tester.widget<CalendarPane>(find.byType(CalendarPane)).selectedTask,
            isNull,
          );
          await tester.tap(find.text(task.title));
          await settle(tester);
        }

        final grid = find.byKey(const ValueKey('calendar-grid-gestures'));
        final gesture = await tester.startGesture(
          tester.getTopLeft(grid) + const Offset(100, 16 * 72),
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (mobile) await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveBy(const Offset(0, 54));
        await tester.pump();
        await gesture.up();
        await settle(tester);
        final block = repo.snapshot.blocks.single;
        expect(block.taskId, task.id);
        expect(block.start, isNot(task.proposedStart));
        expect(block.duration, const Duration(minutes: 45));
        expect(repo.snapshot.task(task.id)!.isProposed, isFalse);
        expect(
          tester.widget<CalendarPane>(find.byType(CalendarPane)).selectedTask,
          isNull,
        );
        expect(find.text('Выберите время: ${task.title}'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testInteraction(
      'proposal planner card accepts time on ${mobile ? "phone" : "desktop"}',
      (tester) async {
        final repo = await workspace(
          tester,
          mobile: mobile,
          prepare: (repo) async {
            await proposal(repo);
          },
        );
        await tester.tap(find.text('Канбан').first);
        await settle(tester);
        expect(find.text('Встреча с гостем'), findsNothing);
        await tester.tap(find.text('Планировщик').first);
        await settle(tester);
        expect(find.byType(ProposedTaskCard), findsOneWidget);
        expect(find.text('ПРЕДЛОЖЕНО'), findsOneWidget);
        expect(find.text('Другое время'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Принять'));
        await settle(tester);
        expect(find.byType(ProposedTaskCard), findsNothing);
        expect(repo.snapshot.blocks, hasLength(1));
        expect(repo.snapshot.tasks.single.isProposed, isFalse);
        expect(find.text('Выберите время: Встреча с гостем'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
