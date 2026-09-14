#!/usr/bin/env bash
# Pull every localizable string the compiler sees into Resources/Localizable.xcstrings.
# New keys arrive untranslated (state "new"); stale ones are marked so. Translate them in Xcode
# (open the .xcstrings file) or by editing the JSON, then rebuild with scripts/package_app.sh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift build --package-path "$ROOT_DIR" --scratch-path "$WORK/build" --product Osmotic \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null
xcrun xcstringstool sync "$ROOT_DIR/Resources/Localizable.xcstrings" --stringsdata "$WORK"/strings/*.stringsdata
python3 - "$ROOT_DIR/Resources/Localizable.xcstrings" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
todo = [k for k, v in d["strings"].items()
        if v.get("shouldTranslate", True) and "es" not in v.get("localizations", {})]
print(f"{len(d['strings'])} strings, {len(todo)} without Spanish:")
for k in todo: print("  ", repr(k))
PY
