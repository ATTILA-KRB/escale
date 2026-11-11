#!/bin/bash
# Recette du client VNC : lance un serveur RFB de test (scripts/fixtures/vnc/rfbserver.py, stdlib Python, port 0) puis
# sshd local non privilegie (trajet « via un hote SSH », copie de selftest-telnet.sh) puis l'app avec une bibliotheque
# TEMPORAIRE et le scenario --selftest-vnc (fenetre sans prendre le focus).
# Le mot de passe de test est genere au hasard, transmis par variable d'environnement, jamais ecrit sur disque.
# Sortie : code de l'app ; resultats dans $OUT (result.json, vnc-fenetre.png). Ne touche jamais a ~/.ssh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-vnct.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
APP_PID=""; SRV_PID=""; SSHD_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  if [ -n "$SSHD_PID" ]; then
    pkill -P "$SSHD_PID" 2>/dev/null || true
    kill "$SSHD_PID" 2>/dev/null || true
  fi
  # Maitres orphelins de CETTE recette uniquement (leur ligne de commande cite $WORK) ; jamais un motif large.
  pkill -f "ssh .*$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- sshd local sur 127.0.0.1, port libre (relais du trajet « via SSH »)
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
D="$WORK/sshd"; mkdir -p "$D"; chmod 700 "$D"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-host -f "$D/hostkey"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-client -f "$D/client"
cp "$D/client.pub" "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/hostkey.pub")" > "$D/known_hosts"
cat > "$D/sshd_config" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $D/authorized_keys
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
AllowTcpForwarding yes
MaxSessions 10
MaxStartups 100:30:200
PrintMotd no
LogLevel VERBOSE
CONF
/usr/sbin/sshd -D -e -f "$D/sshd_config" 2> "$D/sshd.log" &
SSHD_PID=$!
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  kill -0 "$SSHD_PID" 2>/dev/null || { echo "sshd a quitte :"; cat "$D/sshd.log"; exit 2; }
  sleep 0.1
done

# --- bibliotheque JSON : un hote SSH « Relais SSH »
mkdir -p "$WORK/lib"
python3 - "$WORK/lib/library.json" "$PORT" "$D/client" "$(id -un)" <<'PY'
import json, sys, uuid
path, port, key, user = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
host = {"id": str(uuid.uuid4()).upper(), "name": "Relais SSH", "host": "127.0.0.1", "port": port, "user": user,
        "auth": {"keyFile": {"path": key}}, "jumpHosts": [], "tags": ["test"], "tunnels": []}
json.dump({"folders": [], "hosts": [host]}, open(path, "w"), indent=2)
PY

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
  --library "$WORK/lib/library.json" --ssh-config /dev/null --known-hosts "$D/known_hosts" \
  --keychain-service "com.attila-krb.Escale.selftest.vnc.$$" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null \
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
