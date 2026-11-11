#!/bin/bash
# Recette du client VNC : lance un serveur RFB de test (scripts/fixtures/vnc/rfbserver.py, stdlib Python, port 0) puis
# l'app avec une bibliotheque TEMPORAIRE et le scenario --selftest-vnc (fenetre sans prendre le focus).
# Le mot de passe de test est genere au hasard, transmis par variable d'environnement, jamais ecrit sur disque.
# Sortie : code de l'app ; resultats dans $OUT (result.json, vnc-fenetre.png). Ne touche jamais a ~/.ssh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-vnct.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""; SRV_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en echec"; exit 3; }

export ESCALE_VNCTEST_PASSWORD="t$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
export ESCALE_VNCTEST_LOG="$WORK/server.log"
: > "$ESCALE_VNCTEST_LOG"
python3 "$ROOT/scripts/fixtures/vnc/rfbserver.py" --port-file "$WORK/port" --log "$ESCALE_VNCTEST_LOG" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "serveur RFB de test non demarre"; exit 4; }
export ESCALE_VNCTEST_PORT="$(cat "$WORK/port")"

set +e
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/lib/library.json" --ssh-config /dev/null --keychain-service "com.attila-krb.Escale.selftest.vnc.$$" \
  --selftest-vnc "$OUT" &
APP_PID=$!
( sleep 120; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
cp "$ESCALE_VNCTEST_LOG" "$OUT/server.log" 2>/dev/null || true
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; fi
echo "code de sortie de l'app : $CODE"
[ "$CODE" -eq 0 ] || exit 1
