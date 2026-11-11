#!/bin/bash
# Serveur X11 integre : extrait le serveur Xquartz du paquet officiel XQuartz (version et SHA-256 figes), le rend
# autonome (bibliotheques reliees en @rpath, plus aucun chemin /opt/X11) et produit EscaleX11.app.
#
# Usage :
#   scripts/x11-bundle.sh                       prepare le cache (build/x11/EscaleX11.app) et affiche son chemin
#   scripts/x11-bundle.sh --install DIR [--sign ID] [--runtime]
#                                               copie EscaleX11.app dans DIR (Contents/Helpers de l'app) et la signe
#                                               (ID par defaut « - » : ad hoc ; --runtime : runtime durci + horodatage)
# Le paquet (122 Mo) est garde dans ~/Library/Caches/Escale-build ; le cache n'est refait que si ce script change.
set -euo pipefail

XQ_VERSION="2.8.6"
XQ_SHA256="9ac35a505095bfbd3009c3b4772f0c6421e2f79c4210ab908459270d1c447909"
XQ_URL="https://github.com/XQuartz/XQuartz/releases/download/XQuartz-$XQ_VERSION/XQuartz-$XQ_VERSION.pkg"
BUNDLE_ID="com.attila-krb.Escale.X11"
# Outils copies a cote du serveur : xauth (ssh), xkbcomp (clavier), xdpyinfo/xeyes (diagnostic et recettes),
# quartz-wm (gestionnaire de fenetres de XQuartz : barres de titre macOS, mode rootless ; licence APSL 2.0).
TOOLS="xauth xkbcomp xdpyinfo xeyes quartz-wm"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_CACHE="${ESCALE_X11_PKG_CACHE:-$HOME/Library/Caches/Escale-build}"
OUT_DIR="${ESCALE_X11_CACHE:-$ROOT/build/x11}"
APP="$OUT_DIR/EscaleX11.app"
STAMP="$OUT_DIR/stamp"
WANT_STAMP="$XQ_VERSION $(shasum -a 256 "${BASH_SOURCE[0]}" | cut -d' ' -f1)"

log() { echo "x11-bundle: $*" >&2; }

build_cache() {
  if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ] && [ -x "$APP/Contents/MacOS/X11.bin" ]; then return; fi
  mkdir -p "$PKG_CACHE" "$OUT_DIR"
  local pkg="$PKG_CACHE/XQuartz-$XQ_VERSION.pkg"
  if [ ! -f "$pkg" ] || [ "$(shasum -a 256 "$pkg" | cut -d' ' -f1)" != "$XQ_SHA256" ]; then
    log "telechargement de XQuartz $XQ_VERSION"
    curl -fsSL --retry 3 -o "$pkg.part" "$XQ_URL"
    mv "$pkg.part" "$pkg"
  fi
  local sum; sum="$(shasum -a 256 "$pkg" | cut -d' ' -f1)"
  [ "$sum" = "$XQ_SHA256" ] || { log "SHA-256 inattendu ($sum) : paquet refuse"; rm -f "$pkg"; exit 3; }

  WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/escale-x11b.XXXXXX")"
  trap 'rm -rf "$WORK_TMP"' EXIT; local work="$WORK_TMP"
  pkgutil --expand-full "$pkg" "$work/x" >/dev/null
  local payload="$work/x/XQuartzComponent.pkg/Payload"
  local x11="$payload/opt/X11"
  [ -x "$payload/Applications/Utilities/XQuartz.app/Contents/MacOS/X11.bin" ] || { log "X11.bin absent du paquet"; exit 3; }

  rm -rf "$APP" "$OUT_DIR/EscaleX11.app.tmp"
  local tmp="$OUT_DIR/EscaleX11.app.tmp"
  cp -R "$payload/Applications/Utilities/XQuartz.app" "$tmp"
  local c="$tmp/Contents"
  rm -rf "$c/_CodeSignature" "$c/MacOS/X11" "$c/MacOS/X11.sh" 2>/dev/null || true
  # X11.bin est lie a Sparkle (celui de XQuartz) : le framework reste, sans ses programmes de mise a jour
  # (l'app se met a jour avec Escale ; jamais de remplacement du paquet signe par un updater tiers).
  local spk="$c/Frameworks/Sparkle.framework"
  rm -rf "$spk"/Versions/B/{Autoupdate,Updater.app,XPCServices} "$spk"/{Autoupdate,Updater.app,XPCServices}
  mkdir -p "$c/Frameworks" "$c/Resources/xkb" "$c/Resources/fonts"
  for t in $TOOLS; do cp "$x11/bin/$t" "$c/MacOS/$t"; done
  cp -R "$x11/share/X11/xkb/." "$c/Resources/xkb/"
  cp -R "$x11/share/fonts/misc" "$c/Resources/fonts/misc"
  cp "$work/x/Resources/LICENSE.txt" "$c/Resources/XQuartz-LICENSE.txt"
  # quartz-wm est sous Apple Public Source License 2.0 (autorise la redistribution commerciale ; binaire non modifie hors
  # chemins de bibliotheques ; source : https://gitlab.freedesktop.org/xorg/app/quartz-wm, offre dans le fichier ci-dessous).
  cp "$ROOT/scripts/x11-licenses/quartz-wm-APSL-2.0.txt" "$c/Resources/quartz-wm-APSL-2.0.txt"
  cat > "$c/Resources/quartz-wm-SOURCE.txt" <<'TXT'
