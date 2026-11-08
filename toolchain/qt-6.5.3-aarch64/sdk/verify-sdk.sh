#!/bin/bash
# 检查交叉编译 pi_terminal 需要的三件套是否齐备；缺什么、怎么补，逐项打印。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/cross-build/env.sh" >/dev/null 2>&1 || true

pass=0; fail=0
row() { printf '%-28s %-10s %s\n' "$1" "$2" "$3"; [ "$2" = PASS ] && pass=$((pass+1)) || fail=$((fail+1)); }
chk() { # name path detail
  if [ -e "$2" ]; then row "$1" PASS "$2"; else row "$1" MISSING "$3"; fi
}
# Qt 6 的 host 工具在 libexec/，不在 bin/
chk_any() { # name detail path...
  local name="$1" detail="$2"; shift 2
  for p in "$@"; do [ -e "$p" ] && { row "$name" PASS "$p"; return; }; done
  row "$name" MISSING "$detail"
}

echo "== 目标机 Qt 开发树 =="
chk "Qt 头文件"        "$ORPI_QT_PREFIX/include/QtCore/qstring.h" "缺 include/：用 sdk/make-dev-sdk.sh 从安装前缀打包"
chk "Qt CMake 配置"    "$ORPI_QT_PREFIX/lib/cmake/Qt6/Qt6Config.cmake" "缺 lib/cmake/Qt6：find_package(Qt6) 会直接失败"
chk "mkspecs"          "$ORPI_QT_PREFIX/mkspecs" "缺 mkspecs：Qt 平台定义不完整"

echo
echo "== host Qt（moc/rcc/qmlcachegen）=="
chk_any "host moc" "缺 host Qt：aqt install-qt linux desktop 6.5.3 linux_gcc_64" \
  "$ORPI_HOST_QT/libexec/moc" "$ORPI_HOST_QT/bin/moc"
chk_any "host qmlcachegen" "缺 host Qt（QML 编译需要）" \
  "$ORPI_HOST_QT/libexec/qmlcachegen" "$ORPI_HOST_QT/bin/qmlcachegen"
chk "host CMake 配置"  "$ORPI_HOST_QT/lib/cmake/Qt6/Qt6Config.cmake" "QT_HOST_PATH 指向的目录必须带 lib/cmake"

echo
echo "== Pi sysroot =="
chk "sysroot libc"     "$ORPI_SYSROOT/lib/aarch64-linux-gnu/libc.so.6" "缺 sysroot：sdk/make-sysroot.sh user@pi"
chk "sysroot 头文件"    "$ORPI_SYSROOT/usr/include" "缺 sysroot 头文件"
chk "sysroot libsqlcipher" "$ORPI_SYSROOT/usr/lib/aarch64-linux-gnu/libsqlcipher.so" "缺 SQLCipher 开发包（目标机 libsqlcipher-dev）"

echo
echo "== 交叉编译器与兼容桩 =="
chk "aarch64 g++"      "$(command -v "${ORPI_CROSS_PREFIX}g++" 2>/dev/null)" "缺交叉编译器：apt install g++-12-aarch64-linux-gnu"
chk "isoc23 兼容桩"     "$ORPI_STUB" "缺桩：cross-build/env.sh 会自动编译，或手动 gcc -c cross-build/isoc23_compat.c"
ver=$("${ORPI_CROSS_PREFIX}g++" -dumpversion 2>/dev/null || echo "?")
echo "编译器版本: $ver（目标机 Debian 12 是 GCC 12，用 13 会缺 std::ios_base_library_init）"

echo
echo "结果: $pass 项就绪, $fail 项缺失"
[ "$fail" -eq 0 ] || echo "提示：sdk/README.md 有每项的产出/获取方法。"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
