import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import 'repository.dart';

class PlannedReminder {
  const PlannedReminder(
    this.key,
    this.taskId,
    this.title,
    this.at, {
    this.body = 'Пора начать · Yggvion',
  });
  final String key, taskId, title;
  final String body;
  final DateTime at;
  String get deliveryKey => 'notified:$key:${at.millisecondsSinceEpoch}';
  int get id => int.parse(
    sha256.convert(utf8.encode(key)).toString().substring(0, 7),
    radix: 16,
  );
}

List<PlannedReminder> remindersFor(Snapshot snapshot, DateTime now) {
  final result = <PlannedReminder>[];
  for (final block in snapshot.blocks) {
    final task = snapshot.task(block.taskId);
    if (task == null || task.done || block.historical) continue;
    if (block.reminderAt.isNotEmpty) {
      for (var index = 0; index < block.reminderAt.length; index++) {
        final at = block.reminderAt[index];
        // Older clients stored month/week reminders as well. Never schedule
        // those, even before the birthday series has been refreshed locally.
        if (task.isBirthday &&
            (at.isBefore(block.start) || !at.isBefore(block.end))) {
          continue;
        }
        if (at.isAfter(now)) {
          result.add(
            PlannedReminder(
              // Keep the original day-of-birthday delivery key across updates.
              '${block.id}:at:${task.isBirthday ? 2 : index}',
              task.id,
              task.title,
              at,
              body: task.isBirthday
                  ? 'Сегодня день рождения. Не забудьте поздравить!'
                  : 'Пора начать · Yggvion',
            ),
          );
        }
      }
      continue;
    }
    for (final offset in block.reminders) {
      final at = block.start.subtract(Duration(minutes: offset));
      if (at.isAfter(now)) {
        result.add(
          PlannedReminder('${block.id}:$offset', task.id, task.title, at),
        );
      }
    }
  }
  for (final e in snapshot.entities.where((e) => e.kind == 'snooze')) {
    final task = snapshot.task(e.data['task_id'] as String),
        at = parseTime(e.data['at']);
    if (task != null && !task.done && at.isAfter(now)) {
      result.add(
        PlannedReminder(
          e.id,
          task.id,
          task.title,
          at,
          body: task.isBirthday
              ? 'Напоминание о дне рождения'
              : 'Пора начать · Yggvion',
        ),
      );
    }
  }
  return result..sort((a, b) => a.at.compareTo(b.at));
}

class ReminderService {
  ReminderService(this.repo);
  final Repository repo;
  final TargetPlatform platform = defaultTargetPlatform;
  final plugin = FlutterLocalNotificationsPlugin();
  bool initialized = false, _busy = false, _again = false, _disposed = false;
  String? error;
  String? _signature;
  bool? permissionGranted;
  int scheduledCount = 0;
  static const testNotificationId = 2147483646;
  Timer? _debounce, _linuxTimer;
  bool _linuxBusy = false;
  String? pendingTaskId;
  void Function(String taskId)? onOpenTask;

  void _response(NotificationResponse response) {
    if (_disposed) return;
    final id = response.payload;
    if (id == null || repo.snapshot.task(id) == null) return;
    if (response.actionId == 'snooze') {
      unawaited(
        repo.snooze(id, const Duration(minutes: 10)).catchError((Object e) {
          error = 'Не удалось отложить уведомление: $e';
          repo.publish();
        }),
      );
    } else if (onOpenTask != null) {
      onOpenTask!(id);
    } else {
      pendingTaskId = id;
    }
  }

  Future<void> initialize() async {
    try {
      final categories = [
        DarwinNotificationCategory(
          'calendar',
          actions: [
            DarwinNotificationAction.plain(
              'snooze',
              'Через 10 минут',
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
      ];
      await plugin.initialize(
        InitializationSettings(
          android: const AndroidInitializationSettings(
            '@drawable/ic_notification',
          ),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
            notificationCategories: categories,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
            notificationCategories: categories,
          ),
          linux: const LinuxInitializationSettings(
            defaultActionName: 'Открыть',
          ),
          windows: const WindowsInitializationSettings(
            appName: 'Yggvion',
            appUserModelId: 'dev.yggvion.yggvion',
            guid: '37ad4b76-7b08-4604-a3d4-9f96923f4257',
          ),
        ),
        onDidReceiveNotificationResponse: _response,
      );
      initialized = true;
      // The Linux plugin has no launch-details implementation; delivery there
      // is handled by this process or the local companion.
      final launch = (platform == TargetPlatform.linux)
          ? null
          : await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse != null) {
        _response(launch!.notificationResponse!);
      }
      repo.addListener(changed);
      await checkPermission();
      await refresh();
      if ((platform == TargetPlatform.linux)) {
        unawaited(_linuxTick());
        _linuxTimer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _linuxTick(),
        );
      }
    } catch (e) {
      error = 'Не удалось включить уведомления: $e';
    }
  }

