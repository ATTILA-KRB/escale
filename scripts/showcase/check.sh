#!/bin/bash
# Contrôle CLI du labo de captures : démarre un labo (ou réutilise ESCALE_LAB_ENV=<env.sh>), joue des commandes ssh/sftp
# et ÉCHOUE (code != 0) si une sortie contient la moindre fuite : nom d'utilisateur réel, /Users, Darwin, nom de la machine,
# dossier de travail réel, « staff »… Vérifie aussi que les sorties sont celles attendues (MOTD, invite, sftp fonctionnel).
# CHECK_INJECT_LEAK=1 ajoute volontairement une commande qui fuit, pour prouver que le contrôle échoue.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SRC/../.." && pwd -P)"
export PATH=/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin   # rg (Homebrew) uniquement pour l'analyse des sorties
OUT="$(mktemp -d "${TMPDIR:-/tmp}/escale-check.XXXXXX")"
ALL="$OUT/all.txt"; : > "$ALL"
FAILS=0
LAB_PID=""

cleanup() {
  trap - EXIT INT TERM
  [ -n "$LAB_PID" ] && kill "$LAB_PID" 2>/dev/null && wait "$LAB_PID" 2>/dev/null
  [ -z "${KEEP:-}" ] && rm -rf "$OUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() { echo "ECHEC : $*" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok    : $*"; }

# --- démarrage du labo
if [ -n "${ESCALE_LAB_ENV:-}" ]; then
  # shellcheck disable=SC1090
  . "$ESCALE_LAB_ENV"
else
  W="$OUT/work"
  ESCALE_LAB_WORK="$W" "$SRC/lab.sh" env > "$OUT/lab.out" 2>&1 &
  LAB_PID=$!
  for _ in $(seq 1 150); do [ -f "$W/env.sh" ] && break; sleep 0.2; done
  [ -f "$W/env.sh" ] || { cat "$OUT/lab.out"; echo "labo non démarré" >&2; exit 2; }
  # shellcheck disable=SC1091
  . "$W/env.sh"
fi
WORK="$ESCALE_LAB_WORK"
cat "$OUT/lab.out" 2>/dev/null | sed -n '1,14p'

SSHO=(-F "$ESCALE_LAB_SSH_CONFIG" -o "UserKnownHostsFile=$ESCALE_LAB_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
  -o "User=$(id -un)" -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -i "$ESCALE_LAB_KEY")
# Délai dur sans dépendance (perl système) : une commande bloquée fait échouer le contrôle au lieu de le suspendre.
T() { /usr/bin/perl -e 'alarm 25; exec @ARGV' -- "$@"; }
WEB=10.40.1.11

# Exécute une commande distante, journalise la sortie (cmd + sortie) dans $ALL, expose $LAST.
run() { # hôte commande…
  local h="$1"; shift
  LAST="$(T /usr/bin/ssh "${SSHO[@]}" "deploy@$h" "$@" 2>&1)"; LAST_RC=$?
  { echo "### ssh $h ${RUN_LABEL:-$*}"; echo "$LAST"; } >> "$ALL"
}
expect() { # motif description
  if printf '%s\n' "$LAST" | rg -q -- "$1"; then ok "$2"; else fail "$2 (motif absent : $1)"; printf '%s\n' "$LAST" | sed 's/^/    | /' | head -15 >&2; fi
}

# 1) shell interactif (-tt) : MOTD + invite façon Debian
SESS="$(printf 'pwd\nwhoami\nhostname\nls\nexit\n' | TERM=xterm-256color T /usr/bin/ssh -tt "${SSHO[@]}" "deploy@$WEB" 2>&1)"
{ echo "### ssh -tt $WEB"; echo "$SESS"; } >> "$ALL"
PLAIN="$(printf '%s' "$SESS" | /usr/bin/perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g')"
LAST="$PLAIN"
expect 'Welcome to Ubuntu 24\.04\.1 LTS' "MOTD Ubuntu"
expect 'deploy@web-01:~\$ pwd' "invite deploy@web-01:~\$"
expect '^/home/deploy$' "pwd = /home/deploy"

# 2) exécutions non interactives
run "$WEB" 'whoami; hostname; uname -a; ls -la; pwd'
expect '^deploy$' "whoami = deploy"
expect '^web-01$' "hostname = web-01"
expect 'Linux web-01 6\.8\.0-48-generic .*Ubuntu|Linux web-01 6\.8\.0-48-generic' "uname Linux 6.8"
expect 'deploy +deploy .* \.bashrc' "ls -la propriétaire deploy"
expect '^/home/deploy$' "pwd virtuel"

