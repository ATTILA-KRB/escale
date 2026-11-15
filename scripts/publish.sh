#!/bin/bash
# Publie la release de dist/ (produite par scripts/release.sh) sur le site : DMG + appcast Sparkle.
# Usage : scripts/publish.sh [--dry-run]
#   --dry-run : verifie et prepare web/ (fichiers, release.json, build), sans deployer.
# Variables : ESCALE_SITE_URL (defaut https://escale-ssh.vercel.app), ESCALE_SPARKLE_ACCOUNT (defaut escale),
#             ESCALE_VERCEL_SCOPE (defaut attilas-projects-0d91e4d7), ESCALE_VERCEL_PROJECT (defaut escale).
# Ne commite rien : affiche les fichiers a commiter a la fin (web/src/release.json, web/public/updates/appcast.xml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"

SITE="${ESCALE_SITE_URL:-https://escale-ssh.vercel.app}"
FEED="$SITE/updates/appcast.xml"
SPARKLE_ACCOUNT="${ESCALE_SPARKLE_ACCOUNT:-escale}"
SCOPE="${ESCALE_VERCEL_SCOPE:-attilas-projects-0d91e4d7}"
PROJECT="${ESCALE_VERCEL_PROJECT:-escale}"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 64 ;;
  esac
done

UPD="$ROOT/dist/updates"
PUB="$ROOT/web/public/updates"
APP="$ROOT/dist/Escale.app"
VERCEL=(npx -y vercel@latest)
step() { echo; echo "==> $*"; }
die() { echo "ERREUR : $*" >&2; exit 1; }

step "Controle de la release (dist/)"
[ -f "$UPD/appcast.xml" ] || die "dist/updates/appcast.xml absent : lancer scripts/release.sh"
DMGS=("$UPD"/Escale-*.dmg)
[ "${#DMGS[@]}" -eq 1 ] && [ -f "${DMGS[0]}" ] || die "un seul DMG attendu dans dist/updates (trouve : ${#DMGS[@]})"
DMG="${DMGS[0]}"; DMG_NAME="$(basename "$DMG")"
VERSION="$(sed -n 's#.*<sparkle:shortVersionString>\(.*\)</sparkle:shortVersionString>.*#\1#p' "$UPD/appcast.xml" | head -1)"
BUILD="$(sed -n 's#.*<sparkle:version>\(.*\)</sparkle:version>.*#\1#p' "$UPD/appcast.xml" | head -1)"
[ "$DMG_NAME" = "Escale-$VERSION.dmg" ] || die "DMG $DMG_NAME ne correspond pas a la version $VERSION de l'appcast"
[ "$(rg -c '<item>' "$UPD/appcast.xml")" = 1 ] || die "l'appcast doit decrire une seule version"
rg -qF "url=\"$SITE/updates/$DMG_NAME\"" "$UPD/appcast.xml" \
  || die "l'URL du DMG dans l'appcast n'est pas $SITE/updates/$DMG_NAME (ESCALE_DOWNLOAD_URL_PREFIX oublie ?)"
echo "version $VERSION (build $BUILD), $DMG_NAME"

# Une app livree sans le bon flux ne se mettrait plus jamais a jour : bloquant.
APP_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$APP_FEED" = "$FEED" ] || die "SUFeedURL de dist/Escale.app = '$APP_FEED', attendu $FEED"
APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$APP_VER" = "$BUILD" ] || die "CFBundleVersion de l'app ($APP_VER) different du build de l'appcast ($BUILD)"

