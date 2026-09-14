#!/usr/bin/env bash
# Debug: render a demo screen of build/Osmotic.app to a PNG without hardware.
#   scripts/snapshot.sh <out.png> [library|connecting|cameras] [manifest.bin]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$1"; SCREEN="${2:-library}"; MANIFEST="${3:-$ROOT_DIR/Tests/OsmoticCoreTests/Fixtures/op3_29.bin}"
rm -f "$OUT"
OSMOTIC_DEMO_MANIFEST="$MANIFEST" OSMOTIC_DEMO_SCREEN="$SCREEN" OSMOTIC_SNAPSHOT="$OUT" OSMOTIC_SNAPSHOT_QUIT=1 \
  "$ROOT_DIR/build/Osmotic.app/Contents/MacOS/Osmotic" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 40); do [ -f "$OUT" ] && break; sleep 0.5; done
sleep 1; kill "$PID" 2>/dev/null || true
ls -la "$OUT"
