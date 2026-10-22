import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/ui/providers.dart';
import 'package:yggvion/ui/timer_control.dart';

import 'interaction_test.dart' show settle;

void main() {
  setUpAll(tz.initializeTimeZones);

  for (final compact in [true, false]) {
    testWidgets(
      'global timer adopts an incoming session and stops it (compact: $compact)',
      (tester) async {
        final now = DateTime.utc(2026, 10, 19, 12);
        late Repository repo;
        late Task remoteTask;
        await tester.runAsync(() async {
          repo = Repository(
            LocalDatabase(NativeDatabase.memory()),
            clock: () => now,
          );
          await repo.initialize();
          if (!compact) {
            final previous = await repo.createTask('Previous local timer');
            await repo.toggleCalendarTimer(previous);
            await repo.toggleCalendarTimer(repo.lastCalendarTask!);
          }
          remoteTask = await repo.createTask('Started on another device');
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() => repo.db.close());
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appProvider.overrideWith((ref) => repo)],
            child: MaterialApp(
              home: Scaffold(body: TimerControl(compact: compact)),
            ),
          ),
        );

        // Apply an incoming record as synchronization does, after the UI is open.
        final incoming = WorkSession.create(
          'remote-session',
          remoteTask.id,
          'another-device',
          now.subtract(const Duration(minutes: 25)),
          null,
        ).withVersion(1);
        await tester.runAsync(() async {
          await repo.db.put(incoming);
          await repo.reload();
        });
        await settle(tester);
        final control = find.byKey(const ValueKey('global-timer'));
        expect(
          find.descendant(
            of: control,
            matching: find.byIcon(
              compact ? Icons.pause_circle_outline : Icons.pause_rounded,
            ),
          ),
          findsOneWidget,
        );
        if (!compact) expect(find.text('00:25:00'), findsOneWidget);

        await tester.tap(control);
        await settle(tester);
        final stopped = repo.snapshot.sessions.singleWhere(
          (session) => session.id == incoming.id,
        );
        expect(stopped.end, now);
        expect(stopped.deviceId, 'another-device');
        expect(repo.snapshot.sessions.where((s) => s.running), isEmpty);
        expect(repo.lastCalendarTask!.id, remoteTask.id);
        expect(
          repo.snapshot.spent(remoteTask.id, now),
          const Duration(minutes: 25),
        );

        // Continuing on this device creates a new interval for the same task.
        await tester.tap(control);
        await settle(tester);
        final resumed = repo.snapshot.sessions.singleWhere((s) => s.running);
        expect(resumed.taskId, remoteTask.id);
        expect(resumed.deviceId, repo.deviceId);
        expect(resumed.id, isNot(incoming.id));
        expect(resumed.start, now);
      },
    );
  }
}
