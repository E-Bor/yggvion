import Cocoa
import FlutterMacOS
import CoreServices

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // `flutter run` executes the binary directly. Register this actual bundle
    // so Notification Center resolves its icon, not a deleted development copy.
    let status = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    if status != noErr {
      NSLog("Yggvion: application registration failed (%d)", status)
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
