#!/usr/bin/env bash
# Build a release: tag, universal app, a DMG for people (drag to Applications) and a zip + Ed25519
# signature for the in-app updater.
#   scripts/release.sh 0.2.0              dry run: builds build/Osmotic-0.2.0.{dmg,zip,zip.sig}, publishes nothing
#   scripts/release.sh 0.2.0 --publish    also pushes the tag and creates the GitHub release (gh)
# Needs: a clean tree, a "## [0.2.0]" section in CHANGELOG.md, the signing key in the Keychain
# (swift scripts/update_key.swift generate) and its public half in Info.plist (OsmoticUpdatePublicKey).
# Optional: SIGN_IDENTITY for a Developer ID build (see package_app.sh / notarize.sh); NOTES_FILE for
# release notes other than the CHANGELOG section.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="${1:?usage: scripts/release.sh X.Y.Z [--publish]}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "commit your changes first"; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "add a '## [$VERSION]' section to CHANGELOG.md"; exit 1; }
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :OsmoticUpdatePublicKey' Resources/Info.plist 2>/dev/null || true)"
[ -n "$PUBKEY" ] || { echo "Info.plist has no OsmoticUpdatePublicKey"; exit 1; }
[ "$(swift scripts/update_key.swift public)" = "$PUBKEY" ] || { echo "the Keychain key doesn't match Info.plist"; exit 1; }

git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || git tag -a "v$VERSION" -m "Osmotic $VERSION"
scripts/package_app.sh release
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Osmotic.app/Contents/Info.plist)"
[ "$BUILT" = "$VERSION" ] || { echo "built version $BUILT != $VERSION (is v$VERSION the latest tag?)"; exit 1; }

ZIP="build/Osmotic-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/Osmotic.app "$ZIP"
swift scripts/update_key.swift sign "$ZIP" > "$ZIP.sig"
swift scripts/update_key.swift verify "$ZIP" "$ZIP.sig" "$PUBKEY"

# The DMG: the app, a shortcut to Applications and a note for the first launch of an unnotarized
# build. Signed only when there's a Developer ID (notarize.sh is the path for that).
DMG="build/Osmotic-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Osmotic.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg_readme.txt "$STAGE/Read Me First.txt"
cp LICENSE "$STAGE/LICENSE.txt"
hdiutil create -quiet -volname "Osmotic $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
[ -n "${SIGN_IDENTITY:-}" ] && codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# Release notes: NOTES_FILE if given, else the version's section of CHANGELOG.md.
if [ -n "${NOTES_FILE:-}" ]; then
  NOTES="$NOTES_FILE"
else
  NOTES="$(mktemp)"
  awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$NOTES"
fi
echo "Built $DMG ($(du -h "$DMG" | cut -f1)), $ZIP ($(du -h "$ZIP" | cut -f1)) and its signature."
if [ "$PUBLISH" = "--publish" ]; then
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$ZIP" "$ZIP.sig" --title "Osmotic $VERSION" --notes-file "$NOTES"
else
  echo "Dry run — nothing published. To publish: scripts/release.sh $VERSION --publish"
fi