  void changed() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 100),
      () => unawaited(refresh()),
    );
  }

  Future<void> checkPermission() async {
    if (!initialized) return;
    final before = permissionGranted;
    if ((platform == TargetPlatform.iOS)) {
      permissionGranted =
          (await plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.checkPermissions())
              ?.isEnabled;
    } else if ((platform == TargetPlatform.macOS)) {
      permissionGranted =
          (await plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.checkPermissions())
              ?.isEnabled;
    } else if ((platform == TargetPlatform.android)) {
      permissionGranted = await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
    }
    if (before != permissionGranted) repo.publish();
  }

  Future<void> requestPermissionOnce() async {
    if (_disposed ||
        !initialized ||
        await repo.db.meta('notification_permission_asked') == 'true') {
      return;
    }
    await requestPermission();
    if (!_disposed) {
      await repo.db.setMeta('notification_permission_asked', 'true');
    }
  }

  Future<void> openSettings() async {
    if (platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.android) {
      final opened = await const MethodChannel(
        'dev.yggvion/notification_settings',
      ).invokeMethod<bool>('open');
      if (opened != true) {
        throw StateError('Не удалось открыть системные настройки уведомлений.');
      }
    } else if (platform == TargetPlatform.windows) {
      if (!await launchUrl(Uri.parse('ms-settings:notifications'))) {
        throw StateError('Не удалось открыть настройки уведомлений Windows.');
      }
    } else {
      for (final command in [
        ['gnome-control-center', 'notifications'],
        ['systemsettings', 'kcm_notifications'],
      ]) {
        try {
          await Process.start(
            command.first,
            command.skip(1).toList(),
            mode: ProcessStartMode.detached,
          );
          return;
        } on ProcessException {
          // Try the other supported desktop settings application.
        }
      }
      throw StateError(
        'Откройте раздел уведомлений в настройках рабочего окружения.',
      );
    }
  }

  Future<void> requestPermission() async {
    if (!initialized) throw StateError(error ?? 'Служба уведомлений не готова');
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestExactAlarmsPermission();
    await plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await checkPermission();
    _signature = null;
    await refresh();
  }

  Future<void> testNotification() async {
    await requestPermission();
    if (_disposed) return;
    if (permissionGranted == false) {
      throw StateError(
        'Разрешите уведомления для Yggvion в настройках устройства',
      );
    }
    if ((platform == TargetPlatform.linux)) {
      await plugin.show(
        testNotificationId,
        'Yggvion',
        'Проверка уведомлений',
        details,
      );
      return;
    }
    await plugin.zonedSchedule(
      testNotificationId,
      'Yggvion',
      'Уведомления работают',
      tz.TZDateTime.from(repo.now().add(const Duration(seconds: 10)), tz.UTC),
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  NotificationDetails get details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'calendar',
      'Календарь',
      channelDescription: 'Начало запланированных задач',
      importance: Importance.high,
      priority: Priority.high,
      actions: [
        AndroidNotificationAction(
          'snooze',
          'Через 10 минут',
          showsUserInterface: true,
        ),
      ],
    ),
    iOS: DarwinNotificationDetails(
      categoryIdentifier: 'calendar',
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    ),
    macOS: DarwinNotificationDetails(categoryIdentifier: 'calendar'),
    linux: LinuxNotificationDetails(
      actions: [
        LinuxNotificationAction(key: 'snooze', label: 'Через 10 минут'),
      ],
    ),
    windows: WindowsNotificationDetails(
      actions: [WindowsAction(content: 'Через 10 минут', arguments: 'snooze')],
    ),
  );
  Future<void> refresh() async {
    if (!initialized || _disposed) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final previousError = error, previousCount = scheduledCount;
    try {
      final pending = remindersFor(repo.snapshot, repo.now()).take(60).toList();
      final signature = pending
          .map((r) => '${r.key}:${r.title}:${r.body}:${r.at.toIso8601String()}')
          .join('|');
      if (signature == _signature) return;
      if ((platform == TargetPlatform.linux)) {
        _signature = signature;
        return;
      }
      final old = (await plugin.pendingNotificationRequests())
              .map((r) => r.id)
              .toSet(),
          ids = pending.map((r) => r.id).toSet();
      for (final id in old.difference(ids)) {
        if (id != testNotificationId) await plugin.cancel(id);
      }
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final exact = await android?.canScheduleExactNotifications() ?? true;
      for (final reminder in pending) {
        await plugin.zonedSchedule(
          reminder.id,
          reminder.title,
          reminder.body,
          tz.TZDateTime.from(reminder.at, tz.UTC),
          details,
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: reminder.taskId,
        );
      }
      _signature = signature;
      scheduledCount = pending.length;
      error = null;
    } catch (e) {
      error = 'Не удалось обновить напоминания: $e';
    } finally {
      _busy = false;
      if (error != previousError || scheduledCount != previousCount) {
        repo.publish();
      }
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> _linuxTick() async {
    if (_linuxBusy || _disposed) return;
    _linuxBusy = true;
    try {
      final now = repo.now();
      final due = remindersFor(
        repo.snapshot,
        now.subtract(const Duration(minutes: 15)),
      ).where((r) => !r.at.isAfter(now));
      for (final reminder in due) {
        if (!await repo.db.claimReminder(reminder.deliveryKey)) continue;
        try {
          await plugin.show(
            reminder.id,
            reminder.title,
            reminder.body,
            details,
            payload: reminder.taskId,
          );
        } catch (e) {
          await repo.db.releaseReminder(reminder.deliveryKey);
          rethrow;
        }
      }
    } catch (e) {
      error = 'Уведомление не доставлено: $e';
    } finally {
      _linuxBusy = false;
    }
  }

  Future<void> clearAndStop() async {
    dispose();
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (_busy || _linuxBusy) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Не удалось остановить уведомления. Повторите очистку.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (initialized) await plugin.cancelAll();
    scheduledCount = 0;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onOpenTask = null;
    pendingTaskId = null;
    repo.removeListener(changed);
    _debounce?.cancel();
    _linuxTimer?.cancel();
  }
}