spctl -a -t install "$DMG" 2>/dev/null || die "Gatekeeper refuse le DMG (notarisation ?)"
xcrun stapler validate -q "$DMG" || die "ticket de notarisation absent du DMG"
SIGN_UPDATE="$(fd -t f '^sign_update$' "$ROOT/build-release/SourcePackages/artifacts" 2>/dev/null | rg -v old_dsa | head -1)"
[ -n "$SIGN_UPDATE" ] || die "sign_update introuvable (lancer scripts/release.sh une fois)"
SIG="$(rg -o 'edSignature="[^"]+' "$UPD/appcast.xml" | head -1 | cut -d'"' -f2)"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$SIG" || die "signature EdDSA de l'appcast invalide"
echo "Gatekeeper, agrafage, signature EdDSA : OK"

# Sparkle compare CFBundleVersion : republier un build inferieur ou egal ne mettrait personne a jour.
LIVE_BUILD="$(curl -fsS "$FEED" 2>/dev/null | sed -n 's#.*<sparkle:version>\(.*\)</sparkle:version>.*#\1#p' | head -1 || true)"
if [ -n "$LIVE_BUILD" ]; then
  [ "$BUILD" -ge "$LIVE_BUILD" ] || die "build $BUILD inferieur au build en ligne ($LIVE_BUILD)"
  [ "$BUILD" -gt "$LIVE_BUILD" ] || echo "attention : build $BUILD deja en ligne (republication)"
fi

step "Preparation de web/"
mkdir -p "$PUB"
# Seul le dernier DMG est servi : l'appcast ne pointe que vers lui, et chaque deploiement reste leger.
find "$PUB" -maxdepth 1 -name 'Escale-*.dmg' ! -name "$DMG_NAME" -print -delete
cp "$DMG" "$UPD/appcast.xml" "$PUB/"
SIZE_MB="$(( ($(stat -f%z "$DMG") + 524288) / 1048576 ))"
cat > "$ROOT/web/src/release.json" <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "dmg": "$DMG_NAME",
  "sizeMB": $SIZE_MB
}
EOF
echo "web/src/release.json : $VERSION, $SIZE_MB Mo"

step "Build du site (Vercel)"
cd "$ROOT/web"
[ -d node_modules ] || npm ci --silent
[ -f .vercel/project.json ] || "${VERCEL[@]}" link --yes --project "$PROJECT" --scope "$SCOPE" >/dev/null
SITE_URL="$SITE" "${VERCEL[@]}" build --prod --yes > "$ROOT/build-release/vercel-build.log" 2>&1 \
  || { tail -20 "$ROOT/build-release/vercel-build.log"; die "build Vercel en echec"; }
cmp -s .vercel/output/static/updates/"$DMG_NAME" "$DMG" || die "DMG absent ou different dans la sortie du build"

if [ "$DRY" = 1 ]; then
  step "--dry-run : rien n'est deploye (sortie dans web/.vercel/output)"
  exit 0
fi

step "Deploiement production"
"${VERCEL[@]}" deploy --prebuilt --prod --yes > "$ROOT/build-release/vercel-deploy.log" 2>&1 \
  || { tail -20 "$ROOT/build-release/vercel-deploy.log"; die "deploiement Vercel en echec"; }

step "Verification en ligne ($SITE)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok=0
for _ in 1 2 3 4 5 6; do # l'alias de production bascule en quelques secondes
  curl -fsS "$FEED?v=$RANDOM" -o "$TMP/appcast.xml" 2>/dev/null && cmp -s "$TMP/appcast.xml" "$UPD/appcast.xml" && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || die "l'appcast en ligne n'est pas celui de dist/updates"
curl -fsS "$SITE/updates/$DMG_NAME" -o "$TMP/$DMG_NAME" || die "DMG non telechargeable"
cmp -s "$TMP/$DMG_NAME" "$DMG" || die "DMG en ligne different de dist/"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$TMP/$DMG_NAME" "$SIG" || die "signature du DMG en ligne invalide"
for p in / /en; do
  # Page lue en entier avant la recherche : `curl | rg -q` echoue sous pipefail (rg ferme la pipe, SIGPIPE).
  page="$(curl -fsS "$SITE$p")" || die "page $p injoignable"
  rg -qF "/updates/$DMG_NAME" <<<"$page" || die "la page $p ne pointe pas vers $DMG_NAME"
done
echo "appcast, DMG (identique, signe), pages FR/EN : OK"

echo
echo "Publie : Escale $VERSION (build $BUILD) sur $SITE"
echo "A commiter : web/src/release.json web/public/updates/appcast.xml"
