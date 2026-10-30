# Notifications and platform behavior

[Documentation](README.md) · [Features](features.md) · [Building](building.md)

Yggvion targets Android, iOS, macOS, Windows and Linux. Native permissions, background execution and signing differ between platforms. Widget tests verify application logic, not operating-system delivery guarantees.

## Reminders

Each device schedules reminders from data it has **already synchronized**. The next 60 reminders are registered with the operating system in advance and do not need a VPS connection when they fire. Opening the app, editing data and resuming from the background refresh the schedule.

The initial permission prompt is requested once per device. **Settings → Notifications on this device** shows permission state, the number of scheduled reminders and errors. **Test notification** schedules a notification ten seconds later.

**Allow notifications** opens Yggvion's system notification settings on iOS, Android and macOS; on Windows it opens notification settings, and on Linux it opens GNOME/KDE settings if available. Returning to the application refreshes permission state. iOS can display notifications while the application is open. Android requests exact-alarm permission separately and falls back to inexact scheduling when that permission is unavailable.

A task created elsewhere after this device's app has closed cannot enter its local reminder schedule until synchronization runs again. This version does not use APNs/FCM to deliver changes to suspended or closed mobile clients. Do Not Disturb, battery policies and user permissions can delay or suppress notifications.

Infinite recurring series cannot be fully registered with the OS. Ordinary occurrences are prepared for 90 days ahead and expanded further when their dates are viewed. Birthdays are expanded for the current year and the following two years, plus viewed dates. They use existing series/tasks/blocks with optional `birthday_date`, `birthday_year` and `reminder_at` fields. Keep clients and the Linux reminder companion up to date; the VPS is not upgraded automatically.

## Lock-screen time tracking

The tracking surface displays the task, elapsed/estimated time, progress and timer controls. Once elapsed time exceeds the estimate, red grows from the right while blue represents the planned share of total elapsed time. The red follows the calendar's overrun color.

### iOS

The lock-screen banner uses **ActivityKit and WidgetKit**, with the `TrackingWidget` extension embedded in Runner. It requires the same development team as the containing app. There is no APNs or App Groups dependency. The app supports iOS 16.4 and later; in-banner actions require iOS 17, while tapping on iOS 16.4 opens the app. Live Activities must be enabled in system settings.

The OS advances the timer without a constantly running Flutter process. One Live Activity can remain active for up to eight hours; application time tracking continues afterward. The overrun bar uses a piecewise system-progress approximation while running and is accurate on pause. Native pause/stop commands remain queued until acknowledged in local SQLite, retain their original press time and are deduplicated on replay. Stopping a timer does not complete the task.

Changes from another device refresh the banner after the iPhone next synchronizes. A locked, suspended iPhone may therefore display an old task until the app opens again. The displayed counter does not independently create or extend tracked intervals. If a start was already synchronized, switching tasks elsewhere closes the prior interval at that switch time, and the phone later receives the same record. Independently started offline timers follow the normal overlap/conflict reconciliation rules.

### Android

Tracking uses a `specialUse` foreground service only while the timer is running. A native chronometer updates seconds; the service updates progress roughly once per minute without networking or a wake lock. Pausing stops the service and keeps the notification. Lock-screen visibility depends on the user's notification permissions and privacy settings.

Google Play distribution requires declaring the `specialUse` foreground-service purpose. Native timer actions are persisted and replayed with the same acknowledgement/deduplication behavior as on iOS.

## macOS notification icons

Notifications use `AppIcon` from the built app and retain the primary blue icon. Changing the in-app/Dock accent does not dynamically recolor the system notification icon.

Startup registers the current app bundle with Launch Services, which matters with `flutter run` or multiple old builds sharing a bundle ID. After updating, check a **new** test notification: old delivered notifications can retain a cached image. A reboot is not a substitute for checking the current built bundle and a newly scheduled notification.

## Linux reminder companion

When the Flutter client is fully closed, an optional local user service can schedule notifications. It reads the same local SQLite database, coordinates delivery markers with the client and writes snooze operations into the local outbox. It works offline in an active graphical session and requires `notify-send` from libnotify.

After launching the client at least once, build and install the companion from the repository root:

```sh
cd server
go build -o yggvion-reminders ./cmd/reminders
install -Dm755 yggvion-reminders "$HOME/.local/bin/yggvion-reminders"
cd ..
install -Dm644 deploy/yggvion-reminders.service "$HOME/.config/systemd/user/yggvion-reminders.service"
```

Check the executable/database paths in the installed unit before enabling it:

```sh
systemctl --user daemon-reload
systemctl --user enable --now yggvion-reminders.service
```

This service is installed manually, not by the VPS installer. Rebuild it when upgrading to a client/database contract that needs new reminder fields.

## Native validation

Use the [manual checks](testing.md) for logic and a simulator/emulator or dedicated test environment for native behavior. Physical devices are not required for Flutter widget tests. Do not deploy diagnostic builds to the owner's phone without a separate explicit request; that device is reserved for manual UX testing.

Windows/Linux binaries need their own native build hosts. App store signing, production OAuth access, actual background notification delivery and provider firewalls require separate release validation. A passing unit/widget suite alone does not certify them.
