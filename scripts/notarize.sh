#!/usr/bin/env bash
# Release: sign with Developer ID, wrap in a DMG, notarize, staple. Needs an Apple Developer account.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=osmotic scripts/notarize.sh
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials osmotic --apple-id you@example.com --team-id TEAMID
# Ship only the stapled build/Osmotic.dmg (a zip can't be stapled).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/scripts/package_app.sh" release
APP="$ROOT_DIR/build/Osmotic.app"
DMG="$ROOT_DIR/build/Osmotic.dmg"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT_DIR/LICENSE" "$STAGE/LICENSE.txt"
hdiutil create -volname Osmotic -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp -i io.github.smithplus.osmotic "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "$DMG"
