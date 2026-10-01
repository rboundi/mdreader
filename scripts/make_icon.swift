// Writes the layers of the MDReader icon as an Icon Composer document (AppIcon.icon).
// Usage: swift scripts/make_icon.swift <path/to/AppIcon.icon>
//
// The icon follows Apple's layered format: a full 1024×1024 canvas with no mask, shadow or
// highlight drawn in. The system adds the shape, the glass and the dark, clear and tinted versions.
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icon")
let assets = out.appendingPathComponent("Assets")
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(body)
    </svg>

    """
}

func write(_ name: String, _ body: String) {
    try! svg(body).write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// The sheet of paper, centred on the canvas.
let sheet = (x: 246.0, y: 166.0, width: 532.0, height: 692.0, radius: 38.0)
func page(fill: String, angle: Double) -> String {
    let rotate = angle == 0 ? "" : " transform=\"rotate(\(angle) 512 512)\""
    return "<rect x=\"\(sheet.x)\" y=\"\(sheet.y)\" width=\"\(sheet.width)\" height=\"\(sheet.height)\" "
        + "rx=\"\(sheet.radius)\" fill=\"\(fill)\"\(rotate)/>"
}

// Three sheets, the back two fanned out behind the front one.
write("page-back.svg", page(fill: "#C7D8FF", angle: 10))
write("page-middle.svg", page(fill: "#E6EEFF", angle: 4))
write("page-front.svg", page(fill: "#FFFFFF", angle: 0))

// ".md" as outlines (Icon Composer doesn't take live text), in SF Rounded Heavy.
func outline(_ text: String, size: CGFloat, x: CGFloat, baseline: CGFloat, kern: CGFloat) -> String {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font, .kern: kern]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for (glyph, position) in zip(glyphs, positions) {
            guard let letter = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
            // Glyphs are y-up; SVG is y-down.
            let place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + position.x, ty: baseline - position.y)
            path.addPath(letter, transform: place)
        }
    }
    var d = ""
    let f = { (v: CGFloat) in String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint:
            d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

let left = sheet.x + 66
var label = "<path fill=\"#1E5BD6\" d=\"\(outline(".md", size: 176, x: left, baseline: 412, kern: -5))\"/>\n"
// Lines of text under the label.
for (i, width) in [400.0, 330.0, 376.0, 236.0].enumerated() {
    label += "<rect x=\"\(left)\" y=\"\(496 + Double(i) * 66)\" width=\"\(width)\" height=\"26\" rx=\"13\" fill=\"#A9C2F2\"/>\n"
}
write("label.svg", label)

// Groups are listed front to back. The paper is opaque; the label sits flat on it.
let document = """
{
  "fill-specializations" : [
    {
      "value" : {
        "automatic-gradient" : "srgb:0.20000,0.47000,0.94000,1.00000"
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "automatic-gradient" : "srgb:0.09000,0.24000,0.60000,1.00000"
      }
    }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "label.svg",
          "name" : "label"
        }
      ],
      "shadow" : {
        "kind" : "none",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "image-name" : "page-front.svg",
          "name" : "page-front"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "image-name" : "page-middle.svg",
          "name" : "page-middle"
        },
        {
          "image-name" : "page-back.svg",
          "name" : "page-back"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
try! document.write(to: out.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("wrote \(out.path)")
