#!/bin/bash
# Compile le prototype rdpshot contre les bibliotheques statiques produites par build-freerdp.sh.
# OpenSSL 3 est lie statiquement (pas de dependance Homebrew a l'execution).
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
W=${1:-$HOME/.hermes/cache/scratch/freerdp}
I=$W/install
O=${OPENSSL_ROOT:-$W/openssl-universal}
ARCH=${ARCH:-arm64}
HERE=$(cd "$(dirname "$0")" && pwd)
clang -O2 -arch $ARCH -mmacosx-version-min=15.0 -std=gnu11 -Wall \
  -I"$I/include/freerdp3" -I"$I/include/winpr3" -I"$O/include" \
  "$HERE/rdpshot.c" -o "$W/rdpshot-$ARCH" \
  -L"$I/lib" -L"$I/lib/freerdp3" -lfreerdp-client3 -lremdesk-common -lrdpsnd-common -lfreerdp3 -lwinpr3 \
  "$O/lib/libssl.a" "$O/lib/libcrypto.a" -lz -lm -ldl -lpthread \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation \
  -framework Foundation -framework Security -framework SystemConfiguration -framework IOKit -framework AppKit -framework Carbon
echo "OK $W/rdpshot-$ARCH"
