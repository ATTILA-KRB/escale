#!/bin/bash
# Release signee Developer ID, notarisee, DMG, appcast Sparkle. Ne publie RIEN (tout reste dans dist/).
# Usage : scripts/release.sh [--version X.Y.Z] [--build N] [--skip-notarize] [--no-dmg-style]
# Variables (voir docs/RELEASE.md) :
#   ESCALE_SIGN_IDENTITY   identite codesign (defaut : hash du certificat Developer ID de Rayan, team 5FMH389VS7)
#   ESCALE_NOTARY_KEY      chemin de la cle API .p8 (jamais copiee ici) ; ESCALE_NOTARY_KEY_ID ; ESCALE_NOTARY_ISSUER
#   ESCALE_FEED_URL        URL du flux Sparkle (defaut : https://escale-ssh.vercel.app/updates/appcast.xml) ;
#                          ESCALE_FEED_URL= (vide explicite) = build sans mises a jour
#   ESCALE_DOWNLOAD_URL_PREFIX  prefixe des URL de DMG dans l'appcast (defaut : https://escale-ssh.vercel.app/updates/)
#   ESCALE_SPARKLE_ACCOUNT compte Trousseau de la cle EdDSA (defaut : escale)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/bin:$PATH"

IDENTITY="${ESCALE_SIGN_IDENTITY:-D0F93EE12C167056F3206C7CB7D208C0952E9728}"
TEAM="5FMH389VS7"
# Lue par project.yml (CODE_SIGN_IDENTITY Release) ; pas de CODE_SIGN_IDENTITY en ligne de commande : il
# s'appliquerait aussi aux cibles des paquets SwiftPM (SwiftTerm) et ferait echouer l'archive.
export ESCALE_SIGN_IDENTITY="$IDENTITY"
NOTARY_KEY="${ESCALE_NOTARY_KEY:-$HOME/Downloads/05_Technique/AuthKey_G7JK2CFPL3.p8}"
NOTARY_KEY_ID="${ESCALE_NOTARY_KEY_ID:-G7JK2CFPL3}"
NOTARY_ISSUER="${ESCALE_NOTARY_ISSUER:-fd7a9e88-3c53-47c3-a128-f044f3aabd52}"
# Flux fige dans les apps livrees depuis la 1.0.0 : ne pas le changer (les installations ne le suivraient pas).
FEED_URL="${ESCALE_FEED_URL-https://escale-ssh.vercel.app/updates/appcast.xml}"
export ESCALE_DOWNLOAD_URL_PREFIX="${ESCALE_DOWNLOAD_URL_PREFIX-https://escale-ssh.vercel.app/updates/}"
SPARKLE_ACCOUNT="${ESCALE_SPARKLE_ACCOUNT:-escale}"

VERSION="" BUILD="" SKIP_NOTARIZE=0 STYLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --no-dmg-style) STYLE=0; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 64 ;;
  esac
done
[ -n "$VERSION" ] || VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$BUILD" ] || BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

DIST="$ROOT/dist"
WORK="$ROOT/build-release"
APP="$DIST/Escale.app"
DMG="$DIST/Escale-$VERSION.dmg"
step() { echo; echo "==> $*"; }

notarize() { # $1 = fichier (zip ou dmg)
  [ -f "$NOTARY_KEY" ] || { echo "cle API introuvable : $NOTARY_KEY" >&2; exit 2; }
  local out id
  out="$(xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait 2>&1)" \
    || { echo "$out"; }
  echo "$out" | tail -n 8
  id="$(echo "$out" | sed -n 's/^ *id: *//p' | head -1)"
  if ! echo "$out" | rg -q "status: Accepted"; then
    echo "notarisation refusee ; journal :" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2
    exit 3
  fi
}

step "Version $VERSION ($BUILD), identite $IDENTITY"
rm -rf "$DIST" "$WORK/Escale.xcarchive"; mkdir -p "$DIST" "$WORK"

step "xcodegen"
xcodegen generate --quiet

step "Archive Release"
xcodebuild archive -project Escale.xcodeproj -scheme Escale -configuration Release \
  -archivePath "$WORK/Escale.xcarchive" -derivedDataPath "$WORK" \
  -skipPackagePluginValidation -skipMacroValidation -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" ESCALE_FEED_URL="$FEED_URL"
ditto "$WORK/Escale.xcarchive/Products/Applications/Escale.app" "$APP"

