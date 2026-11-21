#!/bin/bash
# ForceCommand des sshd du labo : choisit shell fictif / serveur SFTP fictif / commande exec fictive.
# Usage (posé par lab.sh dans sshd_config) : wrapper.sh <dossier hôte>
# Le dossier hôte contient hostenv (variables), root/ (FS fictif), meta.json, bin/ (commandes factices).
H="$1"
# shellcheck disable=SC1091
. "$H/hostenv"
export TZ=UTC
cmd="${SSH_ORIGINAL_COMMAND-}"

# Le PATH affiché est celui d'Ubuntu ; les commandes factices sont des fonctions (vfuncs.sh) qui visent $LABBIN.
# Environnement minimal (pas de SSH_CLIENT : bash croirait être lancé par rshd/sshd et ignorerait BASH_ENV) : rien du vrai utilisateur, de la vraie machine ni de ses chemins.
ENVV=(HOME=/home/deploy USER=deploy LOGNAME=deploy HOSTNAME="$LABHOST" LABHOST="$LABHOST" SHELL=/bin/bash
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin" LABBIN="$H/bin" TERM="${TERM:-xterm-256color}" LANG=en_US.UTF-8 TZ=UTC
  PYTHONDONTWRITEBYTECODE=1 BASH_SILENCE_DEPRECATION_WARNING=1 FAKEROOT="$FAKEROOT" LABDIR="$LABDIR" LABSRC="$LABSRC" LABTMP="$LABDIR/tmp"
  LABMETA="$H/meta.json" LABROOT="$FAKEROOT" BASH_ENV="$LABSRC/vfuncs.sh"
  SSH_CONNECTION="198.51.100.23 52114 $LABIP 22")
[ -n "${SSH_TTY-}" ] && ENVV+=(SSH_TTY=/dev/pts/0)
# Redirection X11 (sshd pose DISPLAY ; le cookie est dans le WORK, cf. xauth-lab de lab.sh).
[ -n "${DISPLAY-}" ] && ENVV+=(DISPLAY="$DISPLAY" XAUTHORITY="$LABDIR/xauthority")

# Sous-système SFTP : sshd lance la commande du Subsystem (marqueur « lab-fake-sftp ») via ForceCommand.
if [ "$cmd" = "lab-fake-sftp" ]; then
  exec /usr/bin/env -i TZ=UTC PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B "$LABSRC/fake_sftp.py" "$FAKEROOT"
fi

cd "$FAKEROOT/home/deploy" || exit 1

if [ -z "$cmd" ]; then
  # Session shell : MOTD seulement avec un terminal, puis faux bash.
  if [ -n "${SSH_TTY-}" ]; then
    /usr/bin/env -i TZ=UTC LABMETA="$H/meta.json" LABROOT="$FAKEROOT" /usr/bin/python3 -B "$LABSRC/fake_cmds.py" motd
  fi
  exec /usr/bin/env -i "${ENVV[@]}" /bin/bash --rcfile "$LABSRC/rc.sh" -i
fi

# Commande exec (sondes de l'app…). Le moniteur lit /proc : on fournit un faux /proc vivant, propre à cette session.
if [[ $cmd == *@@ESC* ]]; then
  P="$H/proc.$$"
  mkdir -p "$P/net"
  /usr/bin/env -i LABMETA="$H/meta.json" LABROOT="$FAKEROOT" TZ=UTC /usr/bin/python3 -B "$LABSRC/fake_cmds.py" procd "$P" &
  UPD=$!
  trap 'kill "$UPD" 2>/dev/null; rm -rf "$P"' EXIT
  trap 'exit 143' TERM HUP
  for _ in $(seq 1 40); do [ -f "$P/uptime" ] && break; sleep 0.05; done
  # Les sondes passent par sh -c (pas de BASH_ENV, donc pas de fonctions) : faux bin en tête du PATH réel.
  ENVV+=(ESC_PROC="$P" ESC_OS=Linux PATH="$H/bin:/usr/bin:/bin")
fi
/usr/bin/env -i "${ENVV[@]}" /bin/bash -c "$cmd"
