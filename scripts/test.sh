#!/bin/bash
# Tests du coeur puis build de l'app. Usage : scripts/test.sh
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
swift test --package-path Packages/EscaleCore
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -project Escale.xcodeproj -scheme Escale -configuration Debug -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation build -quiet
echo "OK : tests et build"
