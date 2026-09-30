#!/bin/bash
# Builds MDReader.app into ./build. Requires only the Xcode Command Line Tools.
#   ./build.sh            release build (universal when full Xcode is installed)
#   ./build.sh --install  also copy to /Applications and link the `mdr` command
#   ./build.sh --release  also create build/MDReader-<version>.zip and .dmg for a release
# The version comes from $VERSION, else the latest git tag (v1.2.3), else 1.0.0.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$( (git describe --tags --abbrev=0 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/MDReader.app"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
echo "==> Compiling (universal)"
if ! swift build -c release "${ARCH_FLAGS[@]}" 2>/dev/null; then
  echo "    universal build unavailable, building for this Mac only"
  ARCH_FLAGS=()
  swift build -c release
fi
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MDReader" "$APP/Contents/MacOS/MDReader"
strip -x "$APP/Contents/MacOS/MDReader"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/mdr "$APP/Contents/Resources/mdr"
chmod +x "$APP/Contents/Resources/mdr"
cp -R Resources/web "$APP/Contents/Resources/web"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP v$VERSION ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/MDReader"))"

if [[ "${1:-}" == "--release" ]]; then
  ZIP="build/MDReader-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "==> $ZIP  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

  # Disk image with the usual "drag to Applications" layout.
  DMG="build/MDReader-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "MDReader $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "==> $DMG  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/MDReader.app
  cp -R "$APP" /Applications/
  # Register with Launch Services so "Open With" picks it up immediately.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MDReader.app
  echo "==> Installed to /Applications/MDReader.app"
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -w "$dir" ]]; then
      ln -sf /Applications/MDReader.app/Contents/Resources/mdr "$dir/mdr"
      echo "==> Linked $dir/mdr"
      break
    fi
  done
fi
