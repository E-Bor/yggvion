// Run on macOS: swift tools/generate_branding.swift
// Renders the approved SVG into native icon sizes without third-party packages.
import AppKit
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let client = root.appendingPathComponent("client")
let branding = client.appendingPathComponent("assets/branding")
let palette: [(String, UInt32)] = [
  ("AppIcon", 0x9cb9ff), ("AccentB7A6E8", 0xb7a6e8),
  ("AccentD6B780", 0xd6b780), ("Accent8AC9B4", 0x8ac9b4),
  ("AccentDFA6BA", 0xdfa6ba), ("Accent8FC7CF", 0x8fc7cf),
  ("AccentD7A58D", 0xd7a58d), ("AccentA8B3C5", 0xa8b3c5),
]

func color(_ rgb: UInt32) -> CGColor {
  NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
          green: CGFloat((rgb >> 8) & 255) / 255,
          blue: CGFloat(rgb & 255) / 255, alpha: 1).cgColor
}

final class Source: NSObject, XMLParserDelegate {
  var paths: [(String, Bool)] = []
  var mirrors: [Bool] = []
  func parser(_ parser: XMLParser, didStartElement element: String,
              namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    let mirror = attributes["transform"] == "translate(256 0) scale(-1 1)"
    mirrors.append((mirrors.last ?? false) != mirror)
    if element == "path", let d = attributes["d"] { paths.append((d, mirrors.last!)) }
  }
  func parser(_ parser: XMLParser, didEndElement element: String,
              namespaceURI: String?, qualifiedName: String?) { mirrors.removeLast() }
}
let source = Source()
let parser = XMLParser(data: try Data(contentsOf: branding.appendingPathComponent("yggvion.svg")))
parser.delegate = source
guard parser.parse(), source.paths.count == 6 else { fatalError("Expected the approved Yggdrasil Shield SVG") }
let tokens = try NSRegularExpression(pattern: "[MLHVCQZ]|-?[0-9]+(?:\\.[0-9]+)?")
func path(_ d: String) -> CGPath {
  let input = d as NSString
  let values = tokens.matches(in: d, range: NSRange(location: 0, length: input.length))
    .map { input.substring(with: $0.range) }
  var i = 0
  var point = CGPoint.zero
  let output = CGMutablePath()
  func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(values[i])!) }
  while i < values.count {
    let command = values[i]; i += 1
    switch command {
    case "M": point = CGPoint(x: number(), y: number()); output.move(to: point)
    case "L": point = CGPoint(x: number(), y: number()); output.addLine(to: point)
    case "H": point.x = number(); output.addLine(to: point)
    case "V": point.y = number(); output.addLine(to: point)
    case "C":
      let first = CGPoint(x: number(), y: number())
      let second = CGPoint(x: number(), y: number())
      point = CGPoint(x: number(), y: number())
      output.addCurve(to: point, control1: first, control2: second)
    case "Q":
      let control = CGPoint(x: number(), y: number())
      point = CGPoint(x: number(), y: number())
      output.addQuadCurve(to: point, control: control)
    case "Z": output.closeSubpath(); point = output.currentPoint
    default: fatalError("Unsupported SVG command")
    }
  }
  return output
}
let paths = source.paths.map { (path($0.0), $0.1) }

func mark(_ ctx: CGContext, frame: CGRect, rgb: UInt32) {
  ctx.saveGState()
  ctx.translateBy(x: frame.minX, y: frame.minY)
  ctx.scaleBy(x: frame.width / 256, y: frame.height / 256)
  ctx.setFillColor(color(rgb))
  for (path, mirrored) in paths {
    ctx.saveGState()
    if mirrored { ctx.translateBy(x: 256, y: 0); ctx.scaleBy(x: -1, y: 1) }
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
  }
  ctx.restoreGState()
}

func background(_ ctx: CGContext, size: CGFloat, desktop: Bool) {
  let rect = CGRect(x: 0, y: 0, width: size, height: size)
    .insetBy(dx: desktop ? size * 0.08 : 0, dy: desktop ? size * 0.08 : 0)
  let shape = CGPath(roundedRect: rect, cornerWidth: desktop ? size * 0.19 : 0,
                     cornerHeight: desktop ? size * 0.19 : 0, transform: nil)
  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color(0x242b35), color(0x111419)] as CFArray,
                            locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY),
                         end: CGPoint(x: 0, y: rect.maxY), options: [])
  ctx.restoreGState()
  if desktop {
    ctx.setStrokeColor(color(0x303744))
    ctx.setLineWidth(size / 512)
    ctx.addPath(shape)
    ctx.strokePath()
  }
}

func png(size: Int, opaque: Bool = false, draw: (CGContext, CGFloat) -> Void) -> Data {
  let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: alpha.rawValue)!
  ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
  ctx.translateBy(x: 0, y: CGFloat(size))
  ctx.scaleBy(x: 1, y: -1)
  ctx.setShouldAntialias(true)
  draw(ctx, CGFloat(size))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
  precondition(CGImageDestinationFinalize(destination), "PNG export failed")
  return data as Data
}

