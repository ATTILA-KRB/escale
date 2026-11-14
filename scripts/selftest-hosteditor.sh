#!/bin/bash
# Recette du dialogue de session (HostEditorSheet) : app lancee avec une bibliotheque vide (creee dans $WORK), scenario
# --selftest-hosteditor pilote en interne (aucun clic, aucune activation, aucun sshd : l'editeur n'ouvre aucune connexion).
# Sortie : code de l'app ; resultats dans $OUT (result.json + PNG). Ne touche jamais a ~/.ssh ni a ~/Library.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-hedt.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""

cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- build isole
cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en echec"; exit 3; }
/opt/homebrew/bin/rg -N "BUILD (SUCCEEDED|FAILED)" "$WORK/build.log" | tail -n 1 || tail -n 3 "$WORK/build.log"

# --- lancement
set +e
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/lib/library.json" --ssh-config /dev/null --known-hosts "$WORK/known_hosts" \
  --keychain-service "com.attila-krb.Escale.selftest.hosteditor.$$" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null \
  --selftest-hosteditor "$OUT" &
APP_PID=$!
# Garde-fou : 3 minutes maximum.
( sleep 180; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; fi
echo "code de sortie de l'app : $CODE"
exit "$CODE"
