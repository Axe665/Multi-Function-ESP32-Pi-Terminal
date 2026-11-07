#!/bin/bash
# 一键构建 Qt 6.5.3 aarch64（源码 -> 安装树）。
# 前置：cross-build/README.md 里的 apt 依赖、sysroot、Qt 源码、host Qt SDK。
set -euo pipefail
source "$(dirname "$0")/env.sh"

SRC="${QT_SRC:-$ORPI_HANDOVER_ROOT/work/qt653-src/qt-everywhere-src-6.5.3}"
BUILD="${QT_BUILD:-$ORPI_HANDOVER_ROOT/work/qt653-build}"
JOBS="${JOBS:-12}"

[ -d "$SRC" ] || { echo "缺 Qt 源码：$SRC（见 cross-build/README.md）"; exit 1; }
[ -d "$ORPI_SYSROOT" ] || { echo "缺 sysroot：$ORPI_SYSROOT"; exit 1; }

# 1) 兼容桩
mkdir -p "$(dirname "$ORPI_STUB")"
if [ ! -f "$ORPI_STUB" ]; then
  "${ORPI_CROSS_PREFIX}gcc" -O2 -fPIC -c "$(dirname "$0")/isoc23_compat.c" -o "$ORPI_STUB"
  echo "已编译兼容桩：$ORPI_STUB"
fi

# 2) configure（只做一次）
if [ ! -f "$BUILD/CMakeCache.txt" ]; then
  mkdir -p "$BUILD"
  cd "$BUILD"
  "$SRC/configure" \
    -prefix "$ORPI_QT_PREFIX" -extprefix "$ORPI_QT_PREFIX" \
    -release -opensource -confirm-license -nomake examples -nomake tests \
    -qt-host-path "$ORPI_HOST_QT" \
    -device linux-rasp-pi4-aarch64 \
    -device-option CROSS_COMPILE="$ORPI_CROSS_PREFIX" \
    -sysroot "$ORPI_SYSROOT" -opengl es2 \
    -submodules qtbase,qtdeclarative,qtsvg,qtimageformats,qtshadertools,qtmultimedia,qtwebengine,qtwebchannel,qtpositioning,qtserialport,qtconnectivity,qtscxml,qtspeech \
    -skip qt3d,qt5compat,qtcharts,qtcoap,qtdatavis3d,qtgrpc,qthttpserver,qtlanguageserver,qtlocation,qtlottie,qtmqtt,qtnetworkauth,qtopcua,qtpdf,qtquick3d,qtquick3dphysics,qtquickeffectmaker,qtquicktimeline,qtremoteobjects,qtsensors,qtserialbus,qttools,qttranslations,qtvirtualkeyboard,qtwayland,qtwebsocket,qtwebview \
    -DCMAKE_TOOLCHAIN_FILE="$(dirname "$0")/toolchain-pi653.cmake"
fi

# 3) 补丁 + 构建
python3 "$(dirname "$0")/patch-qt-build.py" "$BUILD" "$ORPI_SYSROOT" "$ORPI_STUB"
cd "$BUILD" && ninja -j"$JOBS"

# 4) 安装
cmake --install . --prefix "$ORPI_QT_PREFIX"
echo "Qt 安装完成：$ORPI_QT_PREFIX"
