#!/usr/bin/env bash
# Build a release that the in-app updater can install: tag, universal app, zip, Ed25519 signature.
#   scripts/release.sh 0.2.0              dry run: builds build/Osmotic-0.2.0.zip + .sig, publishes nothing
#   scripts/release.sh 0.2.0 --publish    also pushes the tag and creates the GitHub release (gh)
# Needs: a clean tree, a "## [0.2.0]" section in CHANGELOG.md, the signing key in the Keychain
# (swift scripts/update_key.swift generate) and its public half in Info.plist (OsmoticUpdatePublicKey).
# Optional: SIGN_IDENTITY for a Developer ID build (see package_app.sh / notarize.sh).
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

NOTES="$(mktemp)"
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$NOTES"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1)) and its signature."
if [ "$PUBLISH" = "--publish" ]; then
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "Osmotic $VERSION" --notes-file "$NOTES"
else
  echo "Dry run — nothing published. To publish: scripts/release.sh $VERSION --publish"
fi
