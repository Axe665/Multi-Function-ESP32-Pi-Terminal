#!/bin/bash
# 生成 Pi 交付目录（Qt 运行时 + 项目 + 部署脚本），并打包成 tar.zst。
set -euo pipefail
source "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$REPO/dist}/orpi-qt653-pi3"
rm -rf "$OUT"; mkdir -p "$OUT/opt/qt653-arm64" "$OUT/usr"

# Qt 运行时（去掉 include/cmake/doc/mkspecs/metatypes/modules 和大部分 bin）
cd "$ORPI_QT_PREFIX"
for d in lib plugins qml resources translations libexec; do
  [ -d "$d" ] && cp -a "$d" "$OUT/opt/qt653-arm64/"
done
mkdir -p "$OUT/opt/qt653-arm64/bin"
for t in qmake qmake6 qml qtpaths qtpaths6; do [ -f "bin/$t" ] && cp -a "bin/$t" "$OUT/opt/qt653-arm64/bin/"; done
find "$OUT/opt/qt653-arm64" -name '*.prl' -delete 2>/dev/null || true
find "$OUT/opt/qt653-arm64/lib" -name cmake -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT/opt/qt653-arm64" -name '*.cmake' -delete 2>/dev/null || true

# 项目产物
cp -a "$REPO/src/pi-stage653/usr/." "$OUT/usr/"
rm -rf "$OUT/usr/include" "$OUT/usr/lib/cmake"

# RUNPATH 修正为可重定位形式（Qt 在 /opt/qt653-arm64）
QT=/opt/qt653-arm64/lib
fix_rpath() { file -b "$1" 2>/dev/null | grep -q '^ELF' && patchelf --set-rpath "$2" "$1" || true; }
for f in "$OUT"/usr/bin/*; do fix_rpath "$f" "\$ORIGIN/../lib/orange-pi-terminal:$QT"; done
for f in "$OUT"/usr/lib/orange-pi-terminal/*.so.*; do fix_rpath "$f" "\$ORIGIN:$QT"; done
for f in "$OUT"/usr/libexec/orange-pi-terminal/*; do fix_rpath "$f" "\$ORIGIN/../../lib/orange-pi-terminal:$QT"; done
for f in "$OUT"/usr/lib/orange-pi-terminal/modules/*/*.so; do fix_rpath "$f" "\$ORIGIN/../..:$QT"; done
for f in "$OUT"/opt/qt653-arm64/plugins/platforms/*.so "$OUT"/opt/qt653-arm64/plugins/xcbglintegrations/*.so; do
  fix_rpath "$f" '$ORIGIN/../../lib'
done

cp -a "$REPO/deploy/deploy-pi.sh" "$REPO/docs/部署说明.md" "$OUT/" 2>/dev/null || true
{
  echo "生成时间: $(date '+%F %T %z')"
  echo "Qt: 6.5.3 aarch64 (源码交叉编译)"
  echo "项目: ORPI Terminal (仓库 src/)"
} > "$OUT/BUILD.txt"

mkdir -p "$(dirname "$OUT")"
tar -C "$(dirname "$OUT")" -c "$(basename "$OUT")" | zstd -19 -T0 -o "$OUT.tar.zst" -f
sha256sum "$OUT.tar.zst" | tee "$OUT.tar.zst.sha256"
