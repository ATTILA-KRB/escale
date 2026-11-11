#!/bin/bash
# Recette macros + X11 : sshd local non privilégié (X11Forwarding, faux xauth, faux serveur X) + scénario --selftest-macros.
# Sans XQuartz : la preuve X11 porte sur la chaîne ssh (DISPLAY distant, connexion X rapatriée), pas sur l'affichage.
# Sortie : code de l'app ; résultats dans $OUT (result.json + PNG). Ne touche jamais à ~/.ssh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
# Dossier court (limite ~104 octets des sockets de contrôle) : sous $TMPDIR, pruné par le système.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-macrot.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
SSHD_PID=""
APP_PID=""
FAKEX_PID=""

cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  [ -n "$FAKEX_PID" ] && kill "$FAKEX_PID" 2>/dev/null || true
  if [ -n "$SSHD_PID" ]; then
    pkill -P "$SSHD_PID" 2>/dev/null || true
    kill "$SSHD_PID" 2>/dev/null || true
  fi
  # Maîtres orphelins de CETTE recette uniquement : leur ligne de commande cite $WORK (known_hosts, clé).
  # Ne jamais viser tous les « ssh -M » : cela tuerait les connexions d'une app Escale en service
  # et celles des tests du cœur lancés en parallèle.
  pkill -f "ssh .*$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- sshd local sur 127.0.0.1, port libre
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
D="$WORK/sshd"; mkdir -p "$D"; chmod 700 "$D"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-host -f "$D/hostkey"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-client -f "$D/client"
cp "$D/client.pub" "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/hostkey.pub")" > "$D/known_hosts"
# Faux xauth : liste un cookie ; garde sur disque le cookie « add » que sshd lui envoie (la sonde distante s'en sert).
cat > "$D/fake-xauth" <<XAUTH
#!/bin/sh
if [ "\$1" = "-f" ]; then shift 2; fi
case "\$*" in
  *list*) echo 'mac/unix:0  MIT-MAGIC-COOKIE-1  00112233445566778899aabbccddeeff';;
  *" -") cat > "$D/xauth.stdin";;
esac
exit 0
XAUTH
chmod 755 "$D/fake-xauth"
# Faux serveur X : socket Unix, mémorise les premiers octets reçus.
cat > "$D/fakex.py" <<'PY'
import os, socket, sys
path, got = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
while True:
    c, _ = s.accept()
    d = c.recv(512)
    with open(got, "ab") as f: f.write(d)
    c.close()
PY
python3 "$D/fakex.py" "$D/X0" "$D/x0.got" &
FAKEX_PID=$!
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
X11Forwarding yes
X11UseLocalhost yes
XAuthLocation $D/fake-xauth
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
  kill -0 "$SSHD_PID" 2>/dev/null || { echo "sshd a quitté :"; cat "$D/sshd.log"; exit 2; }
  sleep 0.1
done

# --- bibliothèque JSON : un dossier, deux hôtes (auth = fichier de clé)
python3 - "$WORK/library.json" "$PORT" "$D/client" "$(id -un)" <<'PY'
import json, sys, uuid
path, port, key, user = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
folder = str(uuid.uuid4()).upper()
def host(name, x11=False):
    h = {"id": str(uuid.uuid4()).upper(), "name": name, "host": "127.0.0.1", "port": port, "user": user,
         "auth": {"keyFile": {"path": key}}, "jumpHosts": [], "tags": ["test"], "folderID": folder}
    if x11: h["x11Forwarding"] = True
    return h
lib = {"folders": [{"id": folder, "name": "Tests locaux"}], "hosts": [host("Hôte A"), host("Hôte X", True), host("Hôte Y", True)]}
json.dump(lib, open(path, "w"), indent=2)
PY

# --- build isolé
cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }
/opt/homebrew/bin/rg -N "BUILD (SUCCEEDED|FAILED)" "$WORK/build.log" | tail -n 1 || tail -n 3 "$WORK/build.log"

# --- lancement
set +e
ESCALE_FAKEX_DIR="$D" ESCALE_FAKEX_GOT="$D/x0.got" ESCALE_SSHD_LOG="$D/sshd.log" "$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/library.json" --ssh-config /dev/null --known-hosts "$D/known_hosts" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null \
  --selftest-macros "$OUT" &
APP_PID=$!
# Garde-fou : 7 minutes maximum.
( sleep 420; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; cp "$D/sshd.log" "$KEEP_OUT/sshd.log"; fi
echo "code de sortie de l'app : $CODE"
exit "$CODE"
