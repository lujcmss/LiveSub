// Draws the LiveSub app icon and writes Resources/AppIcon.icns.
// Run with: swift scripts/make-icon.swift [variant] [output.png]
// The idea: sound (a waveform) becoming subtitles in two languages (a small warm line for the
// original, a larger white line for the translation).
import AppKit

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "a"
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon shape: a rounded square inset from the canvas, with a soft drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x1A1C3A).setFill()
    shape.fill()
    ctx.restoreGState()

    // Background: deep night-sky gradient with a warm glow low down, like a screen in a dark room.
    ctx.saveGState()
    shape.addClip()
    let top: UInt32 = variant == "b" ? 0x0E2A47 : 0x16183A
    let bottom: UInt32 = variant == "b" ? 0x145C6B : 0x3B2A7A
    NSGradient(colors: [color(bottom), color(top)])!.draw(in: tile, angle: 90)
    let glow = NSGradient(colors: [color(variant == "b" ? 0x35D0BA : 0x8C6BFF, 0.55), color(0x000000, 0)])!
    glow.draw(fromCenter: NSPoint(x: 512, y: 250), radius: 0, toCenter: NSPoint(x: 512, y: 250), radius: 520, options: [])

    // Waveform: rounded bars, tallest in the middle.
    let heights: [CGFloat] = [120, 230, 330, 190, 290, 150, 80]
    let barWidth: CGFloat = 52, gap: CGFloat = 34
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    let centerY: CGFloat = 640
    for (i, h) in heights.enumerated() {
        let rect = NSRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
        let t = CGFloat(i) / CGFloat(heights.count - 1)
        let c1 = variant == "b" ? color(0x7CF5E1) : color(0x9FD8FF)
        let c2 = variant == "b" ? color(0xE9FFF9) : color(0xE7D9FF)
        let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        ctx.saveGState()
        bar.addClip()
        NSGradient(colors: [c1.blended(withFraction: t, of: c2)!, NSColor.white])!.draw(in: rect, angle: 90)
        ctx.restoreGState()
        x += barWidth + gap
    }

    // Subtitles: a short warm line (the original) above a longer white line (the translation).
    func pill(_ rect: NSRect, _ fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
    if variant == "c" {
        // Variant c: the lines sit inside a translucent caption box.
        color(0x000000, 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: 196, y: 196, width: 632, height: 236), xRadius: 56, yRadius: 56).fill()
    }
    pill(NSRect(x: 332, y: 352, width: 360, height: 40), color(0xFFD978))
    pill(NSRect(x: 252, y: 244, width: 520, height: 66), .white)

    // A faint top highlight gives the tile some depth.
    NSGradient(colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.14)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: 90)
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep = draw()
let png = rep.representation(using: .png, properties: [:])!
if CommandLine.arguments.count > 2 {
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

// Build the .icns from the 1024 px master.
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("LiveSub-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try! png.write(to: master)
func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512)] {
    run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent("\(name).png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"])
try? fm.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
