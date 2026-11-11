#!/bin/bash
# Recette du terminal (spike S3) : saisie composée (touches mortes AZERTY, CJK) et accessibilité (AXTextArea).
# Lance l'app avec une bibliothèque TEMPORAIRE (--library) et le scénario --selftest-terminal : aucun serveur ssh,
# un pty local (python en mode raw) ; aucun événement clavier global, aucune prise de focus.
# Sortie : code de l'app ; résultats dans $OUT (result.json + capture). Ne touche jamais à ~/.ssh ni à Application Support/Escale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-term.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cd "$ROOT"
if [ -z "${ESCALE_APP:-}" ]; then
  /opt/homebrew/bin/xcodegen generate --quiet
  xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
    -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
    || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }
fi
APP_BIN="${ESCALE_APP:-$DD/Build/Products/Debug/Escale.app}/Contents/MacOS/Escale"

set +e
"$APP_BIN" --library "$WORK/lib/library.json" --ssh-config /dev/null \
  --keychain-service "com.attila-krb.Escale.selftest.terminal.$$" \
  --selftest-terminal "$OUT" &
APP_PID=$!
( sleep 180; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; fi
echo "code de sortie de l'app : $CODE"
exit "$CODE"