func icon(size: Int, rgb: UInt32, desktop: Bool) -> Data {
  png(size: size, opaque: !desktop) { ctx, n in
    background(ctx, size: n, desktop: desktop)
    let inset = n * (desktop ? 0.08 : 0.03)
    mark(ctx, frame: CGRect(x: inset, y: inset, width: n-2*inset, height: n-2*inset),
         rgb: rgb)
  }
}
func write(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
}
func json(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
}

for name in ["logo-mask", "logo-mask-small"] {
  try write(png(size: 512) { ctx, n in
    mark(ctx, frame: CGRect(x: 0, y: 0, width: n, height: n), rgb: 0xffffff)
  }, to: branding.appendingPathComponent("\(name).png"))
}
try write(icon(size: 1024, rgb: palette[0].1, desktop: false), to: branding.appendingPathComponent("app-icon.png"))

let iosAssets = client.appendingPathComponent("ios/Runner/Assets.xcassets")
let originalManifest = try JSONSerialization.jsonObject(with:
  Data(contentsOf: iosAssets.appendingPathComponent("AppIcon.appiconset/Contents.json"))) as! [String: Any]
let entries = originalManifest["images"] as! [[String: String]]
for (name, rgb) in palette {
  let folder = iosAssets.appendingPathComponent("\(name).appiconset")
  for entry in entries {
    let size = Double(entry["size"]!.components(separatedBy: "x")[0])!
    let scale = Double(entry["scale"]!.dropLast())!
    try write(icon(size: Int(size * scale), rgb: rgb, desktop: false),
              to: folder.appendingPathComponent(entry["filename"]!))
  }
  if name != "AppIcon" { try write(json(originalManifest), to: folder.appendingPathComponent("Contents.json")) }
}

let macAssets = client.appendingPathComponent("macos/Runner/Assets.xcassets")
for size in [16,32,64,128,256,512,1024] {
  try write(icon(size: size, rgb: palette[0].1, desktop: true),
            to: macAssets.appendingPathComponent("AppIcon.appiconset/app_icon_\(size).png"))
}
for name in ["AppIconBackground", "AppIconMark"] {
  let data = png(size: 1024) { ctx, n in
    if name == "AppIconBackground" { background(ctx, size: n, desktop: true) }
    else { mark(ctx, frame: CGRect(x: n*0.08, y: n*0.08, width: n*0.84, height: n*0.84), rgb: 0xffffff) }
  }
  let folder = macAssets.appendingPathComponent("\(name).imageset")
  try write(data, to: folder.appendingPathComponent("\(name).png"))
  try write(json(["images": [["idiom": "universal", "filename": "\(name).png"]],
                  "info": ["version": 1, "author": "xcode"]]), to: folder.appendingPathComponent("Contents.json"))
}

for (density, size) in [("mdpi",48), ("hdpi",72), ("xhdpi",96), ("xxhdpi",144), ("xxxhdpi",192)] {
  try write(icon(size: size, rgb: palette[0].1, desktop: false),
    to: client.appendingPathComponent("android/app/src/main/res/mipmap-\(density)/ic_launcher.png"))
}
// Adaptive and notification vectors use the same SVG geometry.
let vectorPaths = source.paths.map { d, mirrored in
  let p = "<path android:fillColor=\"#FF9CB9FF\" android:pathData=\"\(d)\"/>"
  return mirrored ? "<group android:pivotX=\"128\" android:scaleX=\"-1\">\(p)</group>" : p
}.joined(separator: "\n")
let foreground = """
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="256" android:viewportHeight="256">
  <group android:pivotX="128" android:pivotY="128" android:scaleX="0.66" android:scaleY="0.66">
    \(vectorPaths)
  </group>
</vector>
"""
try write(Data(foreground.utf8), to: client.appendingPathComponent("android/app/src/main/res/drawable/ic_launcher_foreground.xml"))
let notification = "<vector xmlns:android=\"http://schemas.android.com/apk/res/android\" android:width=\"24dp\" android:height=\"24dp\" android:viewportWidth=\"256\" android:viewportHeight=\"256\">\(vectorPaths)</vector>"
  .replacingOccurrences(of: "#FF9CB9FF", with: "#FFFFFFFF")
try write(Data(notification.utf8), to: client.appendingPathComponent("android/app/src/main/res/drawable/ic_notification.xml"))

// PNG-backed ICO entries are supported by current Windows versions.
extension Data {
  mutating func le<T: FixedWidthInteger>(_ value: T) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
  }
}
let sizes = [16,24,32,48,64,128,256]
let images = sizes.map { icon(size: $0, rgb: palette[0].1, desktop: true) }
var ico = Data(); ico.le(UInt16(0)); ico.le(UInt16(1)); ico.le(UInt16(sizes.count))
var offset = 6 + sizes.count * 16
for (size, data) in zip(sizes, images) {
  ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
  ico.le(UInt16(1)); ico.le(UInt16(32)); ico.le(UInt32(data.count)); ico.le(UInt32(offset))
  offset += data.count
}
for data in images { ico.append(data) }
try write(ico, to: client.appendingPathComponent("windows/runner/resources/app_icon.ico"))
try write(icon(size: 256, rgb: palette[0].1, desktop: true),
          to: client.appendingPathComponent("linux/runner/yggvion.png"))
print("Generated Yggdrasil Shield icons for iOS (8 accents), macOS, Android, Windows and Linux")
