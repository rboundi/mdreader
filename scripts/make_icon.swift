// Draws the MDReader app icon at 1024×1024 and writes it as a PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (Apple icon grid: 824pt body, 100pt margin).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
let drop = NSShadow()
drop.shadowColor = color(0x000000, 0.28)
drop.shadowBlurRadius = 28
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
color(0x2B2F77).setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
NSGradient(colors: [color(0x6D5CF6), color(0x3B4BD8), color(0x23287A)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)
// Soft highlight in the top-left.
NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
    .draw(fromCenter: NSPoint(x: 330, y: 860), radius: 0, toCenter: NSPoint(x: 330, y: 860),
          radius: 560, options: [])
ctx.restoreGState()

// Paper sheet with a folded corner.
let paper = NSRect(x: 262, y: 196, width: 500, height: 640)
let fold: CGFloat = 120
let sheet = NSBezierPath()
sheet.move(to: NSPoint(x: paper.minX + 36, y: paper.minY))
sheet.line(to: NSPoint(x: paper.maxX - 36, y: paper.minY))
sheet.curve(to: NSPoint(x: paper.maxX, y: paper.minY + 36),
            controlPoint1: NSPoint(x: paper.maxX - 16, y: paper.minY),
            controlPoint2: NSPoint(x: paper.maxX, y: paper.minY + 16))
sheet.line(to: NSPoint(x: paper.maxX, y: paper.maxY - fold))
sheet.line(to: NSPoint(x: paper.maxX - fold, y: paper.maxY))
sheet.line(to: NSPoint(x: paper.minX + 36, y: paper.maxY))
sheet.curve(to: NSPoint(x: paper.minX, y: paper.maxY - 36),
            controlPoint1: NSPoint(x: paper.minX + 16, y: paper.maxY),
            controlPoint2: NSPoint(x: paper.minX, y: paper.maxY - 16))
sheet.line(to: NSPoint(x: paper.minX, y: paper.minY + 36))
sheet.curve(to: NSPoint(x: paper.minX + 36, y: paper.minY),
            controlPoint1: NSPoint(x: paper.minX, y: paper.minY + 16),
            controlPoint2: NSPoint(x: paper.minX + 16, y: paper.minY))
sheet.close()

ctx.saveGState()
let paperShadow = NSShadow()
paperShadow.shadowColor = color(0x0B0D3A, 0.45)
paperShadow.shadowBlurRadius = 40
paperShadow.shadowOffset = NSSize(width: 0, height: -18)
paperShadow.set()
color(0xFFFFFF).setFill()
sheet.fill()
ctx.restoreGState()

ctx.saveGState()
sheet.addClip()
NSGradient(colors: [color(0xFFFFFF), color(0xECEEFA)])!.draw(in: paper, angle: -90)
ctx.restoreGState()

// The folded flap.
let flap = NSBezierPath()
flap.move(to: NSPoint(x: paper.maxX - fold, y: paper.maxY))
flap.line(to: NSPoint(x: paper.maxX - fold + 10, y: paper.maxY - fold + 26))
flap.curve(to: NSPoint(x: paper.maxX - fold + 26, y: paper.maxY - fold + 10),
           controlPoint1: NSPoint(x: paper.maxX - fold + 12, y: paper.maxY - fold + 14),
           controlPoint2: NSPoint(x: paper.maxX - fold + 14, y: paper.maxY - fold + 12))
flap.line(to: NSPoint(x: paper.maxX, y: paper.maxY - fold))
flap.close()
color(0xC9CDEE).setFill()
flap.fill()

// Markdown mark: "M" and a down arrow.
let ink = color(0x2E3192)
let markRect = NSRect(x: paper.minX + 58, y: 520, width: 384, height: 200)
let markBox = NSBezierPath(roundedRect: markRect, xRadius: 34, yRadius: 34)
markBox.lineWidth = 26
ink.setStroke()
markBox.stroke()

let m = NSBezierPath()
m.lineWidth = 34
m.lineCapStyle = .round
m.lineJoinStyle = .round
let mx = markRect.minX + 56, my = markRect.minY + 50, mh: CGFloat = 100, mw: CGFloat = 150
m.move(to: NSPoint(x: mx, y: my))
m.line(to: NSPoint(x: mx, y: my + mh))
m.line(to: NSPoint(x: mx + mw / 2, y: my + mh * 0.38))
m.line(to: NSPoint(x: mx + mw, y: my + mh))
m.line(to: NSPoint(x: mx + mw, y: my))
m.stroke()

let ax = markRect.maxX - 82
let arrow = NSBezierPath()
arrow.lineWidth = 34
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: ax, y: my + mh))
arrow.line(to: NSPoint(x: ax, y: my + 4))
arrow.move(to: NSPoint(x: ax - 44, y: my + 48))
arrow.line(to: NSPoint(x: ax, y: my + 4))
arrow.line(to: NSPoint(x: ax + 44, y: my + 48))
arrow.stroke()

// Text lines.
let lineColor = color(0x9AA0D6)
for (i, width) in [360.0, 300.0, 340.0, 220.0].enumerated() {
    let y = 430 - CGFloat(i) * 58
    lineColor.withAlphaComponent(i == 0 ? 0.9 : 0.6).setFill()
    NSBezierPath(roundedRect: NSRect(x: paper.minX + 58, y: y, width: CGFloat(width), height: 24),
                 xRadius: 12, yRadius: 12).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
