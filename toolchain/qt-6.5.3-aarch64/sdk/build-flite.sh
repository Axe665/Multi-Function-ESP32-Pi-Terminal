#!/bin/bash
# 交叉编译 vendored flite（项目 CMake 内联构建在交叉场景会失败：
# 它把 "gcc --target=... --sysroot=..." 作为带空格的 CC 传给 configure）。
# 产物配合 cross-build/build-project.sh 的 ORPI_FLITE_ROOT 使用。
# 用法: ./sdk/build-flite.sh <flite 源码目录> [输出目录]
set -euo pipefail
SRC=${1:?用法: build-flite.sh <flite-src> [out]}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/cross-build/env.sh"
OUT=${2:-$REPO/build/flite}
rm -rf "$OUT"; cp -a "$SRC" "$OUT"
cd "$OUT"
CC="${ORPI_CROSS_PREFIX}gcc" CXX="${ORPI_CROSS_PREFIX}g++" \
CFLAGS="--sysroot=$ORPI_SYSROOT -O2 -fPIC" LDFLAGS="--sysroot=$ORPI_SYSROOT" \
  ./configure -q --with-audio=none --host=aarch64-linux-gnu
make -C src -j"$(nproc)"
make -C lang/cmulex -j"$(nproc)"
make -C lang/usenglish -j"$(nproc)"
echo "flite 就绪：$OUT"
echo "用法：export ORPI_FLITE_ROOT=$OUT"
