#!/bin/bash
# 从一份「完整」Qt 安装前缀打出目标机开发树 SDK。
# 交付包 artifacts/ 里只有运行时；编译 pi_terminal 需要 include/lib/cmake/mkspecs/.prl。
# 用法: ./sdk/make-dev-sdk.sh /path/to/qt653-arm64 [输出目录]
set -euo pipefail
SRC=${1:-${ORPI_QT_PREFIX:-}}
OUT_DIR=${2:-$(cd "$(dirname "$0")/.." && pwd)/dist}
[ -n "$SRC" ] && [ -f "$SRC/lib/cmake/Qt6/Qt6Config.cmake" ] || {
  echo "错误: $SRC 不是完整安装前缀（缺 lib/cmake/Qt6/Qt6Config.cmake）" >&2
  echo "      运行时交付包不能用来编译；请先用 cross-build/build-qt653.sh 构建，或解压 dev SDK。" >&2
  exit 1
}
mkdir -p "$OUT_DIR"
NAME=orpi-qt653-aarch64-dev
rm -rf "$OUT_DIR/$NAME"; mkdir -p "$OUT_DIR/$NAME"
for d in include lib mkspecs metatypes modules; do
  [ -d "$SRC/$d" ] && cp -a "$SRC/$d" "$OUT_DIR/$NAME/"
done
# 运行时库只留软链与 .so，去掉 plugins/qml/translations（部署包已有）
find "$OUT_DIR/$NAME/lib" -maxdepth 1 -name '*.prl' -print0 | xargs -0 -r ls >/dev/null 2>&1 || true
{
  echo "Qt: 6.5.3 aarch64 (dev tree)"
  echo "source: $SRC"
  echo "date: $(date '+%F %T %z')"
} > "$OUT_DIR/$NAME/BUILD.txt"
tar -C "$OUT_DIR" -c "$NAME" | zstd -${ZSTD_LEVEL:-19} -T0 -o "$OUT_DIR/$NAME.tar.zst" -f
sha256sum "$OUT_DIR/$NAME.tar.zst" | tee "$OUT_DIR/$NAME.tar.zst.sha256"
echo "产物: $OUT_DIR/$NAME.tar.zst"