# sudo : passe par les commandes factices, jamais d'exec réel (une trace Python révélerait la machine)
run "$WEB" 'sudo systemctl reload nginx && sudo -n systemctl is-active nginx; sudo docker ps; sudo frobnicate; true'
expect '^active$' "sudo systemctl is-active = active"
expect 'app-web-1' "sudo docker ps"
expect 'frobnicate: command not found' "sudo : commande inconnue"
if printf '%s' "$LAST" | rg -q -F -e Traceback; then fail "sudo : trace Python visible"; else ok "sudo sans trace Python"; fi
run "$WEB" 'cat /etc/os-release; df -h; free -h; uptime; id; echo "$HOME $USER $PATH"; env'
expect 'PRETTY_NAME="Ubuntu 24\.04\.1 LTS"' "os-release"
expect '/dev/sda1' "df -h"
expect 'Mem:' "free -h"
expect 'load average' "uptime"
run "$WEB" 'systemctl status nginx; docker ps; journalctl -n 5; tail -n 3 /var/log/nginx/access.log; tail -n 2 /var/log/nginx/error.log'
expect 'Active: .*active \(running\)' "systemctl status nginx"
expect 'app-web-1' "docker ps"
expect '(203\.0\.113|198\.51\.100|192\.0\.2)\.[0-9]+ - - ' "journal nginx (IP de documentation)"
run "$WEB" 'cd /var/www/app && ls -la && cat docker-compose.yml && cd ../../.. && cd .. && pwd && ls / && cat /nonexistent; find /var/www/app -name "*.yml"; du -sh /var/www; grep -rn healthz /var/www/app/src'
expect 'docker-compose\.yml' "projet web"
run 10.40.2.10 'hostname; ls /var/backups/postgres | tail -n 3; cat /etc/postgresql/16/main/postgresql.conf | head -n 3; systemctl status postgresql'
expect '2026-11-1[0-9]\.sql\.gz' "sauvegardes db datées 2026-11"
# Suivi du dossier : fonction OSC 7 exacte de l'app (SFTPFeature.trackingSnippet), chemin virtuel attendu.
SNIP="$(/usr/bin/perl -ne 'print $1 if /trackingSnippet = " (.*); "$/' "$ROOT/Escale/SFTP/SFTPFeature.swift" | /usr/bin/perl -pe 's/\\\\/\\/g; s/\\"/"/g')"
run "$WEB" "$SNIP; cd /var/www/app; __escale_osc7; echo; cd /; __escale_osc7"
expect $'\e]7;file://web-01/var/www/app\a' "OSC 7 virtuel (/var/www/app)"
expect $'\e]7;file://web-01/?\a' "OSC 7 virtuel (racine)"
run 10.40.0.5 'hostname; cat hosts-internes.txt; systemctl status ssh; w; who'
expect 'web-01  10\.40\.1\.11' "bastion"
# Hôte « hors ligne » : vrai échec sur l'IP fictive (le message part dans $ALL, donc dans l'analyse des fuites).
run 10.40.2.11 true
[ "$LAST_RC" -ne 0 ] && ok "hôte hors ligne en échec" || fail "hôte hors ligne joignable"
if printf '%s' "$LAST" | rg -q -F -e 127.0.0.1; then fail "hôte hors ligne : 127.0.0.1 visible"; else ok "hôte hors ligne sans 127.0.0.1"; fi
# Redirection X11 (DISPLAY client fictif, mode Trusted : cookie factice, sans serveur X) : DISPLAY posé par sshd, aucun avertissement xauth (il imprimerait le chemin réel du cookie).
LAST="$(DISPLAY=:99 T /usr/bin/ssh "${SSHO[@]}" -o ForwardX11=yes -o ForwardX11Trusted=yes -o "XAuthLocation=$WORK/xauth-lab" "deploy@$WEB" 'echo "DISPLAY=$DISPLAY"' 2>&1)"
{ echo "### ssh -X $WEB"; echo "$LAST"; } >> "$ALL"
expect '^DISPLAY=localhost:1[0-9]\.0$' "X11 : DISPLAY redirigé"

# 3) sonde de monitoring de l'app (script exact de MonitoringScript.swift, un seul bloc)
BODY="$(/usr/bin/python3 - "$ROOT/Packages/EscaleCore/Sources/EscaleCore/Monitoring/MonitoringScript.swift" <<'PY'
import re, sys, textwrap
s = open(sys.argv[1]).read()
m = re.search(r'#"""\n(.*?)\n\s*"""#', s, re.S)
print(textwrap.dedent(m.group(1)).replace("'", "'\\''"))
PY
)"
RUN_LABEL="(script de monitoring)" run "$WEB" "ESC_ONCE=1 exec sh -c '$BODY'"
expect '^os=Linux$' "monitoring : os=Linux"
expect '^cpu=[0-9]+ [0-9]+$' "monitoring : cpu"
expect '^mem=[0-9]+ [0-9]+$' "monitoring : mem"
expect '^net=eth0 ' "monitoring : net"
expect '^uptime=[0-9]+' "monitoring : uptime"
expect '^disk=' "monitoring : disk"

