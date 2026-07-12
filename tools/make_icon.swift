// Renders Mist's app icon — a dark Foglight squircle lit by a periwinkle glow,
// matching the in-app brand (same radial gradient as the sidebar mark) — to a
// 1024px PNG, then builds Mist.icns via iconutil.
// Run: swift tools/make_icon.swift   (writes Mist.icns in the repo root)
import AppKit

let px = 1024
let size = NSSize(width: px, height: px)
let img = NSImage(size: size)
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 84                          // macOS icon safe-area padding
let rect = CGRect(x: inset, y: inset, width: CGFloat(px) - inset*2, height: CGFloat(px) - inset*2)
let radius = rect.width * 0.235
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Outer halo — a real bloom that bleeds past the squircle's edges, visible as a
// soft blue glow against any Dock background (light or dark), the way the app's
// own accent color glows behind the sidebar mark and running-state pulse.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 130, color: NSColor(calibratedRed: 0.49, green: 0.61, blue: 1.0, alpha: 0.7).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.06, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Squircle fill: dark Foglight ground (near the app's own bg/haze tones) — NOT
// flooded with the bright accent, so it stays moody up close and lets the glow
// (outer halo + inner bloom below) read as light against dark, not just "blue".
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let ground = [
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1).cgColor,   // Fog.haze
    NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor,   // Fog.bg
]
let groundGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: ground as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(groundGrad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Inner bloom: a soft periwinkle light source behind the cloud, like the
// sidebar mark's radial fill but as an accent glow ON the dark ground rather
// than a flat fill covering it.
let bloom = [
    NSColor(calibratedRed: 0.55, green: 0.65, blue: 1.00, alpha: 0.95).cgColor,
    NSColor(calibratedRed: 0.49, green: 0.61, blue: 1.00, alpha: 0.55).cgColor,
    NSColor(calibratedRed: 0.49, green: 0.61, blue: 1.00, alpha: 0).cgColor,
]
let bloomGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bloom as CFArray,
                           locations: [0, 0.45, 1])!
let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.06)
ctx.drawRadialGradient(bloomGrad, startCenter: center, startRadius: 0,
                       endCenter: center, endRadius: rect.width * 0.62, options: [])
ctx.restoreGState()

// Subtle top highlight for depth.
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
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
    // A soft periwinkle glow under the glyph (not a black shadow, which would be
    // invisible on the dark ground) so the cloud reads as lit from the bloom.
    ctx.setShadow(offset: .zero, blur: 30, color: NSColor(calibratedRed: 0.55, green: 0.65, blue: 1.0, alpha: 0.6).cgColor)
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
