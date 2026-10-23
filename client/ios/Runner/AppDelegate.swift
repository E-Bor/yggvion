import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var iconChannel: FlutterMethodChannel?
  private var notificationSettingsChannel: FlutterMethodChannel?
  private var storagePolicyChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let storage = FlutterMethodChannel(name: "dev.yggvion/storage_policy",
                                         binaryMessenger: controller.binaryMessenger)
      storage.setMethodCallHandler { call, result in
        guard call.method == "excludePrivateDataFromBackup" else {
          result(FlutterMethodNotImplemented)
          return
        }
        do {
          // Mark the stable parent so SQLite's WAL/SHM files and new attachments
          // inherit the policy as well. Exported encrypted backups remain portable.
          var directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try directory.setResourceValues(values)
          guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true else {
            result(FlutterError(code: "backup_exclusion_failed",
                                message: "Не удалось защитить локальное хранилище от системного копирования.", details: nil))
            return
          }
          result(nil)
        } catch {
          result(FlutterError(code: "backup_exclusion_failed",
                              message: "Не удалось защитить локальное хранилище от системного копирования.", details: nil))
        }
      }
      storagePolicyChannel = storage
      let settings = FlutterMethodChannel(name: "dev.yggvion/notification_settings",
                                          binaryMessenger: controller.binaryMessenger)
      settings.setMethodCallHandler { call, result in
        guard call.method == "open" else { result(FlutterMethodNotImplemented); return }
        let address: String
        if #available(iOS 16.0, *) {
          address = UIApplication.openNotificationSettingsURLString
        } else {
          address = UIApplication.openSettingsURLString
        }
        guard let url = URL(string: address) else { result(false); return }
        application.open(url, options: [:]) { opened in result(opened) }
      }
      notificationSettingsChannel = settings
      let channel = FlutterMethodChannel(name: "dev.yggvion/app_icon",
                                         binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        guard call.method == "setAccent" else { result(FlutterMethodNotImplemented); return }
        guard let args = call.arguments as? [String: Any],
              let color = args["color"] as? NSNumber,
              color.uint64Value <= UInt64(UInt32.max),
              color.uint32Value >> 24 == 255 else {
          result(FlutterError(code: "invalid_color", message: "Expected opaque ARGB color", details: nil))
          return
        }
        let name: String? = color.uint32Value == 0xff9cb9ff
          ? nil : String(format: "Accent%06X", color.uint32Value & 0xffffff)
        guard application.supportsAlternateIcons else {
          result(FlutterError(code: "unsupported", message: "Alternate icons are unavailable", details: nil))
          return
        }
        if let name {
          let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
          let alternatives = icons?["CFBundleAlternateIcons"] as? [String: Any]
          guard alternatives?[name] != nil else {
            result(FlutterError(code: "unsupported_color", message: "Icon color is not bundled", details: nil))
            return
          }
        }
        if application.alternateIconName == name { result(nil); return }
        guard application.applicationState == .active else {
          result(FlutterError(code: "inactive", message: "App must be active", details: nil))
          return
        }
        application.setAlternateIconName(name) { error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "icon_update_failed", message: error.localizedDescription, details: nil))
            } else { result(nil) }
          }
        }
      }
      iconChannel = channel
    }
    return launched
  }
}
