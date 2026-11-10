#!/bin/bash
# Recette automatique de l'authentification : sshd local non privilégié (clé à phrase de passe, known_hosts de test,
# StrictHostKeyChecking=ask côté app) + scénario --selftest-auth piloté en interne (aucun clic, aucune activation).
# Sortie : code de l'app ; résultats dans $OUT (result.json + PNG). Ne touche jamais à ~/.ssh ni à
# ~/Library/Application Support/Escale ; Trousseau : service de test unique, entrées supprimées à la fin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD="${ESCALE_DD:-$ROOT/build}"
# Dossier court (limite ~104 octets des sockets de contrôle) : sous $TMPDIR, pruné par le système.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/escale-autht.XXXXXX")"
OUT="${OUT:-$WORK/out}"
mkdir -p "$OUT"
SSHD_PID=""
APP_PID=""
SERVICE="com.attila-krb.Escale.selftest.$$.$RANDOM"

cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  if [ -n "$SSHD_PID" ]; then
    pkill -P "$SSHD_PID" 2>/dev/null || true
    kill "$SSHD_PID" 2>/dev/null || true
  fi
  # Maîtres orphelins de CETTE recette uniquement : leur ligne de commande cite $WORK (known_hosts, clé).
  pkill -f "ssh .*$WORK/" 2>/dev/null || true
  # Filet : entrées Trousseau du service de test uniquement (jamais le service de l'utilisateur).
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    security delete-generic-password -s "$SERVICE" >/dev/null 2>&1 || break
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- sshd local sur 127.0.0.1, port libre
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
PASSPHRASE="escale-auth-passphrase-$RANDOM"
D="$WORK/sshd"; mkdir -p "$D"; chmod 700 "$D"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-host -f "$D/hostkey"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-other-host -f "$D/otherhost"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -C escale-client -f "$D/client"
/usr/bin/ssh-keygen -q -t ed25519 -N "$PASSPHRASE" -C escale-client-pp -f "$D/ppkey"
cat "$D/client.pub" "$D/ppkey.pub" > "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/hostkey.pub")" > "$D/known_hosts"
# known_hosts « clé modifiée » : une AUTRE clé d'hôte pour le même hôte:port.
echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/otherhost.pub")" > "$D/known_hosts_changed"
cat > "$D/sshd_config" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
UsePAM no
PasswordAuthentication yes
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

# --- ssh_config de test pour l'import (jamais ~/.ssh/config)
CFG="$WORK/import_ssh_config"
cat > "$CFG" <<'CONF'
# Fichier de test de la recette d'import
Host alpha
    HostName alpha.example.com
    User deploy
    Port 2222
    ProxyJump bastion

Host beta
    HostName beta.example.com
    User admin

Host gamma
    HostName gamma.example.com

Host *.interne
    User wildcard

Host *
    ServerAliveInterval 30

Match host special
    User conditionnel

CONF
# Inclusion circulaire (le fichier s'inclut lui-même, en tête, hors bloc Match) : l'analyseur doit l'ignorer et le signaler.
{ echo "Include $CFG"; cat "$CFG"; } > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
CFG_SUM_BEFORE="$(shasum -a 256 "$CFG" | cut -d' ' -f1)"

# --- build isolé
cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation build > "$WORK/build.log" 2>&1 \
  || { tail -n 40 "$WORK/build.log"; echo "build en échec"; exit 3; }
/opt/homebrew/bin/rg -N "BUILD (SUCCEEDED|FAILED)" "$WORK/build.log" | tail -n 1 || tail -n 3 "$WORK/build.log"

# --- lancement (bibliothèque ABSENTE : créée par l'app dans $WORK)
set +e
ESCALE_AUTHTEST_DIR="$D" ESCALE_AUTHTEST_PORT="$PORT" ESCALE_AUTHTEST_PASSPHRASE="$PASSPHRASE" \
"$DD/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$WORK/lib/library.json" --ssh-config /dev/null --known-hosts "$D/known_hosts" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null \
  --ssh-config-import-source "$CFG" --keychain-service "$SERVICE" \
  --selftest-auth "$OUT" &
APP_PID=$!
# Garde-fou : 5 minutes maximum.
( sleep 300; kill -9 "$APP_PID" 2>/dev/null ) & WATCHDOG=$!
wait "$APP_PID"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
APP_PID=""
set -e

# --- contrôles externes (hors app)
EXTRA=0
CFG_SUM_AFTER="$(shasum -a 256 "$CFG" | cut -d' ' -f1)"
[ "$CFG_SUM_BEFORE" = "$CFG_SUM_AFTER" ] && echo "ssh_config source inchangé (sha256 $CFG_SUM_AFTER)" || { echo "ERREUR : ssh_config source modifié"; EXTRA=1; }
if security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
  echo "ERREUR : entrée Trousseau résiduelle pour le service $SERVICE"; EXTRA=1
else
  echo "Trousseau : aucune entrée pour le service de test $SERVICE"
fi
if pgrep -f "ssh .*$WORK/" >/dev/null 2>&1; then echo "ERREUR : processus ssh résiduel"; EXTRA=1; else echo "aucun ssh résiduel de la recette"; fi

[ -f "$OUT/result.json" ] && cat "$OUT/result.json" || echo "result.json absent"
if [ -n "${KEEP_OUT:-}" ]; then mkdir -p "$KEEP_OUT"; cp -R "$OUT"/. "$KEEP_OUT"/; cp "$D/sshd.log" "$KEEP_OUT/sshd.log"; fi
echo "code de sortie de l'app : $CODE"
[ "$CODE" -eq 0 ] && [ "$EXTRA" -eq 0 ] || exit 1
