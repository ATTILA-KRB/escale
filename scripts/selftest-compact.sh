#!/bin/bash
# Recette du mode compact : fenetre principale normale puis compacte (barre d'outils en icones, barre laterale
# repliee, retour a l'etat precedent, persistance). Bibliotheque TEMPORAIRE (--library), aucun serveur ssh, aucun
# evenement global, aucune prise de focus. Resultats dans $OUT (result.json + PNG). Ne touche jamais a ~/.ssh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-compt.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Bibliothèque de test : un dossier, un hôte (jamais connecté), pour que la barre latérale ait du contenu.
mkdir -p "$WORK/lib"
python3 - "$WORK/lib/library.json" <<'PY'
import json, sys, uuid
folder = str(uuid.uuid4()).upper()
host = {"id": str(uuid.uuid4()).upper(), "name": "Hôte exemple", "host": "127.0.0.1", "port": 22, "user": "test",
        "auth": {"openSSHDefaults": {}}, "jumpHosts": [], "tags": [], "folderID": folder}
json.dump({"folders": [{"id": folder, "name": "Tests locaux"}], "hosts": [host]}, open(sys.argv[1], "w"), indent=2)
PY

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
  --keychain-service "com.attila-krb.Escale.selftest.compact.$$" \
  --selftest-compact "$OUT" &
APP_PID=$!
( sleep 240; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; fi
echo "code de sortie de l'app : $CODE"
exit "$CODE"
