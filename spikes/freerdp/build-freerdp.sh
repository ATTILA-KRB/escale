#!/bin/bash
# Construit FreeRDP 3.33.1 en bibliotheques statiques (arm64, macOS 15+), sans X11/ffmpeg/CUPS.
# Usage : build-freerdp.sh [dossier_de_travail]   (defaut : ~/.hermes/cache/scratch/freerdp)
# Prerequis de construction seulement : cmake, ninja (Homebrew) et build-openssl.sh execute avant.
# Rien de Homebrew a l'execution (OpenSSL est lie statiquement). ARCHS=arm64 pour une construction mono-architecture.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
W=${1:-$HOME/.hermes/cache/scratch/freerdp}
VER=3.33.1
SHA=6b6da1e7217f924b033da6896e70eb4c4a447c3900d03c0d10179062f0a7d495
OSSL=${OPENSSL_ROOT:-$W/openssl-universal}   # produit par build-openssl.sh
ARCHS=${ARCHS:-arm64;x86_64}
mkdir -p "$W"; cd "$W"
if [ ! -f FreeRDP-$VER.tar.gz ]; then
  curl -fsSL -o FreeRDP-$VER.tar.gz https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$VER.tar.gz
fi
echo "$SHA  FreeRDP-$VER.tar.gz" | shasum -a 256 -c -
[ -d FreeRDP-$VER ] || tar xzf FreeRDP-$VER.tar.gz
START=$(date +%s)
rm -rf build install
cmake -S FreeRDP-$VER -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$W/install" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_MANPAGES=OFF \
  -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_SAMPLE=ON -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_PROXY=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF \
  -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_MACAUDIO=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF -DWITH_AAD=OFF \
  -DWITH_FUSE=OFF -DWITH_OPENH264=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF -DWITH_WEBVIEW=OFF -DWITH_OPUS=OFF -DCHANNEL_URBDRC=OFF -DWITH_VERBOSE_WINPR_ASSERT=OFF -DWITH_JSON_DISABLED=ON -DWITH_CCACHE=OFF -DWITH_LIBUSB=OFF -DWITH_SIMD=ON \
  -DOPENSSL_ROOT_DIR="$OSSL" -DOPENSSL_USE_STATIC_LIBS=TRUE
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
echo "BUILD_SECONDS=$(( $(date +%s) - START ))"
