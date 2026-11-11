#!/bin/bash
# OpenSSL 3.5.9 (LTS) statique universel arm64+x86_64, cible macOS 15.0 (le bottle Homebrew vise la version de l'hote
# et n'est que arm64). Installe dans <travail>/openssl-universal/{include,lib}.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
W=${1:-$HOME/.hermes/cache/scratch/freerdp}
VER=3.5.9
mkdir -p "$W"; cd "$W"
[ -f openssl-$VER.tar.gz ] || curl -fsSL -o openssl-$VER.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$VER/openssl-$VER.tar.gz
shasum -a 256 openssl-$VER.tar.gz
START=$(date +%s)
for A in arm64 x86_64; do
  rm -rf ossl-$A openssl-$VER-$A; mkdir openssl-$VER-$A
  tar xzf openssl-$VER.tar.gz -C openssl-$VER-$A --strip-components=1
  (cd openssl-$VER-$A
   T=darwin64-arm64-cc; [ $A = x86_64 ] && T=darwin64-x86_64-cc
   ./Configure $T no-shared no-tests no-apps no-docs no-module no-legacy no-engine no-dso \
     -mmacosx-version-min=15.0 --prefix="$W/ossl-$A" --openssldir=/etc/ssl >/dev/null
   make -j"$(sysctl -n hw.ncpu)" build_libs >/dev/null 2>&1
   make install_dev >/dev/null 2>&1)
done
rm -rf openssl-universal; mkdir -p openssl-universal/lib
cp -R ossl-arm64/include openssl-universal/
for L in libssl libcrypto; do lipo -create ossl-arm64/lib/$L.a ossl-x86_64/lib/$L.a -output openssl-universal/lib/$L.a; done
lipo -info openssl-universal/lib/libcrypto.a
echo "OPENSSL_SECONDS=$(( $(date +%s) - START ))"
