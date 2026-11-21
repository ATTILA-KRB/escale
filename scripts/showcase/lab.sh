#!/bin/bash
# Labo de captures d'écran : quelques sshd locaux non privilégiés qui présentent des données FICTIVES mais réalistes
# (faux shell Ubuntu, faux SFTP, faux /proc pour le monitoring). Aucune information de la vraie machine n'est exposée.
#
#   scripts/showcase/lab.sh env   démarre les serveurs, écrit $WORK/env.sh, reste au premier plan (Ctrl-C pour arrêter)
#   scripts/showcase/lab.sh app   idem + build Debug de l'app et lancement avec la bibliothèque du labo
#
# Variables : ESCALE_LAB_WORK (dossier de travail imposé), KEEP=1 (ne pas effacer le WORK), BUILD_ONLY=1 (mode app :
# compiler puis s'arrêter), ESCALE_DD (derivedData, défaut $ROOT/build). Ne touche jamais à ~/.ssh.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1   # pas de __pycache__ dans le dépôt (et un sshd sans session écrit mal les .pyc)

MODE="${1:-env}"
case "$MODE" in env | app) ;; *) echo "usage : $0 env|app" >&2; exit 64 ;; esac

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SRC/../.." && pwd -P)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
XDIR="$DD/Build/Products/Debug/Escale.app/Contents/Helpers/EscaleX11.app/Contents/MacOS"
# Dossier court (sockets de contrôle ~104 octets) sous $TMPDIR.
if [ -n "${ESCALE_LAB_WORK:-}" ]; then mkdir -p "$ESCALE_LAB_WORK"; WORK="$ESCALE_LAB_WORK"
else WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-lab.XXXXXX")"; fi
WORK="$(cd "$WORK" && pwd -P)"
REAL_USER="$(id -un)"
PIDS=()
APP_PID=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  # Reliquats de CE labo uniquement (maîtres ssh de l'app, wrappers, faux serveurs) : leur ligne de commande cite $WORK/.
  # Jamais de motif large (invariant 9).
  pkill -f -- "$WORK/" 2>/dev/null || true
  sleep 0.2
  [ -z "${KEEP:-}" ] && rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# --- hôtes fictifs servis : nom ip rôle (un sshd chacun)
SERVED=("web-01 10.40.1.11 web" "web-02 10.40.1.12 web" "db-primary 10.40.2.10 db" "bastion 10.40.0.5 bastion")
# --- hôtes de la bibliothèque non servis (port fermé) : nom ip
UNSERVED=("db-replica 10.40.2.11" "cache-01 10.40.2.20" "staging-web 10.40.3.11" "staging-db 10.40.3.12"
  "monitoring 10.40.0.20" "ci-runner-01 10.40.0.31")

