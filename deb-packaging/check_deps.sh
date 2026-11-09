#!/usr/bin/env bash
# 检查编译所需的外部依赖，缺什么就打印对应的安装命令。
#
# 分两类：
#   1) 已经打包进仓库、不需要安装的：OpenSSL / mbedTLS / SQLCipher
#      —— 在 third_party/deps，pi_terminal/CMakeLists.txt 会自动找到。
#   2) 体积太大或与系统绑定、必须由使用者提供的：Qt 6.4+、GStreamer、X11/OpenGL、Node.js
#      —— 本脚本只做检查并给出命令，不自动执行（避免动到你的系统）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
missing=0

say_ok()   { printf '  [ok]   %s\n' "$1"; }
say_miss() { printf '  [缺]   %s\n' "$1"; missing=1; }

echo "== 1. 项目内置依赖（无需安装） =="
VENDOR="$ROOT/third_party/deps"
for item in include/openssl/ssl.h include/mbedtls/ecdsa.h include/sqlcipher/sqlite3.h \
            lib/x86_64-linux-gnu/libcrypto.so lib/x86_64-linux-gnu/libsqlcipher.so; do
    if [ -e "$VENDOR/$item" ]; then say_ok "$item"; else say_miss "$VENDOR/$item"; fi
done

# Python 侧（配包/测试才需要）
for mod in cryptography PIL numpy; do
    if python3 -c "import $mod" >/dev/null 2>&1; then say_ok "python: $mod"; else say_miss "python: $mod（pip install -r pi_terminal/tools/requirements.txt）"; fi
done

echo "== 2. Qt（必需，体积太大不内置）；目标机基线 6.4.2（系统包），开发可用 6.5.3，最低 6.4 =="
QT_OK=""
# 作者 SDK 的默认落点（CMakePresets.json 里也指向这里）
for q in "$HOME/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64" "$HOME/Qt/6.5.3/gcc_64"; do
    [ -x "$q/bin/qmake" ] && QT_OK="$("$q/bin/qmake" -query QT_VERSION 2>/dev/null)" && break
done
# 系统 Qt：Debian/Ubuntu 用 qmake6（/usr/bin/qmake 可能不存在）
if [ -z "$QT_OK" ] && command -v qmake6 >/dev/null 2>&1; then QT_OK="$(qmake6 -query QT_VERSION 2>/dev/null)"; fi
if [ -z "$QT_OK" ] && command -v qmake >/dev/null 2>&1; then QT_OK="$(qmake -query QT_VERSION 2>/dev/null)"; fi
if [ -z "$QT_OK" ] && [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    for p in $(echo "$CMAKE_PREFIX_PATH" | tr ':' ' '); do
        [ -x "$p/bin/qmake" ] && QT_OK="$("$p/bin/qmake" -query QT_VERSION)" && break
        [ -x "$p/bin/qmake6" ] && QT_OK="$("$p/bin/qmake6" -query QT_VERSION)" && break
    done
fi
if [ -n "$QT_OK" ]; then
    say_ok "Qt $QT_OK"
else
    say_miss "Qt 未找到（目标基线 6.4.2；开发可用 6.5.3；最低 6.4）"
    cat <<'TIP'
        三种来源任选其一：
          a) 目标机基线：发行版系统包（Debian 12 / Ubuntu 24.04 自带 Qt 6.4.2）
             sudo apt install qt6-base-dev qt6-declarative-dev qt6-webengine-dev \
                  qt6-multimedia-dev qt6-speech-dev qt6-shadertools-dev \
                  qt6-connectivity-dev qt6-serialport-dev qt6-svg-dev qt6-webchannel-dev
             可选（控件字体逐 Scope 覆盖，缺了也能编过）：
                  sudo apt install qt6-declarative-private-dev
          b) 用官方安装器（需要 Qt 账号，选 Desktop gcc_64 + Qt WebEngine）：
             https://www.qt.io/download-qt-installer
          c) 或用 aqtinstall 命令行装（免登录）：
             python3 -m pip install aqtinstall
             # 与目标机完全一致的基线：
             python3 -m aqt install-qt linux desktop 6.4.2 gcc_64 -m qtwebengine qtmultimedia qtshadertools qtconnectivity qtserialport qtscxml
             # 或开发用 6.5.3：
             python3 -m aqt install-qt linux desktop 6.5.3 gcc_64 -m qtwebengine qtmultimedia qtimageformats qtshadertools qtconnectivity qtserialport qtscxml
             装完用 CMakePresets 的 linux-qt642 / linux-qt653，或：
             export OPI_QT_ROOT=/path/to/<version>/gcc_64
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

echo "== 4. 功能级依赖（缺了对应功能不可用，不影响编译） =="
check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then say_ok "$2"; else say_miss "$2"; fi
}
# nft：网络策略用 nftables 兜底；没有它出站控制不生效。
check_cmd nft "nft（nftables，网络策略）"
# python3：宠物库（ArkPets）与测试脚本调用 /usr/bin/python3。
check_cmd python3 "python3（宠物库 / 测试脚本）"
# espeak-ng：中文语音播报引擎。
check_cmd espeak-ng "espeak-ng（语音播报）"

echo "== 5. 可选 =="
if command -v node >/dev/null 2>&1; then say_ok "Node.js $(node --version)（在线音乐 API）"; else say_miss "Node.js（仅在线音乐需要，可跳过）"; fi
if command -v udisksctl >/dev/null 2>&1; then say_ok "udisks2（U 盘自动挂载）"; else say_miss "udisks2（U 盘相关功能需要）"; fi

echo
if [ "$missing" -eq 0 ]; then
    echo "全部就绪，可以编译：build_scripts/build_terminal.sh"
else
    echo "还有缺失项，按上面的提示处理后再编译。"
fi

echo "== 4. 运行时依赖（目标机 / 打包机都要有） =="
have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 视频/电视（libvlc 需要插件，只有 libvlc5 会黑屏）
if have_cmd cvlc || have_cmd vlc || [ -d /usr/lib/x86_64-linux-gnu/vlc/plugins ] || [ -d /usr/lib/aarch64-linux-gnu/vlc/plugins ]; then
    say_ok "VLC 插件（视频/电视）"
else
    say_miss "VLC 插件：sudo apt install -y vlc-plugin-base   # 只有 libvlc5 会黑屏"
fi

# 桌宠转换器：java + javac 都要
if have_cmd java && have_cmd javac; then
    say_ok "JDK（桌宠转换器）"
else
    say_miss "JDK 17：sudo apt install -y openjdk-17-jdk-headless   # 缺它桌宠无法下载/切换模型"
fi

# 本地音乐元数据/封面
if have_cmd ffprobe && have_cmd ffmpeg; then
    say_ok "ffmpeg/ffprobe（音乐元数据）"
else
    say_miss "ffmpeg：sudo apt install -y ffmpeg"
fi

# 网易云 API 的 npm 依赖（不在 Debian 源，必须提前装好再打包）
if [ -d "$ROOT/pi_terminal/music_api/node_modules/@neteaseapireborn" ]; then
    say_ok "music_api node_modules（在线音乐 API）"
else
    say_miss "music_api node_modules：bash pi_terminal/scripts/install-music-api.sh（打包前必须）"
fi

# Python 图像依赖（桌宠图集）
if python3 -c 'import PIL' >/dev/null 2>&1; then
    say_ok "python3 PIL（桌宠图集）"
else
    say_miss "python3-pil：sudo apt install -y python3-pil"
fi

exit "$missing"
