import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/data/system_tracking.dart';
import 'package:yggvion/domain/models.dart';
import 'package:yggvion/domain/tracking_action.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.yggvion/tracking');
  late Repository repo;
  late SystemTrackingService service;
  late DateTime now;
  late List<Map<String, Object?>> pending;
  late List<Map<dynamic, dynamic>> publications;
  var failPublish = false;

  Map<String, Object?> command(
    String action,
    String taskId,
    DateTime at,
    List<String> sessions, {
    String? session,
  }) => {
    'id': '$action-${at.millisecondsSinceEpoch}',
    'taskId': taskId,
    'deviceId': repo.deviceId,
    'atMs': at.millisecondsSinceEpoch,
    'action': action,
    'sessionIds': sessions,
    'newSessionId': session,
  };

  setUpAll(tz.initializeTimeZones);
  setUp(() async {
    now = DateTime.utc(2026, 10, 23, 12);
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize();
    pending = [];
    publications = [];
    failPublish = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'pending':
          return List.of(pending);
        case 'publish':
          if (failPublish) throw PlatformException(code: 'test_failure');
          final data = call.arguments as Map;
          final acknowledged = data['acknowledged'] as List;
          pending.removeWhere((c) => acknowledged.contains(c['id']));
          if (pending.isNotEmpty) return false;
          publications.add(data);
          return true;
        case 'clear':
          pending.clear();
          return null;
      }
      throw StateError('Unexpected method ${call.method}');
    });
    service = SystemTrackingService(repo, platform: TargetPlatform.iOS);
  });
  tearDown(() async {
    service.dispose();
    await repo.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'language changes refresh lock-screen labels without changing time',
    () async {
      final task = await repo.createTask('My task');
      await repo.toggleCalendarTimer(task);
      await service.initialize();
      await repo.setLanguage('de');
      await service.refresh();
      final state = publications.last['state'] as Map;
      expect(state['title'], 'My task');
      expect((state['labels'] as Map)['running'], 'In Arbeit');
      expect((state['labels'] as Map)['minute'], 'Min.');
      expect(state['elapsedMs'], 0);
      expect(repo.snapshot.sessions, hasLength(1));
      await repo.setLanguage('ru');
    },
  );

  test(
    'background pause/resume/stop use tap times and survive unacknowledged replay',
    () async {
      final task = await repo.createTask('Доклад');
      await repo.toggleCalendarTimer(task);
      final first = repo.snapshot.sessions.single.id;
      final start = now;
      pending.addAll([
        command('pause', task.id, start.add(const Duration(minutes: 10)), [
          first,
        ]),
        command(
          'resume',
          task.id,
          start.add(const Duration(minutes: 30)),
          [],
          session: 'native-session',
        ),
        command('stop', task.id, start.add(const Duration(minutes: 45)), [
          'native-session',
        ]),
      ]);
      now = start.add(const Duration(hours: 2));
      failPublish = true;
      await service.initialize();
      expect(pending, hasLength(3));
      expect(service.error, isNotNull);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 25));
      expect(repo.trackedTask, isNull);
      failPublish = false;
      await service.refresh(force: true);
      expect(pending, isEmpty);
      expect(service.error, isNull);
      expect(repo.snapshot.sessions, hasLength(2));
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 25));
      expect(publications.last['state'], isNull);
      expect(repo.snapshot.task(task.id)!.done, isFalse);
    },
  );

  test(
    'stale lock-screen pause leaves newer tasks and other profiles alone',
    () async {
      final a = await repo.createTask('Первая'),
          b = await repo.createTask('Вторая');
      await repo.toggleTimer(a);
      final first = repo.snapshot.sessions.single.id;
      now = now.add(const Duration(minutes: 10));
      final stopAt = now;
      now = now.add(const Duration(minutes: 5));
      await repo.toggleTimer(b);
      await repo.applyTrackingAction(
        TrackingAction.fromMap(command('pause', a.id, stopAt, [first])),
      );
      expect(repo.activeTimerTask!.id, b.id);
      expect(repo.snapshot.spent(a.id, now), const Duration(minutes: 10));
      final foreign = command(
        'pause',
        b.id,
        now,
        repo.snapshot.sessions.map((s) => s.id).toList(),
      )..['deviceId'] = 'replaced-profile';
      await repo.applyTrackingAction(TrackingAction.fromMap(foreign));
      expect(repo.activeTimerTask!.id, b.id);
      await repo.status(repo.snapshot.task(a.id)!, TaskStatus.done);
      await repo.applyTrackingAction(
        TrackingAction.fromMap(
          command('resume', a.id, now, [], session: 'stale-resume'),
        ),
      );
      expect(await repo.db.entity('stale-resume'), isNull);
    },
  );

  test('publishes accent and time without one-second updates', () async {
    final task = await repo.createTask('Исследование');
    await repo.toggleTimer(task);
    now = now.add(const Duration(minutes: 5));
    await service.initialize();
    final state = publications.last['state'] as Map;
    expect(state['running'], true);
    expect(state['plannedMs'], const Duration(minutes: 30).inMilliseconds);
    expect(state['elapsedMs'], const Duration(minutes: 5).inMilliseconds);
    expect(state['accent'], repo.snapshot.settings.accentColor);
    final count = publications.length;
    now = now.add(const Duration(minutes: 10));
    await repo.createNote();
    await service.refresh();
    expect(publications, hasLength(count));
    await repo.status(repo.snapshot.task(task.id)!, TaskStatus.done);
    await service.refresh();
    expect(publications.last['state'], isNull);
  });

  test(
    'action arriving during publish is drained before the next snapshot',
    () async {
      final task = await repo.createTask('Задача');
      await repo.toggleTimer(task);
      final session = repo.snapshot.sessions.single.id;
      var calls = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'pending') return List.of(pending);
        if (call.method == 'publish') {
          if (calls++ == 0) {
            now = now.add(const Duration(minutes: 7));
            pending.add(command('pause', task.id, now, [session]));
            return false;
          }
          final data = call.arguments as Map;
          expect(data['acknowledged'], [pending.single['id']]);
          expect((data['state'] as Map)['running'], false);
          pending.clear();
          return true;
        }
        return null;
      });
      await service.initialize();
      expect(calls, 2);
      expect(repo.activeTimerTask, isNull);
      expect(repo.snapshot.spent(task.id, now), const Duration(minutes: 7));
    },
  );
}
