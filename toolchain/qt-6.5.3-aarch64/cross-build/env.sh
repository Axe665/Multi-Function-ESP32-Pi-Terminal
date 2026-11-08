#!/bin/bash
# 交叉编译环境变量。所有路径都可由外部环境覆盖；未指定时按下列顺序自动探测。
#   dist/sdk/{qt653-arm64,host-qt,pi-sysroot}   ← sdk/*.sh 产出的三件套
#   $ORPI_HANDOVER_ROOT/work/...                ← 交接盘布局（向后兼容）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORPI_HANDOVER_ROOT="${ORPI_HANDOVER_ROOT:-$(dirname "$REPO_ROOT")}"

_pick() { for c in "$@"; do [ -e "$c" ] && { echo "$c"; return; }; done; }
# 三件套统一根：默认 dist/sdk/{qt653-arm64,host-qt,pi-sysroot}，
# 也可用 ORPI_SDK_ROOT 指向任意布局相同的目录。
export ORPI_SDK_ROOT="${ORPI_SDK_ROOT:-$REPO_ROOT/dist/sdk}"

export ORPI_QT_PREFIX="${ORPI_QT_PREFIX:-$(_pick \
  "$ORPI_SDK_ROOT/qt653-arm64" \
  "$REPO_ROOT/dist/qt653-arm64" \
  "$ORPI_HANDOVER_ROOT/work/qt653-arm64")}"

export ORPI_HOST_QT="${ORPI_HOST_QT:-$(_pick \
  "$ORPI_SDK_ROOT/host-qt" \
  /opt/Qt/6.5.3/gcc_64)}"

export ORPI_SYSROOT="${ORPI_SYSROOT:-$(_pick \
  "$ORPI_SDK_ROOT/pi-sysroot" \
  "$ORPI_HANDOVER_ROOT/work/pi-sysroot")}"

# 目标机 Debian 12 是 GCC 12：用 13 编译会引用 std::ios_base_library_init，
# 而目标 libstdc++ 没有该符号。优先选 -12，并用包装目录把名字补齐成 gcc/g++。
if [ -z "${ORPI_CROSS_PREFIX:-}" ]; then
  if command -v aarch64-linux-gnu-g++-12 >/dev/null 2>&1; then
    WRAP="$REPO_ROOT/build/toolchain"
    mkdir -p "$WRAP"
    ln -sf "$(command -v aarch64-linux-gnu-gcc-12)" "$WRAP/gcc"
    ln -sf "$(command -v aarch64-linux-gnu-g++-12)" "$WRAP/g++"
    for t in ar ranlib strip nm objcopy; do
      c=$(command -v "aarch64-linux-gnu-$t" 2>/dev/null) && ln -sf "$c" "$WRAP/$t"
    done
    export ORPI_CROSS_PREFIX="$WRAP/"
  else
    export ORPI_CROSS_PREFIX="${ORPI_CROSS_PREFIX:-aarch64-linux-gnu-}"
  fi
fi

# glibc 2.39 头文件会引入 __isoc23_*；用弱符号桩补上，避免目标机 2.36 缺符号。
export ORPI_STUB="${ORPI_STUB:-$REPO_ROOT/cross-build/build/isoc23_compat.o}"
if [ ! -f "$ORPI_STUB" ]; then
  mkdir -p "$(dirname "$ORPI_STUB")"
  "${ORPI_CROSS_PREFIX:-aarch64-linux-gnu-}gcc" \
    ${ORPI_SYSROOT:+--sysroot="$ORPI_SYSROOT"} -O2 -c \
    "$REPO_ROOT/cross-build/isoc23_compat.c" -o "$ORPI_STUB" 2>/dev/null \
    || echo "env.sh: 警告：isoc23 兼容桩编译失败（非致命，目标机若报 GLIBC_2.38 再查）" >&2
fi

export PYTHONPATH="$REPO_ROOT/tools/pyshim:${PYTHONPATH:-}"
[ -n "${ORPI_SYSROOT:-}" ] && {
  export PKG_CONFIG_SYSROOT_DIR="$ORPI_SYSROOT"
  export PKG_CONFIG_LIBDIR="$ORPI_SYSROOT/usr/lib/pkgconfig:$ORPI_SYSROOT/usr/share/pkgconfig"
}
[ -n "${ORPI_HOST_QT:-}" ] && export PATH="$ORPI_HOST_QT/bin:$PATH"
