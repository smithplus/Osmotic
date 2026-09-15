#!/usr/bin/env bash
# Build Osmotic and wrap it into build/Osmotic.app.
#   scripts/package_app.sh            release build, universal (Apple silicon + Intel)
#   scripts/package_app.sh debug      debug build, this Mac's architecture only (fast)
# Signing: ad-hoc by default. For a release, set SIGN_IDENTITY to a Developer ID, e.g.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package_app.sh
# and then run scripts/notarize.sh. Ad-hoc builds re-ask every permission after each rebuild
# (macOS can't tie the grants to a stable identity); Developer ID builds don't.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_DIR="$ROOT_DIR/build/Osmotic.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ARCH_FLAGS=()
if [ "$CONFIG" = "release" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build --package-path "$ROOT_DIR" -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  swift "$ROOT_DIR/scripts/make_icon.swift" "$ROOT_DIR"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN_DIR/Osmotic" "$APP_DIR/Contents/MacOS/Osmotic"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# License notices travel with the binary (MIT: Osmosis, Kaze for DJI); Credits.rtf shows in About.
cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
cp "$ROOT_DIR/Resources/Credits.rtf" "$APP_DIR/Contents/Resources/Credits.rtf"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"

# Version: the latest tag (v1.2.3 → 1.2.3) if there is one, else Info.plist's; build number = commit count,
# so every build from a newer commit is a higher CFBundleVersion.
PLIST="$APP_DIR/Contents/Info.plist"
if TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$PLIST"
fi
if BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
fi

# Localizations: the String Catalog compiles to <lang>.lproj/Localizable.strings(dict); per-language
# Info.plist strings (permission prompts) are copied as they are.
xcrun xcstringstool compile "$ROOT_DIR/Resources/Localizable.xcstrings" --output-directory "$APP_DIR/Contents/Resources"
for lproj in "$ROOT_DIR"/Resources/*.lproj; do
  mkdir -p "$APP_DIR/Contents/Resources/$(basename "$lproj")"
  cp "$lproj"/* "$APP_DIR/Contents/Resources/$(basename "$lproj")/"
done
mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
chmod +x "$APP_DIR/Contents/MacOS/Osmotic"

# Hardened runtime: no JIT, no unsigned libraries, no debugger attach — the app needs none of them.
# Its resource-access entitlements (location, camera) are in Resources/Osmotic.entitlements.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ROOT_DIR/Resources/Osmotic.entitlements"
  --identifier io.github.smithplus.osmotic)
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_FLAGS+=(--timestamp); fi   # notarization requires a secure timestamp
codesign "${SIGN_FLAGS[@]}" "$APP_DIR"
echo "$APP_DIR"
