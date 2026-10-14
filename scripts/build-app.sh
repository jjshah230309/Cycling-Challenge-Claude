#!/usr/bin/env bash
# Builds Breakaway.app (ad-hoc signed) into ./build.
#
#   scripts/build-app.sh            # release build for this Mac's architecture
#   scripts/build-app.sh --universal  # Apple silicon + Intel
set -euo pipefail
cd "$(dirname "$0")/.."

# (macOS ships bash 3.2, where "${arr[@]}" on an empty array trips `set -u`.)
ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling (release)…"
swift build -c release --product Breakaway ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR=$(swift build -c release --product Breakaway ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)

APP=build/Breakaway.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Breakaway" "$APP/Contents/MacOS/Breakaway"
cp Sources/Breakaway/Info.plist "$APP/Contents/Info.plist"
# Satellite imagery draped over each route's terrain.
cp -R Sources/Breakaway/Resources/Imagery "$APP/Contents/Resources/Imagery"

echo "▸ Drawing app icon…"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
if swift scripts/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "  (icon generation skipped)"
fi

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it with: open $APP"
