#!/bin/bash
# Tests du coeur puis build de l'app. Usage : scripts/test.sh
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
# Serveur X11 integre (paquet signe ad hoc) : les tests reels d'EmbeddedX11Tests le demarrent.
scripts/x11-bundle.sh --install build/x11-test >/dev/null
ESCALE_X11_TEST_APP="$PWD/build/x11-test/EscaleX11.app" swift test --package-path Packages/EscaleCore
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation build -quiet
echo "OK : tests et build"