# 4) fuite volontaire (preuve que le contrôle échoue)
if [ -n "${CHECK_INJECT_LEAK:-}" ]; then
  run "$WEB" '/usr/bin/id -un; /usr/bin/uname -s'
fi

# 5) sftp
SB="$OUT/sftp"; mkdir -p "$SB"; cd "$SB" || exit 2
echo "contenu envoye" > up.txt
cat > batch.txt <<'EOF'
pwd
ls -l
cd /var/www/app
pwd
ls -la
cd releases
ls -l
get /etc/os-release dl-os-release
put up.txt
mkdir nouveau
rename up.txt renomme.txt
ls -l
get renomme.txt dl-renomme.txt
rm renomme.txt
rmdir nouveau
ls
cd /home/deploy
ls -l
cd ../../..
pwd
cd ..
pwd
ls -l
ls /etc/nginx
get /../../../etc/passwd dl-passwd
EOF
T /usr/bin/sftp "${SSHO[@]}" -b batch.txt "deploy@$WEB" > sftp.out 2>&1; SFTP_RC=$?
{ echo "### sftp -b"; cat sftp.out; } >> "$ALL"
LAST="$(cat sftp.out)"
[ "$SFTP_RC" -eq 0 ] && ok "sftp -b sans erreur" || fail "sftp -b code $SFTP_RC"
expect 'Remote working directory: /home/deploy' "sftp pwd virtuel"
expect 'drwxr-xr-x +[0-9]+ deploy +www-data' "sftp longname deploy:www-data"
expect '20261113-2' "sftp releases"
cmp -s dl-os-release <(printf '%s\n' "$(cat "$WORK/hosts/web-01/root/etc/os-release")") && ok "get : contenu identique" || fail "get : contenu différent"
[ "$(cat dl-renomme.txt 2>/dev/null)" = "contenu envoye" ] && ok "put + rename + get relu" || fail "put/rename"
[ ! -e "$WORK/hosts/web-01/root/var/www/app/releases/renomme.txt" ] && [ ! -e "$WORK/hosts/web-01/root/var/www/app/releases/nouveau" ] && ok "rm/rmdir effectifs" || fail "rm/rmdir"
# évasion : lien symbolique pointant hors racine, refusé
ln -s /etc "$WORK/hosts/web-01/root/tmp/evasion"
printf 'ls /tmp/evasion\ncd /tmp/evasion\nget /tmp/evasion/hosts dl-hosts\n' > esc.txt
T /usr/bin/sftp "${SSHO[@]}" -b - "deploy@$WEB" < esc.txt > sftp-esc.out 2>&1
{ echo "### sftp évasion"; cat sftp-esc.out; } >> "$ALL"
[ ! -e dl-hosts ] && ok "lien hors racine refusé" || fail "évasion par lien symbolique possible"
rm -f "$WORK/hosts/web-01/root/tmp/evasion"
# la racine ne s'échappe pas par ..
[ ! -s dl-passwd ] || ! rg -q 'daemon|root:\*' dl-passwd && ok "get /../../etc/passwd reste virtuel" || fail "passwd réel lu"

# 6) analyse des fuites dans TOUTES les sorties
REAL_USER="$(id -un)"; CN="$(scutil --get ComputerName 2>/dev/null || true)"; LH="$(scutil --get LocalHostName 2>/dev/null || true)"
HN="$(hostname)"; HS="$(hostname -s)"
LEAK_PATTERNS=("$REAL_USER" "/Users" "Darwin" "$CN" "$LH" "$HN" "$HS" "$WORK" "$ROOT" "${TMPDIR%/}" "/private/var" "escale-lab" "staff" "scripts/showcase" "wrapper.sh" "fake_sftp" "fake_cmds" "macOS" "Library/Developer" "Traceback" ".hermes")
LEAKS=0
for p in "${LEAK_PATTERNS[@]}"; do
  [ -n "$p" ] || continue
  if rg -n -i -F -e "$p" "$ALL" > "$OUT/leak.txt"; then
    LEAKS=$((LEAKS + 1)); fail "fuite : « $p »"; head -n 5 "$OUT/leak.txt" | sed 's/^/    | /' >&2
  fi
done
[ "$LEAKS" -eq 0 ] && ok "aucune fuite parmi ${#LEAK_PATTERNS[@]} motifs ($(wc -l < "$ALL" | tr -d ' ') lignes analysées)"

echo
if [ "$FAILS" -eq 0 ]; then echo "VERT : tous les contrôles passent"; exit 0; fi
echo "ROUGE : $FAILS échec(s)" >&2; exit 1
