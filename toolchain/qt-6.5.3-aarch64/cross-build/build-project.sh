#!/bin/bash
# 用本仓库的 Qt 6.5.3 aarch64 交叉编译一个 pi_terminal 工程。
# 用法: ./cross-build/build-project.sh [工程根目录]（默认 $ORPI_PROJECT 或 ./src）
set -euo pipefail
source "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${1:-${ORPI_PROJECT:-$REPO/src}}"
JOBS="${JOBS:-$(nproc)}"

missing=0
[ -f "${ORPI_QT_PREFIX:-}/lib/cmake/Qt6/Qt6Config.cmake" ] || { echo "缺目标机 Qt 开发树（ORPI_QT_PREFIX）"; missing=1; }
[ -f "${ORPI_HOST_QT:-}/bin/moc" ] || { echo "缺 host Qt（ORPI_HOST_QT）"; missing=1; }
[ -d "${ORPI_SYSROOT:-}/usr/include" ] || { echo "缺 sysroot（ORPI_SYSROOT）"; missing=1; }
[ -f "$PROJ/pi_terminal/CMakeLists.txt" ] || { echo "找不到 $PROJ/pi_terminal/CMakeLists.txt"; missing=1; }
if [ "$missing" = 1 ]; then
  echo; echo "运行 ./sdk/verify-sdk.sh 查看逐项修复方法。" >&2
  exit 2
fi

BUILD="$PROJ/pi_terminal/build-pi653"
EXTRA=()
# vendored flite 的 configure 不接受带空格的 CC；交叉编译时用预构建树覆盖。
[ -n "${ORPI_FLITE_ROOT:-}" ] && EXTRA+=("-DFLITE_ROOT=$ORPI_FLITE_ROOT")

cmake -S "$PROJ/pi_terminal" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$(dirname "$0")/toolchain-pi653.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DTERMINAL_REPAIR_AUDIT=OFF \
  -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DVLC_ROOT="$ORPI_SYSROOT/usr" -DSQLCIPHER_ROOT="$ORPI_SYSROOT/usr" \
  -DMBEDTLS_ROOT="$ORPI_SYSROOT/usr" -DOPENSSL_ROOT_DIR="$ORPI_SYSROOT/usr" \
  -DCMAKE_PREFIX_PATH="$ORPI_QT_PREFIX;$ORPI_SYSROOT/usr;$ORPI_SYSROOT/usr/lib/aarch64-linux-gnu/cmake" \
  -DQT_HOST_PATH="$ORPI_HOST_QT" "${EXTRA[@]}"

cmake --build "$BUILD" --parallel "$JOBS"

STAGE="$PROJ/pi-stage653"
rm -rf "$STAGE"
DESTDIR="$STAGE" cmake --install "$BUILD" --prefix /usr
echo "项目安装到：$STAGE"
