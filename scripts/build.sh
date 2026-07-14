#!/usr/bin/env bash
# Build Cloak: fetch pinned Zygisk header, compile libcloak.so for all ABIs,
# assemble the flashable Magisk zip. Requires ANDROID_NDK_HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK path}"

# Pinned upstream Zygisk API header (ABI contract). Update deliberately.
ZYGISK_URL="https://raw.githubusercontent.com/topjohnwu/zygisk-module-sample/master/module/jni/zygisk.hpp"

ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")
API=26

echo "==> fetch pinned zygisk.hpp"
curl -fsSL "$ZYGISK_URL" -o "$ROOT/native/zygisk.hpp"

rm -rf "$OUT"
mkdir -p "$OUT/module"

echo "==> compile native libcloak.so"
for abi in "${ABIS[@]}"; do
  bdir="$ROOT/native/.build/$abi"
  cmake -S "$ROOT/native" -B "$bdir" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$bdir" --config Release >/dev/null
  mkdir -p "$OUT/module/zygisk"
  cp "$bdir/libcloak.so" "$OUT/module/zygisk/$abi.so"
  echo "   $abi -> zygisk/$abi.so"
done

echo "==> assemble module tree"
cp -r "$ROOT/magisk-module/." "$OUT/module/"
cp "$ROOT/config/targets.conf" "$OUT/module/targets.conf"
cp "$ROOT/config/props.conf"   "$OUT/module/props.conf"

VER="$(grep '^version=' "$ROOT/magisk-module/module.prop" | cut -d= -f2)"
ZIP="$OUT/cloak-$VER.zip"

echo "==> package $ZIP"
( cd "$OUT/module" && zip -r9 "$ZIP" . -x '.*' >/dev/null )
echo "==> done: $ZIP"
