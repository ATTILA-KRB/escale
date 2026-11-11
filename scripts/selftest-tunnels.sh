#!/bin/bash
# Recette des tunnels : sshd local non privilégié + serveur HTTP local + scénario --selftest-tunnels piloté en interne.
# L, D, R et autoStart vérifiés par curl, IPv6 (::1 et zone fe80::1%lo0), -R 0 (port attribué), modification à chaud d'un tunnel actif
# (succès, puis échec avec rétablissement de l'ancien), coupure du maître, rétablissement automatique.
# Sortie : code de l'app ; résultats dans $OUT (result.json + PNG). Ne touche jamais à ~/.ssh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
# Dossier court (limite ~104 octets des sockets de contrôle) : sous $TMPDIR, pruné par le système.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-tunt.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
SSHD_PID=""
APP_PID=""
HTTP_PID=""
HTTP6_PID=""

cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
  [ -n "$HTTP6_PID" ] && kill "$HTTP6_PID" 2>/dev/null || true
  if [ -n "$SSHD_PID" ]; then
    pkill -P "$SSHD_PID" 2>/dev/null || true
    kill "$SSHD_PID" 2>/dev/null || true
  fi
  # Maîtres orphelins de CETTE recette uniquement (leur ligne de commande cite $WORK) ; jamais un motif large.
  pkill -f "ssh .*$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# --- serveur HTTP local (cible des tunnels)
HTTP_PORT="$(freeport)"
BODY="escale-tunnel-ok-$RANDOM$RANDOM"
mkdir -p "$WORK/www"
printf '%s' "$BODY" > "$WORK/www/index.html"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/www" > "$WORK/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$HTTP_PORT") 2>/dev/null && break
  kill -0 "$HTTP_PID" 2>/dev/null || { echo "serveur HTTP a quitté :"; cat "$WORK/http.log"; exit 2; }
  sleep 0.1
done

# --- second serveur HTTP en IPv6 (::1) : cible des tunnels IPv6 et de la modification à chaud
HTTP6_PORT="$(freeport)"
BODY6="escale-tunnel-ipv6-$RANDOM$RANDOM"
mkdir -p "$WORK/www6"
printf '%s' "$BODY6" > "$WORK/www6/index.html"
cat > "$WORK/http6.py" <<'PY'
import http.server, socket, sys
class S(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    def log_message(self, *a): pass
import os
os.chdir(sys.argv[2])
S(("::1", int(sys.argv[1])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
python3 "$WORK/http6.py" "$HTTP6_PORT" "$WORK/www6" > "$WORK/http6.log" 2>&1 &
HTTP6_PID=$!
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/::1/$HTTP6_PORT") 2>/dev/null && break
  kill -0 "$HTTP6_PID" 2>/dev/null || { echo "serveur HTTP IPv6 a quitté :"; cat "$WORK/http6.log"; exit 2; }
  sleep 0.1
done

# --- sshd local sur 127.0.0.1, port libre
PORT="$(freeport)"
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
  kill -0 "$SSHD_PID" 2>/dev/null || { echo "sshd a quitté :"; cat "$D/sshd.log"; exit 2; }
  sleep 0.1
done

# --- bibliothèque JSON : « Hôte A » porte 4 tunnels (L, D, R, L autoStart), « Hôte B » aucun
PL="$(freeport)"; PD="$(freeport)"; PR="$(freeport)"; PA="$(freeport)"; P6="$(freeport)"; PZ="$(freeport)"; PE="$(freeport)"
python3 - "$WORK/library.json" "$PORT" "$D/client" "$(id -un)" "$HTTP_PORT" "$PL" "$PD" "$PR" "$PA" "$HTTP6_PORT" "$P6" "$PE" "$PZ" <<'PY'
import json, sys, uuid
path, port, key, user, http, pl, pd, pr, pa, http6, p6, pe, pz = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], *map(int, sys.argv[5:])
folder = str(uuid.uuid4()).upper()
def tun(kind, bind, dest=0, name="", auto=False, addr="127.0.0.1", dhost="127.0.0.1"):
    return {"id": str(uuid.uuid4()).upper(), "kind": kind, "bindAddress": addr, "bindPort": bind,
            "destinationHost": dhost if kind != "dynamic" else "", "destinationPort": dest if kind != "dynamic" else 0,
            "name": name, "autoStart": auto}
def host(name, tunnels):
    return {"id": str(uuid.uuid4()).upper(), "name": name, "host": "127.0.0.1", "port": port, "user": user,
            "auth": {"keyFile": {"path": key}}, "jumpHosts": [], "tags": ["test"], "folderID": folder, "tunnels": tunnels}
a = host("Hôte A", [tun("local", pl, http, "web local"), tun("dynamic", pd, 0, "proxy SOCKS"),
                    tun("remote", pr, http, "exposition distante"), tun("local", pa, http, "auto", True),
                    tun("local", p6, http6, "ipv6 local", addr="::1", dhost="::1"),
                    tun("local", pz, http6, "ipv6 zone", addr="fe80::1%lo0", dhost="::1"), # lien local de lo0 (macOS)
                    tun("remote", 0, http, "distant port attribué"),
                    tun("local", pe, http, "a modifier")])
lib = {"folders": [{"id": folder, "name": "Tests locaux"}], "hosts": [a, host("Hôte B", [])]}
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
ESCALE_TUNNEL_HTTP_PORT="$HTTP_PORT" ESCALE_TUNNEL_HTTP_BODY="$BODY" \
ESCALE_TUNNEL_HTTP6_PORT="$HTTP6_PORT" ESCALE_TUNNEL_HTTP6_BODY="$BODY6" \
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/library.json" --ssh-config /dev/null --known-hosts "$D/known_hosts" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null \
  --selftest-tunnels "$OUT" &
APP_PID=$!
# Garde-fou : 4 minutes maximum.
( sleep 240; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; cp "$D/sshd.log" "$KEEP_OUT/sshd.log"; fi
echo "code de sortie de l'app : $CODE"
exit "$CODE"
