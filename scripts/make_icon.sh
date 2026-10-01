#!/bin/bash
# Regenerates the app icon from scripts/make_icon.swift. Needs Xcode 26 or later (Icon Composer).
#   Resources/AppIcon.icon   the layered Icon Composer document (source)
#   Resources/Assets.car     compiled from it: the layered icon for macOS 26 and later, flat ones for 13–15
#   Resources/AppIcon.icns   the small flat sizes, also written by actool
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
# actool also writes the small sizes as an .icns; the catalog has the large ones for macOS 13–15,
# already on the older grid.
cp "$TMP/AppIcon.icns" Resources/AppIcon.icns

"$ICTOOL" "$PWD/Resources/AppIcon.icon" --export-image --output-file "$TMP/render.png" --platform macOS \
  --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
sips -Z 256 "$TMP/render.png" --out docs/icon-256.png >/dev/null
echo "Resources/AppIcon.icon, Assets.car, AppIcon.icns and docs/icon-256.png updated"
