import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var iconChannel: FlutterMethodChannel?
  private var notificationSettingsChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y, width: 1380, height: 900), display: true)
    self.minSize = NSSize(width: 760, height: 600)
    self.title = "Yggvion"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let settings = FlutterMethodChannel(name: "dev.yggvion/notification_settings",
                                        binaryMessenger: flutterViewController.engine.binaryMessenger)
    settings.setMethodCallHandler { call, result in
      guard call.method == "open" else { result(FlutterMethodNotImplemented); return }
      let pane: String
      if #available(macOS 13.0, *) {
        pane = "com.apple.Notifications-Settings.extension"
      } else {
        pane = "com.apple.preference.notifications"
      }
      guard let url = URL(string: "x-apple.systempreferences:\(pane)?id=dev.yggvion.yggvion") else {
        result(false); return
      }
      result(NSWorkspace.shared.open(url))
    }
    notificationSettingsChannel = settings

    let channel = FlutterMethodChannel(name: "dev.yggvion/app_icon",
                                       binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "setAccent" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: Any],
            let color = args["color"] as? NSNumber,
            color.uint64Value <= UInt64(UInt32.max),
            color.uint32Value >> 24 == 255 else {
        result(FlutterError(code: "invalid_color", message: "Expected opaque ARGB color", details: nil))
        return
      }
      guard let background = NSImage(named: "AppIconBackground"),
            let mask = NSImage(named: "AppIconMark") else {
        result(FlutterError(code: "missing_asset", message: "Icon artwork is missing", details: nil))
        return
      }
      let rgb = color.uint32Value
      let accent = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
      let tinted = NSImage(size: mask.size, flipped: false) { rect in
        accent.setFill()
        rect.fill()
        mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        return true
      }
      let icon = NSImage(size: background.size, flipped: false) { rect in
        background.draw(in: rect)
        tinted.draw(in: rect)
        return true
      }
      NSApplication.shared.applicationIconImage = icon
      result(nil)
    }
    iconChannel = channel

    super.awakeFromNib()
  }
}
