#!/bin/bash
# Regenerates the app icon from scripts/make_icon.swift. Needs Xcode 26 or later (Icon Composer).
#   Resources/AppIcon.icon   the layered Icon Composer document (source)
#   Resources/Assets.car     compiled from it; macOS 26 and later draw the icon from this
#   Resources/AppIcon.icns   flat icon for macOS 13–15
#   docs/icon-256.png        for the README
# The compiled files are committed so that building the app doesn't need Icon Composer.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || { echo "error: Icon Composer not found (Xcode 26 or later)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf Resources/AppIcon.icon
swift scripts/make_icon.swift Resources/AppIcon.icon

# Absolute path: actool's helper process resolves relative ones against its own folder, which
# can be another project's.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$TMP" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 13.0 --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" Resources/Assets.car

# The flat icon: Icon Composer's render, scaled onto the older grid (an 824pt body in a 1024pt
# canvas) so it matches the size of other icons on macOS 13–15.
"$ICTOOL" "$PWD/Resources/AppIcon.icon" --export-image --output-file "$TMP/render.png" --platform macOS \
  --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
cat > "$TMP/fit.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let side = 1024 * 0.845
source.draw(in: NSRect(x: (1024 - side) / 2, y: (1024 - side) / 2, width: side, height: side))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$TMP/fit.swift" "$TMP/render.png" "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

sips -Z 256 "$TMP/render.png" --out docs/icon-256.png >/dev/null
echo "Resources/AppIcon.icon, Assets.car, AppIcon.icns and docs/icon-256.png updated"
