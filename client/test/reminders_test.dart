import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:yggvion/data/database.dart';
import 'package:yggvion/data/reminders.dart';
import 'package:yggvion/data/repository.dart';
import 'package:yggvion/domain/birthdays.dart';
import 'package:yggvion/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late Repository repo;
  late ReminderService service;
  late List<MethodCall> calls;
  late Map<int, Map<String, Object?>> pending;
  late bool permission, failScheduling;
  setUp(() async {
    tz.initializeTimeZones();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    // The native plugin validates against wall-clock time before the mocked
    // channel is called, so this anchor must stay in the future on every run.
    final now = DateTime.now().toUtc().add(const Duration(days: 1));
    repo = Repository(LocalDatabase(NativeDatabase.memory()), clock: () => now);
    await repo.initialize();
    calls = [];
    pending = {};
    permission = true;
    failScheduling = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'initialize':
              return true;
            case 'getNotificationAppLaunchDetails':
              return {'notificationLaunchedApp': false};
            case 'requestPermissions':
              return permission;
            case 'checkPermissions':
              return {
                'isEnabled': permission,
                'isAlertEnabled': permission,
                'isSoundEnabled': permission,
              };
            case 'pendingNotificationRequests':
              return pending.values.toList();
            case 'zonedSchedule':
              if (failScheduling) {
                throw PlatformException(
                  code: 'schedule_failed',
                  message: 'Test failure',
                );
              }
              final data = Map<String, Object?>.from(call.arguments as Map);
              pending[data['id']! as int] = {
                'id': data['id'],
                'title': data['title'],
                'body': data['body'],
                'payload': data['payload'],
              };
              return null;
            case 'cancelAll':
              pending.clear();
              return null;
            case 'cancel':
              pending.remove(call.arguments as int);
              return null;
          }
          return null;
        });
    service = ReminderService(repo);
    await service.initialize();
  });
  tearDown(() async {
    service.dispose();
    await repo.db.close();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native schedule follows local creation, movement and unscheduling',
    () async {
      final task = await repo.createTask(
        'На этом телефоне',
        start: repo.now().add(const Duration(hours: 3)),
        reminders: [0, 60],
      );
      await service.refresh();
      expect(service.error, isNull);
      expect(pending, hasLength(2));
      var block = repo.snapshot.taskBlocks(task.id).single;
      final original =
          calls.lastWhere((c) => c.method == 'zonedSchedule').arguments as Map;
      await repo.changeBlock(
        block,
        block.start.add(const Duration(hours: 2)),
        block.end.add(const Duration(hours: 2)),
      );
      await service.refresh();
      final moved =
          calls.lastWhere((c) => c.method == 'zonedSchedule').arguments as Map;
      expect(moved['scheduledDateTime'], isNot(original['scheduledDateTime']));
      expect(pending, hasLength(2));
      block = repo.snapshot.taskBlocks(task.id).single;
      await repo.unschedule(block);
      await service.refresh();
      expect(pending, isEmpty);
    },
  );

  test(
    'birthday refresh cancels legacy month and week notifications on the device',
    () async {
      final date = repo.now().add(const Duration(days: 50));
      await BirthdayService(
        repo,
      ).save('Аня', DateTime(1990, date.month, date.day));
      await repo.commit([
        for (final block in repo.snapshot.blocks)
          block.entity.change({
            'reminder_at': [
              wireTime(
                block.reminderAt.single.subtract(const Duration(days: 30)),
              ),
              wireTime(
                block.reminderAt.single.subtract(const Duration(days: 7)),
              ),
              wireTime(block.reminderAt.single),
            ],
          }),
      ]);
      for (final block in repo.snapshot.blocks) {
        for (var index = 0; index < 3; index++) {
          final reminder = PlannedReminder(
            '${block.id}:at:$index',
            block.taskId,
            'Аня',
            block.reminderAt[index],
          );
          pending[reminder.id] = {
            'id': reminder.id,
            'title': reminder.title,
            'body': '',
            'payload': reminder.taskId,
          };
        }
      }
      await service.refresh();
      expect(service.error, isNull);
      final expected = remindersFor(repo.snapshot, repo.now());
      expect(pending.keys.toSet(), expected.map((r) => r.id).toSet());
      expect(
        pending.values.every(
          (r) => r['body'] == 'Сегодня день рождения. Не забудьте поздравить!',
        ),
        isTrue,
      );
      await repo.status(
        repo.snapshot.task(expected.first.taskId)!,
        TaskStatus.done,
      );
      await service.refresh();
      expect(pending.containsKey(expected.first.id), isFalse);
    },
  );

  test(
    'request permission once, surface denial, then recheck permission from settings',
    () async {
      permission = false;
      await service.requestPermissionOnce();
      expect(service.permissionGranted, isFalse);
      final count = calls.where((c) => c.method == 'requestPermissions').length;
      await service.requestPermissionOnce();
      expect(
        calls.where((c) => c.method == 'requestPermissions'),
        hasLength(count),
      );
      await expectLater(service.testNotification(), throwsStateError);
      permission = true;
      await service.checkPermission();
      expect(service.permissionGranted, isTrue);
      await service.testNotification();
      expect(pending.containsKey(ReminderService.testNotificationId), isTrue);
      await service.refresh();
      expect(pending.containsKey(ReminderService.testNotificationId), isTrue);
    },
  );

  test('scheduling error is visible and retries successfully', () async {
    failScheduling = true;
    await repo.createTask(
      'Повторить доставку',
      start: repo.now().add(const Duration(hours: 1)),
    );
    await service.refresh();
    expect(service.error, contains('schedule_failed'));
    expect(pending, isEmpty);
    failScheduling = false;
    await service.refresh();
    expect(service.error, isNull);
    expect(pending, hasLength(1));
  });

  test(
    'storage reset cancels notifications and prevents rescheduling',
    () async {
      await repo.createTask(
        'Private reminder',
        start: repo.now().add(const Duration(hours: 1)),
      );
      await service.refresh();
      expect(pending, isNotEmpty);
      await service.clearAndStop();
      expect(pending, isEmpty);
      expect(calls.where((c) => c.method == 'cancelAll'), hasLength(1));
      expect(service.scheduledCount, 0);
      final before = calls.length;
      await repo.createTask(
        'Late reminder',
        start: repo.now().add(const Duration(hours: 2)),
      );
      await service.refresh();
      service.changed();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(pending, isEmpty);
      expect(calls.length, before);
    },
  );
}
