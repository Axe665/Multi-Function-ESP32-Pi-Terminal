#!/usr/bin/env bash
# 检查编译所需的外部依赖，缺什么就打印对应的安装命令。
#
# 分两类：
#   1) 已经打包进仓库、不需要安装的：OpenSSL / mbedTLS / SQLCipher
#      —— 在 third_party/vendor/deps，pi_terminal/CMakeLists.txt 会自动找到。
#   2) 体积太大或与系统绑定、必须由使用者提供的：Qt 6.4+、GStreamer、X11/OpenGL、Node.js
#      —— 本脚本只做检查并给出命令，不自动执行（避免动到你的系统）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
missing=0

say_ok()   { printf '  [ok]   %s\n' "$1"; }
say_miss() { printf '  [缺]   %s\n' "$1"; missing=1; }

echo "== 1. 项目内置依赖（无需安装） =="
VENDOR="$ROOT/third_party/vendor/deps"
for item in include/openssl/ssl.h include/mbedtls/ecdsa.h include/sqlcipher/sqlite3.h \
            lib/x86_64-linux-gnu/libcrypto.so lib/x86_64-linux-gnu/libsqlcipher.so; do
    if [ -e "$VENDOR/$item" ]; then say_ok "$item"; else say_miss "$VENDOR/$item"; fi
done

echo "== 2. Qt（必需，体积太大不内置）；验证版本 6.5.3，最低 6.4 =="
QT_OK=""
# 作者 SDK 的默认落点（CMakePresets.json 里也指向这里）
for q in "$HOME/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64" "$HOME/Qt/6.5.3/gcc_64"; do
    [ -x "$q/bin/qmake" ] && QT_OK="$("$q/bin/qmake" -query QT_VERSION 2>/dev/null)" && break
done
if [ -z "$QT_OK" ] && command -v qmake >/dev/null 2>&1; then QT_OK="$(qmake -query QT_VERSION 2>/dev/null)"; fi
if [ -z "$QT_OK" ] && [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    for p in $(echo "$CMAKE_PREFIX_PATH" | tr ':' ' '); do
        [ -x "$p/bin/qmake" ] && QT_OK="$("$p/bin/qmake" -query QT_VERSION)" && break
    done
fi
if [ -n "$QT_OK" ]; then
    say_ok "Qt $QT_OK"
else
    say_miss "Qt 未找到（需要 6.5.3；最低 6.4）"
    cat <<'TIP'
        二选一：
          a) 用官方安装器（需要 Qt 账号，选 Desktop gcc_64 + Qt WebEngine）：
             https://www.qt.io/download-qt-installer
          b) 或用 aqtinstall 命令行装（免登录）：
             python3 -m pip install aqtinstall
             python3 -m aqt install-qt linux desktop 6.5.3 gcc_64 -m qtwebengine qtmultimedia qtimageformats
             装完把 .../6.5.3/gcc_64 加进 CMakePresets 的 CMAKE_PREFIX_PATH，或：
             export CMAKE_PREFIX_PATH=/path/to/6.5.3/gcc_64
TIP
fi

echo "== 3. 系统库（Linux 必需） =="
check_pc() {
    if pkg-config --exists "$1" 2>/dev/null; then say_ok "$2"; else say_miss "$2"; fi
}
# Qt Multimedia 运行时需要 GStreamer；开发包只在自编译多媒体后端时才要，所以放宽检查。
if pkg-config --exists gstreamer-1.0 2>/dev/null || ldconfig -p 2>/dev/null | grep -q libgstreamer-1.0; then
    say_ok "GStreamer（运行时）"
else
    say_miss "GStreamer"
fi
check_pc x11        "X11 开发包"
check_pc gl         "OpenGL 开发包"
if [ "$missing" -eq 1 ]; then
    cat <<'TIP'
        缺系统库时（Debian/Ubuntu）：
          sudo apt install -y build-essential cmake ninja-build pkg-config \
               libgl1-mesa-dev libx11-dev libxkbcommon-dev \
               libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
               gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
               libpulse-dev
TIP
fi

echo "== 4. 可选 =="
if command -v node >/dev/null 2>&1; then say_ok "Node.js $(node --version)（在线音乐 API）"; else say_miss "Node.js（仅在线音乐需要，可跳过）"; fi
if command -v udisksctl >/dev/null 2>&1; then say_ok "udisks2（U 盘自动挂载）"; else say_miss "udisks2（U 盘相关功能需要）"; fi

echo
if [ "$missing" -eq 0 ]; then
    echo "全部就绪，可以编译：build_scripts/build_terminal.sh"
else
    echo "还有缺失项，按上面的提示处理后再编译。"
fi
exit "$missing"
