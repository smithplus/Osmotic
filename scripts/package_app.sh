#!/usr/bin/env bash
# Build Osmotic and wrap it into build/Osmotic.app (ad-hoc signed).
#   scripts/package_app.sh            release build
#   scripts/package_app.sh debug      debug build
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_DIR="$ROOT_DIR/build/Osmotic.app"

swift build --package-path "$ROOT_DIR" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c "$CONFIG" --show-bin-path)"

if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  swift "$ROOT_DIR/scripts/make_icon.swift" "$ROOT_DIR"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN_DIR/Osmotic" "$APP_DIR/Contents/MacOS/Osmotic"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# Localizations: the String Catalog compiles to <lang>.lproj/Localizable.strings(dict); per-language
# Info.plist strings (permission prompts) are copied as they are.
xcrun xcstringstool compile "$ROOT_DIR/Resources/Localizable.xcstrings" --output-directory "$APP_DIR/Contents/Resources"
for lproj in "$ROOT_DIR"/Resources/*.lproj; do
  mkdir -p "$APP_DIR/Contents/Resources/$(basename "$lproj")"
  cp "$lproj"/* "$APP_DIR/Contents/Resources/$(basename "$lproj")/"
done
mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
chmod +x "$APP_DIR/Contents/MacOS/Osmotic"

codesign --force --sign - --identifier io.github.smithplus.osmotic "$APP_DIR"
echo "$APP_DIR"
