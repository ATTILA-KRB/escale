#!/bin/bash
# Captures du site : rejoue --selftest-showcase contre le labo déjà démarré (lab.sh env), puis recadre (crops.py).
# Usage : ESCALE_LAB_WORK=<dossier du labo> scripts/showcase/shots.sh <dossier des captures brutes>
#         ESCALE_SHOWCASE_HERO=1 … : héros du site seul (fenêtre 1280×800), à copier en 00-hero.png.
# Build préalable : xcodebuild … -configuration Debug -derivedDataPath build (voir AGENTS.md).
# L'app Debug partage le domaine de préférences de l'app installée (com.attila-krb.Escale) : AppKit y enregistre
# le cadre de la fenêtre et des volets. On restaure ces clés après le passage (les autres sont laissées à l'app réelle).
W=${ESCALE_LAB_WORK:?ESCALE_LAB_WORK : dossier du labo}
O=${1:?dossier des captures brutes}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=com.attila-krb.Escale
rm -rf "$O"; mkdir -p "$O"; rm -f "$W/macros.json"
defaults export $D "$O/.defaults-avant.plist"
"$ROOT/build/Build/Products/Debug/Escale.app/Contents/MacOS/Escale" \
  --library "$W/library.json" --ssh-config "$W/ssh_config" --known-hosts "$W/known_hosts" \
  --ssh-option IdentityAgent=none --ssh-option GlobalKnownHostsFile=/dev/null --ssh-option "User=$(id -un)" \
  --selftest-showcase "$O" > "$O/app.log" 2>&1 &
P=$!
( sleep 300; kill $P 2>/dev/null ) &
G=$!
wait $P; rc=$?
kill $G 2>/dev/null
defaults export $D "$O/.defaults-apres.plist"
python3 - "$O/.defaults-avant.plist" "$O/.defaults-apres.plist" <<'EOF'
import plistlib, subprocess, sys
avant, apres = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
for k in sorted(set(avant) | set(apres)):
    if not (k.startswith("NSSplitView") or k.startswith("NSWindow Frame") or k.startswith("NSToolbar")):
        continue
    if avant.get(k) == apres.get(k):
        continue
    if k in avant:
        apres[k] = avant[k]
    else:
        apres.pop(k, None)
    print("préférence restaurée :", k)
plistlib.dump(apres, open(sys.argv[2], "wb"))
subprocess.run(["defaults", "import", "com.attila-krb.Escale", sys.argv[2]], check=True)
EOF
rm -f "$O/.defaults-avant.plist" "$O/.defaults-apres.plist"
echo "exit=$rc"
