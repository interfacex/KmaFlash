#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/kma-flash-module-cache"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2;; esac
BUILD_FLAGS=(--use-integrated-swift-driver --experimental-explicit-module-build -j 2)
if [[ -n "${KMA_SWIFT_VFS_OVERLAY:-}" ]]; then
  BUILD_FLAGS+=(-Xcc -ivfsoverlay -Xcc "$KMA_SWIFT_VFS_OVERLAY")
fi
if [[ -n "${KMA_SWIFT_SOLVER_LIMIT:-}" ]]; then
  BUILD_FLAGS+=(-Xswiftc -Xfrontend -Xswiftc -solver-memory-threshold -Xswiftc -Xfrontend -Xswiftc "$KMA_SWIFT_SOLVER_LIMIT")
fi
swift build -c release --disable-sandbox "${BUILD_FLAGS[@]}" --arch "$ARCH" --product KmaFlash
BIN_DIR="$(swift build -c release --disable-sandbox --arch "$ARCH" --show-bin-path)"
APP_DIR="$PWD/build/$ARCH/同页.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/KmaFlash" "$APP_DIR/Contents/MacOS/KmaFlash"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/TongyeMark.png "$APP_DIR/Contents/Resources/TongyeMark.png"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# Copy the resource bundle inside the .app, so no source tree is needed at runtime.
rsync -a --delete --delete-excluded --exclude 'StarterMaterials/' "$BIN_DIR/KmaFlash_FlashCore.bundle/" "$APP_DIR/Contents/Resources/KmaFlash_FlashCore.bundle/"
lipo "$APP_DIR/Contents/MacOS/KmaFlash" -verify_arch "$ARCH"
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
