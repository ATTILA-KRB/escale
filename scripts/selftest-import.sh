#!/bin/bash
# Recette de l'import de sessions (MobaXterm, PuTTY, CSV) : lance l'app avec une bibliothèque TEMPORAIRE (--library) et
# le scénario --selftest-import (aucun clic, aucune boîte de dialogue). Les fixtures sources sont dans
# scripts/fixtures/import (UTF-8) et converties ici en encodages Windows : cp1252 (.mxtsessions), UTF-16LE + BOM (.reg).
# Sortie : code de l'app ; résultats dans $OUT (result.json). Ne touche jamais à ~/.ssh ni à Application Support/Escale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-impt.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT" "$WORK/fixtures"
APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

SRC="$ROOT/scripts/fixtures/import"
python3 - "$SRC" "$WORK/fixtures" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
open(f"{dst}/moba.mxtsessions", "wb").write(open(f"{src}/moba.mxtsessions", encoding="utf-8").read().replace("\n", "\r\n").encode("cp1252"))
open(f"{dst}/putty.reg", "wb").write(b"\xff\xfe" + open(f"{src}/putty.reg", encoding="utf-8").read().replace("\n", "\r\n").encode("utf-16-le"))
open(f"{dst}/hosts.csv", "wb").write(open(f"{src}/hosts.csv", "rb").read())
PY

cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }

set +e
ESCALE_IMPORTTEST_FIXTURES="$WORK/fixtures" \
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/lib/library.json" --ssh-config /dev/null --keychain-service "com.attila-krb.Escale.selftest.import.$$" \
  --selftest-import "$OUT" &
APP_PID=$!
( sleep 120; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; cp "$WORK/lib/library.json" "$KEEP_OUT/library.json" 2>/dev/null || true; fi
echo "code de sortie de l'app : $CODE"
[ "$CODE" -eq 0 ] || exit 1
