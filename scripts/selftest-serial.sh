#!/bin/bash
# Recette du module Série : lance l'app avec une bibliothèque TEMPORAIRE (--library) et le scénario --selftest-serial.
# Le scénario crée lui-même un pty (maître = appareil simulé), ouvre un onglet série dessus, vérifie affichage, saisie,
# CRLF, occupé, port absent et déconnexion. Aucun clic, aucune boîte de dialogue. Ne touche jamais à ~/.ssh.
# Sortie : code de l'app ; résultats dans $OUT (result.json).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-serial.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }

set +e
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/lib/library.json" --ssh-config /dev/null --keychain-service "com.attila-krb.Escale.selftest.serial.$$" \
  --selftest-serial "$OUT" &
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
