#!/usr/bin/env bash
# 出两个 deb：orange-pi-terminal 与 orange-pi-terminal-dev。
#
# 需要三件套（可用环境变量覆盖，默认取 toolchain/ 里的 SDK 布局）：
#   ORPI_SYSROOT   Debian 12 aarch64 sysroot
#   ORPI_QT_PREFIX Qt 6.5.3 aarch64 开发树
#   ORPI_HOST_QT   host Qt（只需 moc/qmlcachegen）
#   ORPI_FLITE_ROOT 交叉编译的 flite
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDKROOT="$ROOT/toolchain/qt-6.5.3-aarch64"

export ORPI_SYSROOT="${ORPI_SYSROOT:-$SDKROOT/dist/sdk/pi-sysroot}"
export ORPI_QT_PREFIX="${ORPI_QT_PREFIX:-$SDKROOT/dist/sdk/qt653-arm64}"
export ORPI_HOST_QT="${ORPI_HOST_QT:-/opt/Qt/6.5.3/gcc_64}"
export ORPI_FLITE_ROOT="${ORPI_FLITE_ROOT:-$SDKROOT/dist/sdk/flite-aarch64}"

# 分卷在 Release 上，缺了就先拉（见 tools/fetch_artifacts.sh）
[[ -e "$SDKROOT/artifacts/sdk/pi-sysroot.tar.zst.part00" ]] || "$ROOT/tools/fetch_artifacts.sh"

for p in "$ORPI_SYSROOT" "$ORPI_QT_PREFIX" "$ORPI_HOST_QT" "$ORPI_FLITE_ROOT"; do
    [[ -e "$p" ]] || { echo "缺少 $p；按 toolchain/qt-6.5.3-aarch64/artifacts/sdk/README.md 解包分卷，或设置环境变量" >&2; exit 1; }
done

cd "$ROOT"
exec dpkg-buildpackage -b -aarm64 -us -uc -d "$@"