quartz-wm (gestionnaire de fenetres de XQuartz 2.8.6) - Copyright Apple Inc. - Apple Public Source License 2.0
(texte : quartz-wm-APSL-2.0.txt). Le binaire est celui du paquet XQuartz 2.8.6, dont seuls les chemins de bibliotheques
ont ete modifies (install_name_tool, @rpath). Code source : https://gitlab.freedesktop.org/xorg/app/quartz-wm
et https://github.com/XQuartz/quartz-wm (etiquette de la version XQuartz 2.8.6).
TXT

  # Bibliotheques : copie transitive depuis /opt/X11/lib, identifiants et references en @rpath.
  python3 - "$x11" "$c" $TOOLS <<'PY'
import os, re, shutil, subprocess, sys
root, contents, tools = sys.argv[1], sys.argv[2], sys.argv[3:]
fw = os.path.join(contents, "Frameworks")
def run(*a): subprocess.run(a, check=True, capture_output=True)
def deps(f):
    out = subprocess.run(["otool", "-L", f], capture_output=True, text=True, check=True).stdout
    return sorted(set(re.findall(r"\t(/opt/X11/lib/[^ ]+)", out)))
exes = [os.path.join(contents, "MacOS", n) for n in ["X11.bin"] + tools]
todo, seen = list(exes), set()
while todo:
    f = todo.pop()
    for d in deps(f):
        name = os.path.basename(d)
        dst = os.path.join(fw, name)
        if name not in seen:
            seen.add(name)
            shutil.copy(os.path.realpath(root + d[len("/opt/X11"):]), dst)
            os.chmod(dst, 0o755)
            run("install_name_tool", "-id", "@rpath/" + name, dst)
            todo.append(dst)
        run("install_name_tool", "-change", d, "@rpath/" + name, f)
for f in exes:
    run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", f)
dylibs = [os.path.join(fw, n) for n in os.listdir(fw) if n.endswith(".dylib")]
for f in dylibs:
    run("install_name_tool", "-add_rpath", "@loader_path", f)
left = [f for f in exes + dylibs
        if "/opt/X11/lib" in subprocess.run(["otool", "-L", f], capture_output=True, text=True).stdout]
if left: sys.exit("references /opt/X11 restantes : %s" % left)
print(len(seen), "bibliotheques", file=sys.stderr)
PY

  # Serveur : le seul chemin fige restant (/opt/X11/bin, repertoire de xkbcomp et ajout au PATH) est vide ;
  # xkbcomp est alors cherche dans le PATH, que l'app fixe a Contents/MacOS.
  # Socket Unix de xtrans : /tmp/.X11-unix doit appartenir a root (d'ou le demon privilegie de XQuartz et son sudo).
  # UNIX_DIR devient /private/tmp (root, 1777, pas un lien comme /tmp : lstat de xtrans) et UNIX_PATH le chemin
  # relatif X : le socket est <dossier prive 0700 d'Escale>/X<n> (le serveur fait chdir($HOME), HOME = ce dossier).
  python3 - "$c/MacOS/X11.bin" <<'PY'
