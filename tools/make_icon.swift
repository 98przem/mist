// Renders Mist's app icon (a purple→blue squircle with a white fog/cloud glyph,
// matching the in-app brand) to a 1024px PNG, then builds Mist.icns via iconutil.
// Run: swift tools/make_icon.swift   (writes Mist.icns in the repo root)
import AppKit

let px = 1024
let size = NSSize(width: px, height: px)
let img = NSImage(size: size)
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with a diagonal purple→blue gradient.
let inset: CGFloat = 84                          // macOS icon safe-area padding
let rect = CGRect(x: inset, y: inset, width: CGFloat(px) - inset*2, height: CGFloat(px) - inset*2)
let radius = rect.width * 0.235
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1).cgColor,   // purple
              NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor]   // blue
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
ctx.restoreGState()

// Subtle top highlight for depth.
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(white: 1, alpha: 0.18).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

// White fog/cloud glyph (SF Symbol), centered, with a soft shadow.
let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .semibold)
if let sym = NSImage(systemSymbolName: "cloud.fog.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = sym.size
    let gx = rect.midX - s.width/2, gy = rect.midY - s.height/2
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(white: 0, alpha: 0.22).cgColor)
    NSColor.white.set()
    let tinted = NSImage(size: s); tinted.lockFocus()
    sym.draw(at: .zero, from: CGRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    CGRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(at: CGPoint(x: gx, y: gy), from: CGRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
}
img.unlockFocus()

// Write the master 1024 PNG.
guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
      let png = bmp.representation(using: .png, properties: [:]) else { fatalError("png") }
let iconset = "/tmp/Mist.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "/tmp/mist_icon_1024.png"))

// Resize into the iconset sizes iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, dim) in variants {
    let out = NSImage(size: NSSize(width: dim, height: dim))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: CGRect(x: 0, y: 0, width: dim, height: dim))
    out.unlockFocus()
    let t = out.tiffRepresentation!, b = NSBitmapImageRep(data: t)!
    try! b.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Mist.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ wrote Mist.icns" : "iconutil failed")
