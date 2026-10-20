import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var iconChannel: FlutterMethodChannel?
  private var hardwareChannel: FlutterMethodChannel?
  private var aiBackgroundChannel: FlutterMethodChannel?
  private var aiBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let background = FlutterMethodChannel(
        name: "dev.yggvion/ai_background", binaryMessenger: controller.binaryMessenger)
      background.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(nil); return }
        switch call.method {
        case "begin":
          if self.aiBackgroundTask == .invalid {
            self.aiBackgroundTask = application.beginBackgroundTask(
              withName: "Voice message transcription"
            ) { [weak self] in
              // Audio and queue state have already been saved by Flutter.
              // iOS may suspend us; processing resumes on the next launch.
              guard let self, self.aiBackgroundTask != .invalid else { return }
              application.endBackgroundTask(self.aiBackgroundTask)
              self.aiBackgroundTask = .invalid
            }
          }
          result(nil)
        case "end":
          if self.aiBackgroundTask != .invalid {
            application.endBackgroundTask(self.aiBackgroundTask)
            self.aiBackgroundTask = .invalid
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      aiBackgroundChannel = background
      let hardware = FlutterMethodChannel(name: "dev.yggvion/hardware", binaryMessenger: controller.binaryMessenger)
      hardware.setMethodCallHandler { call, result in
        guard call.method == "info" else { result(FlutterMethodNotImplemented); return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        result(["memory_bytes": ProcessInfo.processInfo.physicalMemory,
                "free_bytes": values?.volumeAvailableCapacityForImportantUsage ?? 0,
                "name": UIDevice.current.model])
      }
      hardwareChannel = hardware
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