step "Re-signature des composants Sparkle (Developer ID + runtime + horodatage)"
# Xcode ne re-signe pas les XPC/Updater imbriques de Sparkle avec notre identite : Apple refuserait l'app.
# Ordre de Sparkle : du plus interne au plus externe, puis l'app (entitlements conserves).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
CS=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
for x in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [ -e "$x" ] && "${CS[@]}" --preserve-metadata=entitlements "$x"
done
"${CS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${CS[@]}" --preserve-metadata=entitlements,identifier "$APP"

step "Verification de la signature"
# Le helper d'askpass est le binaire principal (AskpassClient.runIfRequested en tete de main). Le serveur X11 integre
# (Contents/Helpers/EscaleX11.app) est signe Developer ID + runtime par la phase de build (scripts/x11-bundle.sh).
[ -x "$APP/Contents/Helpers/EscaleX11.app/Contents/MacOS/X11.bin" ] || { echo "serveur X11 integre absent" >&2; exit 4; }
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | rg "Authority|TeamIdentifier|flags|Timestamp|Identifier="
rg -q "runtime" <(codesign -dv "$APP" 2>&1) || { echo "runtime durci absent" >&2; exit 4; }
# Tout Mach-O embarque (hors liens symboliques) doit porter notre equipe, le runtime durci et un horodatage.
NMACHO=0
while IFS= read -r f; do
  file -b "$f" | rg -q "Mach-O" || continue
  NMACHO=$((NMACHO+1))
  info="$(codesign -dvv "$f" 2>&1)"
  for need in "TeamIdentifier=$TEAM" "Timestamp=" "(runtime)"; do
    echo "$info" | rg -qF -- "$need" || { echo "signature incomplete ($need) : $f" >&2; exit 4; }
  done
done < <(find "$APP/Contents" -type f)
echo "$NMACHO binaires Mach-O verifies (equipe, runtime, horodatage)"
echo "Entitlements :"; codesign -d --entitlements - "$APP" 2>&1 | rg -v "^Executable" || true

if [ "$SKIP_NOTARIZE" = 0 ]; then
  step "Notarisation de l'app"
  ditto -c -k --keepParent "$APP" "$WORK/Escale-app.zip"
  notarize "$WORK/Escale-app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -t exec -vv "$APP"
else
  echo "(--skip-notarize : notarisation ignoree ; spctl refusera l'app)"
fi

step "DMG"
BG="$WORK/dmg-background.png"
python3 - "$BG" <<'PY'
# Fond simple 660x400 (gris tres clair, bandeau plus fonce en bas), PNG ecrit a la main (stdlib seule).
import sys, zlib, struct
w, h = 660, 400
rows = b"".join(b"\x00" + (bytes((244, 244, 246)) if y < h - 60 else bytes((228, 228, 232))) * w for y in range(h))
def chunk(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
PY
STAGE="$WORK/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"; ditto "$APP" "$STAGE/Escale.app"
rm -f "$DMG"
CD_ARGS=(--volname "Escale" --window-pos 200 120 --window-size 660 400 --icon-size 112
  --icon "Escale.app" 170 190 --hide-extension "Escale.app" --app-drop-link 490 190 --background "$BG" --no-internet-enable)
[ "$STYLE" = 1 ] || CD_ARGS+=(--skip-jenkins)
create-dmg "${CD_ARGS[@]}" "$DMG" "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "$SKIP_NOTARIZE" = 0 ]; then
  step "Notarisation du DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

step "Appcast Sparkle"
GEN="$(find "$WORK/SourcePackages/artifacts" -name generate_appcast -type f -path "*Sparkle/bin/*" | head -1)"
if [ -z "$GEN" ]; then echo "generate_appcast introuvable (Sparkle non resolu ?)" >&2; exit 5; fi
UPD="$DIST/updates"; mkdir -p "$UPD"; cp "$DMG" "$UPD/"
GA_ARGS=(--account "$SPARKLE_ACCOUNT")
[ -z "${ESCALE_DOWNLOAD_URL_PREFIX:-}" ] || GA_ARGS+=(--download-url-prefix "$ESCALE_DOWNLOAD_URL_PREFIX")
"$GEN" "${GA_ARGS[@]}" "$UPD"
ls -l "$UPD"

step "Termine : $DMG"
[ -n "$FEED_URL" ] || echo "NB : ESCALE_FEED_URL vide, cette build n'interroge aucun flux (mises a jour desactivees)."
echo "Rien n'a ete publie : voir docs/RELEASE.md pour mettre en ligne le DMG et appcast.xml."
