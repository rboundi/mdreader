// Draws the MDReader app icon at 1024×1024 and writes it as a PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    draw()
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (Apple icon grid: 824pt body, 100pt margin), blue gradient.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
withShadow(color(0x000000, 0.28), blur: 28, y: -12) {
    color(0x1E5BD6).setFill()
    squircle.fill()
}
ctx.saveGState()
squircle.addClip()
NSGradient(colors: [color(0x5AA9FF), color(0x1E5BD6)])!.draw(in: body, angle: -90)
ctx.restoreGState()

// Three stacked sheets, fanned slightly.
let sheet = NSRect(x: 282, y: 210, width: 460, height: 600)
for (angle, fill) in [(-10.0, 0xC7D8FF), (-4.0, 0xE6EEFF), (0.0, 0xFFFFFF)] as [(CGFloat, UInt32)] {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: angle * .pi / 180)
    ctx.translateBy(x: -512, y: -512)
    withShadow(color(0x0A2A6B, 0.35), blur: 30, y: -10) {
        color(fill).setFill()
        NSBezierPath(roundedRect: sheet, xRadius: 30, yRadius: 30).fill()
    }
    ctx.restoreGState()
}

// ".md" label.
let font = NSFont.systemFont(ofSize: 150, weight: .heavy)
let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 150) ?? font
let label = NSAttributedString(
    string: ".md", attributes: [.font: rounded, .foregroundColor: color(0x1E5BD6), .kern: -4])
let labelSize = label.size()
label.draw(at: NSPoint(x: sheet.minX + 58, y: 612 - labelSize.height / 2))

// Text lines.
for (i, width) in [340.0, 280.0, 320.0, 200.0].enumerated() {
    color(0xA9C2F2).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: sheet.minX + 60, y: 480 - CGFloat(i) * 56, width: CGFloat(width), height: 22),
        xRadius: 11, yRadius: 11
    ).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
