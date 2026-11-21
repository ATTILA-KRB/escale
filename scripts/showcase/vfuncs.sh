# Fonctions du faux shell (sourcé par rc.sh en interactif, par BASH_ENV pour `bash -c`).
# Objectif : le shell tourne sur le vrai FS du WORK mais ne montre que des chemins virtuels (/home/deploy…).
# Variables attendues (posées par wrapper.sh) : FAKEROOT, LABHOST, LABDIR, LABSRC, LABTMP.
# Limites : `echo $PWD`, `set`, `which` ou un chemin relatif contenant `..` peuvent encore montrer le réel.

# Commandes factices : fonctions vers $LABBIN, pour que $PATH reste celui d'une Ubuntu (aucun chemin réel).
for _f in "$LABBIN"/*; do _c=${_f##*/}; eval "$_c() { \"\$LABBIN/$_c\" \"\$@\"; }"; done
unset _f _c

# Projette un chemin virtuel absolu sur la racine fictive (si la cible, ou son dossier parent, y existe).
_vmap() {
  local a=$1
  case $a in
    "$FAKEROOT"|"$FAKEROOT"/*) builtin printf '%s' "$a" ;;
    /) builtin printf '%s' "$FAKEROOT" ;;
    /*) if [ -e "$FAKEROOT$a" ] || { [ -n "${a%/*}" ] && [ -d "$FAKEROOT${a%/*}" ]; }; then
          builtin printf '%s' "$FAKEROOT$a"
        else
          builtin printf '%s' "$a"
        fi ;;
    *) builtin printf '%s' "$a" ;;
  esac
}

# _vrun <cmd> <filtrer-stdout 0|1> args… : lance la vraie commande avec chemins projetés, masque FAKEROOT
# dans les messages d'erreur (et dans la sortie si demandé).
_vrun() {
  local c=$1 f=$2 a=() x e rc
  shift 2
  for x in "$@"; do a+=("$(_vmap "$x")"); done
  e=$(mktemp "$LABTMP/err.XXXXXX")
  if [ "$f" = 1 ]; then
    command "$c" "${a[@]}" 2>"$e" | sed -l "s|$FAKEROOT||g"
    rc=${PIPESTATUS[0]}
  else
    command "$c" "${a[@]}" 2>"$e"
    rc=$?
  fi
  sed "s|$FAKEROOT||g" "$e" >&2
  command rm -f "$e"
  return $rc
}

for _c in cat head tail less more wc file touch mkdir rmdir rm cp mv chmod diff; do
  eval "$_c() { _vrun $_c 0 \"\$@\"; }"
done
for _c in find du grep egrep fgrep; do
  eval "$_c() { _vrun $_c 1 \"\$@\"; }"
done
unset _c

# Chemin virtuel du répertoire courant (~ pour le home).
_vp() {
  local p=${PWD#$FAKEROOT}
  [ -z "$p" ] && p=/
  case $p in
    /home/deploy) p='~' ;;
    /home/deploy/*) p="~${p#/home/deploy}" ;;
  esac
  printf '%s' "$p"
}

pwd() { local p=${PWD#$FAKEROOT}; printf '%s\n' "${p:-/}"; }

# Suivi du dossier par l'app (OSC 7 : `printf … "$PWD"` tapé dans le shell) : le chemin réel ne doit jamais sortir.
printf() {
  local a=() x
  for x in "$@"; do x=${x//$FAKEROOT\//\/}; [ "$x" = "$FAKEROOT" ] && x=/; a+=("${x//$FAKEROOT/}"); done
  builtin printf "${a[@]}"
}

cd() {
  local t=${1-$HOME} d
  if [ "$t" = - ]; then t=${OLDPWD:-$FAKEROOT}; t=${t#$FAKEROOT}; t=${t:-/}; fi
  d=$(_vmap "$t")
  builtin cd "$d" 2>/dev/null || { echo "bash: cd: $t: No such file or directory" >&2; return 1; }
  # Jamais au-dessus de la racine fictive (cd .. depuis « / »).
  case $PWD in "$FAKEROOT"|"$FAKEROOT"/*) ;; *) builtin cd "$FAKEROOT" ;; esac
}

# L'environnement ne doit pas exposer les chemins réels du labo.
env() { if [ $# -eq 0 ]; then command env | awk -v a="$LABDIR" -v b="$LABSRC" 'index($0,a)==0 && index($0,b)==0'; else command env "$@"; fi; }
printenv() { if [ $# -eq 0 ]; then env; else command printenv "$@"; fi; }

# Commandes de la machine réelle qu'il ne faut pas laisser parler (processus, réseau, utilisateurs réels).
_nf() { echo "Command '$1' not found, but can be installed with:" >&2; echo "sudo apt install $1" >&2; return 127; }
for _c in top htop lsof netstat ifconfig sw_vers sysctl last scp dscl launchctl ssh sftp ping curl wget; do
  eval "$_c() { _nf $_c; }"
done
unset _c
ps() {
  printf '%s\n' 'USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND' \
    'root           1  0.0  0.1  22568 13184 ?        Ss   Oct02   0:41 /sbin/init' \
    'root         742  0.0  0.1  15440  9216 ?        Ss   Oct02   0:02 sshd: /usr/sbin/sshd -D [listener]' \
    'www-data     816  0.1  0.2  14792  5504 ?        S    Oct02   3:12 nginx: worker process' \
    'deploy      2210  0.0  0.1  21320  5120 pts/0    Ss   09:38   0:00 -bash' \
    'deploy      2318  0.0  0.0  10072  1536 pts/0    R+   09:41   0:00 ps aux'
}

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