NPORTS=$((${#SERVED[@]} + ${#UNSERVED[@]}))
PORTS=($(/usr/bin/python3 - "$NPORTS" <<'PY'
import socket, sys
socks = [socket.socket() for _ in range(int(sys.argv[1]))]
for s in socks:
    s.bind(("127.0.0.1", 0))
print(" ".join(str(s.getsockname()[1]) for s in socks))
PY
))

mkdir -p "$WORK/ssh" "$WORK/hosts" "$WORK/tmp"
chmod 700 "$WORK/ssh"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-lab -f "$WORK/ssh/client"
# xauth vu par sshd : le cookie X11 va dans le WORK, jamais dans le ~/.Xauthority réel.
printf '#!/bin/sh\nXAUTHORITY="%s/xauthority" exec "%s/xauth" "$@"\n' "$WORK" "$XDIR" > "$WORK/xauth-lab"
chmod +x "$WORK/xauth-lab"
: > "$WORK/xauthority"; chmod 600 "$WORK/xauthority"  # fichier présent : xauth n'imprime pas son chemin réel
cp "$WORK/ssh/client.pub" "$WORK/ssh/authorized_keys"; chmod 600 "$WORK/ssh/authorized_keys"
: > "$WORK/known_hosts"
: > "$WORK/ssh_config"
: > "$WORK/hosts.list"
chmod +x "$SRC"/wrapper.sh "$SRC"/fake_sftp.py "$SRC"/fake_cmds.py "$SRC"/seed_fs.py

# Bloc ssh_config : l'app affiche l'IP fictive, ssh se connecte au sshd local.
cfg_block() { # ip port
  cat >> "$WORK/ssh_config" <<CFG
Host $1
    HostName 127.0.0.1
    Port $2
    User $REAL_USER
    HostKeyAlias $1

CFG
}

i=0
for entry in "${SERVED[@]}"; do
  read -r NAME IP ROLE <<<"$entry"
  PORT="${PORTS[$i]}"; i=$((i + 1))
  H="$WORK/hosts/$NAME"
  mkdir -p "$H/bin"; chmod 700 "$H"
  /usr/bin/ssh-keygen -q -t ed25519 -N "" -C "$NAME" -f "$H/hostkey"
  echo "$IP $(cut -d' ' -f1,2 "$H/hostkey.pub")" >> "$WORK/known_hosts"
  /usr/bin/python3 "$SRC/seed_fs.py" "$H" "$NAME" "$IP" "$ROLE"
  cat > "$H/hostenv" <<ENV
LABHOST=$NAME
LABIP=$IP
LABDIR=$WORK
LABSRC=$SRC
FAKEROOT=$H/root
ENV
  # Faux bin : commandes factices prioritaires dans le PATH du faux shell
  cmds="uptime df free uname hostname whoami id groups journalctl who w ls sudo lsb_release systemctl"
  [ "$ROLE" = web ] && cmds="$cmds docker nginx"
  for c in $cmds; do ln -sf "$SRC/fake_cmds.py" "$H/bin/$c"; done
  # X11 : xeyes du serveur X11 intégré à l'app, lancé « sur l'hôte » (DISPLAY posé par sshd).
  # Position fixe pour la capture ; stderr muet (le xeyes du bundle n'a pas les locales Xlib).
  printf '#!/bin/sh\nexec "%s/xeyes" -geometry 320x240+1040+470 "$@" 2>/dev/null\n' "$XDIR" > "$H/bin/xeyes"; chmod +x "$H/bin/xeyes"
  cat > "$H/sshd_config" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey $H/hostkey
PidFile $H/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $WORK/ssh/authorized_keys
StrictModes no
PrintMotd no
PrintLastLog no
AllowTcpForwarding yes
X11Forwarding yes
X11UseLocalhost yes
XAuthLocation $WORK/xauth-lab
MaxSessions 10
MaxStartups 100:30:200
LogLevel VERBOSE
Subsystem sftp lab-fake-sftp
ForceCommand $SRC/wrapper.sh $H
CONF
  /usr/sbin/sshd -D -e -f "$H/sshd_config" 2> "$H/sshd.log" &
  PIDS+=($!)
  cfg_block "$IP" "$PORT"
  echo "$NAME $IP $PORT $ROLE servi" >> "$WORK/hosts.list"
done

for entry in "${UNSERVED[@]}"; do
  read -r NAME IP <<<"$entry"
  PORT="${PORTS[$i]}"; i=$((i + 1))
  # Hôte « hors ligne » : ssh vise l'IP fictive elle-même (aucune machine derrière), d'où un vrai
  # « Operation timed out » sur l'adresse affichée, sans révéler 127.0.0.1 ni le port local.
  cat >> "$WORK/ssh_config" <<CFG
Host $IP
    HostName $IP
    ConnectTimeout 4
    User $REAL_USER

CFG
  echo "$NAME $IP 22 - ferme" >> "$WORK/hosts.list"
done

# Attente des ports des sshd
for entry in "${SERVED[@]}"; do
  read -r NAME _ _ <<<"$entry"
  PORT="$(awk -v n="$NAME" '$1==n{print $3}' "$WORK/hosts.list")"
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
    sleep 0.1
  done
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || { echo "sshd $NAME n'écoute pas :" >&2; cat "$WORK/hosts/$NAME/sshd.log" >&2; exit 2; }
done

# --- bibliothèque JSON. L'app affiche deploy@<ip fictive> ; la cible ssh reste deploy@ip, mais `--ssh-option User=<réel>`
# (un -o User passé avant la cible l'emporte sur user@host, vérifié) fait authentifier le vrai utilisateur local auprès du
# sshd non privilégié. `port` est omis : un -p explicite écraserait le Port du ssh_config (127.0.0.1:<port réel>).
/usr/bin/python3 - "$WORK" <<'PY'
import json, sys, uuid
work = sys.argv[1]
ips = {}
for line in open(work + "/hosts.list"):
    n, ip = line.split()[:2]
    ips[n] = ip
meta = {
    "web-01": ("Production", ["prod", "web", "nginx"]), "web-02": ("Production", ["prod", "web", "nginx"]),
    "db-primary": ("Production", ["prod", "db", "postgres"]), "db-replica": ("Production", ["prod", "db", "postgres"]),
    "cache-01": ("Production", ["prod", "cache"]), "staging-web": ("Préprod", ["staging", "web"]),
    "staging-db": ("Préprod", ["staging", "db"]), "bastion": ("Infra", ["infra", "ssh"]),
    "monitoring": ("Infra", ["infra", "metrics"]), "ci-runner-01": ("Infra", ["infra", "ci"]),
}
folders = {n: str(uuid.uuid4()).upper() for n in ("Production", "Préprod", "Infra")}
order = ["web-01", "web-02", "db-primary", "db-replica", "cache-01", "staging-web", "staging-db", "bastion", "monitoring", "ci-runner-01"]
hosts = [{"id": str(uuid.uuid4()).upper(), "name": n, "host": ips[n],
          "user": "deploy", "auth": {"keyFile": {"path": work + "/ssh/client"}}, "jumpHosts": [], "tags": meta[n][1],
          "folderID": folders[meta[n][0]]} for n in order]
lib = {"version": 1, "folders": [{"id": fid, "name": name} for name, fid in folders.items()], "hosts": hosts}
# Tunnels de démonstration (ports locaux hauts, ouverts seulement à la demande dans l'app).
tun = lambda kind, port, dh="", dp=0, name="": {"id": str(uuid.uuid4()).upper(), "kind": kind, "bindAddress": "127.0.0.1",
                                                 "bindPort": port, "destinationHost": dh, "destinationPort": dp, "name": name, "autoStart": False}
extra = {"bastion": [tun("local", 15432, ips["db-primary"], 5432, "PostgreSQL production"), tun("local", 16379, ips["cache-01"], 6379, "Redis"),
                     tun("local", 13000, ips["monitoring"], 3000, "Grafana"), tun("dynamic", 1080, name="Proxy SOCKS")],
         "web-01": [tun("local", 18080, "127.0.0.1", 8080, "App interne"), tun("remote", 9000, "127.0.0.1", 9000, "Webhook de dev")]}
for h in hosts:
    h["tunnels"] = extra.get(h["name"], [])
    h["x11Forwarding"] = h["name"] in ("web-01", "staging-web")
json.dump(lib, open(work + "/library.json", "w"), indent=2, ensure_ascii=False)
PY

cat > "$WORK/env.sh" <<ENV
# Généré par lab.sh : chemins du labo (à sourcer)
export ESCALE_LAB_WORK="$WORK"
export ESCALE_LAB_LIBRARY="$WORK/library.json"
export ESCALE_LAB_SSH_CONFIG="$WORK/ssh_config"
export ESCALE_LAB_KNOWN_HOSTS="$WORK/known_hosts"
export ESCALE_LAB_KEY="$WORK/ssh/client"
export ESCALE_LAB_HOSTS="$WORK/hosts.list"
export ESCALE_LAB_REAL_USER="$REAL_USER"
ENV

echo "Labo prêt dans $WORK"
echo "  hôtes (nom ip port-réel rôle état) :"
sed 's/^/    /' "$WORK/hosts.list"
echo "  env : $WORK/env.sh"

APP_ARGS=(--library "$WORK/library.json" --ssh-config "$WORK/ssh_config" --known-hosts "$WORK/known_hosts"
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null
  --ssh-option "User=$REAL_USER")

if [ "$MODE" = app ]; then
  cd "$ROOT"
  /opt/homebrew/bin/xcodegen generate --quiet
  xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
    -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
    || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }
  /usr/bin/awk '/BUILD (SUCCEEDED|FAILED)/' "$WORK/build.log" | tail -n 1 || true
  if [ -n "${BUILD_ONLY:-}" ]; then echo "BUILD_ONLY : lancement sauté"; exit 0; fi
  "$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" "${APP_ARGS[@]}" > "$WORK/app.log" 2>&1 &
  APP_PID=$!
  echo "app lancée (pid $APP_PID), journal : $WORK/app.log — fermer l'app ou Ctrl-C pour arrêter le labo"
  wait "$APP_PID" || true
  APP_PID=""
else
  echo "Options app : ${APP_ARGS[*]}"
  echo "Ctrl-C pour arrêter."
  while :; do sleep 1; done
fi