import re, sys
p = sys.argv[1]; d = bytearray(open(p, "rb").read())
def patch(old, new):
    hits = [m.start() for m in re.finditer(rb"(?<=\x00)" + re.escape(old) + rb"\x00", bytes(d))]
    if not hits: sys.exit("chaine %r introuvable dans X11.bin (version de XQuartz changee ?)" % old)
    for h in hits: d[h:h + len(new) + 1] = new + b"\x00"
    return len(hits)
patch(b"/opt/X11/bin", b"")
patch(b"/tmp/.X11-unix/X", b"X")
patch(b"/tmp/.X11-unix", b"/private/tmp")
open(p, "wb").write(d)
PY

  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleName Escale X11" \
    -c "Add :CFBundleDisplayName string Escale X11" \
    -c "Set :CFBundleExecutable X11.bin" \
    "$c/Info.plist"
  # Sparkle de XQuartz : sans flux ni verification automatique (les cles publiques restent : Sparkle demarre sans
  # alerte). Aucune mise a jour possible du paquet en dehors de celles d'Escale.
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$c/Info.plist" 2>/dev/null || true
  for k in SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates; do
    /usr/libexec/PlistBuddy -c "Delete :$k" "$c/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$k bool false" "$c/Info.plist"
  done
  # (Pas de rg/grep : la phase de build Xcode n'a pas Homebrew dans son PATH.)
  [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$c/Info.plist")" = "$BUNDLE_ID" ] \
    || { log "Info.plist non modifie"; exit 3; }
  mv "$tmp" "$APP"
  echo "$WANT_STAMP" > "$STAMP"
  log "pret : $APP ($(du -sh "$APP" | cut -f1))"
}

sign_bundle() { # $1 = EscaleX11.app, $2 = identite, $3 = runtime (0/1)
  local app="$1" id="$2" rt="$3"
  local cs=(codesign --force --sign "$id")
  [ "$rt" = 1 ] && cs+=(--options runtime --timestamp)
  # Du plus interne au plus externe : bibliotheques, outils, puis le paquet (executable principal X11.bin).
  for f in "$app"/Contents/Frameworks/*.dylib; do "${cs[@]}" "$f" >/dev/null 2>&1 || "${cs[@]}" "$f"; done
  "${cs[@]}" "$app/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || "${cs[@]}" "$app/Contents/Frameworks/Sparkle.framework"
  for t in $TOOLS; do "${cs[@]}" "$app/Contents/MacOS/$t" >/dev/null 2>&1 || "${cs[@]}" "$app/Contents/MacOS/$t"; done
  "${cs[@]}" "$app" >/dev/null 2>&1 || "${cs[@]}" "$app"
  codesign --verify --deep --strict "$app"
}

INSTALL=""; IDENTITY="-"; RUNTIME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL="$2"; shift 2;;
    --sign) IDENTITY="$2"; shift 2;;
    --runtime) RUNTIME=1; shift;;
    *) echo "option inconnue : $1" >&2; exit 2;;
  esac
done

build_cache
if [ -z "$INSTALL" ]; then echo "$APP"; exit 0; fi
mkdir -p "$INSTALL"
DEST="$INSTALL/EscaleX11.app"
# Recopie et re-signature seulement si le cache, l'identite ou le mode ont change (empreinte gardee hors du paquet :
# un fichier etranger dans Contents/Helpers casserait la signature de l'app).
INSTALL_STAMP="$OUT_DIR/installs/$(printf '%s' "$DEST" | shasum -a 256 | cut -d' ' -f1)"
WANT_INSTALL="$WANT_STAMP $IDENTITY $RUNTIME"
if [ -f "$INSTALL_STAMP" ] && [ "$(cat "$INSTALL_STAMP")" = "$WANT_INSTALL" ] && codesign --verify --strict "$DEST" >/dev/null 2>&1; then
  exit 0
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
sign_bundle "$DEST" "$IDENTITY" "$RUNTIME"
mkdir -p "$(dirname "$INSTALL_STAMP")"
echo "$WANT_INSTALL" > "$INSTALL_STAMP"
log "installe dans $DEST (signature : $IDENTITY)"
