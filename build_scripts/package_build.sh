#!/usr/bin/env bash
# 打包一份可分发的本机成品：~/orpi-builds/<时间戳>-<短 commit>/
#
# 每轮任务收尾都跑这个，用户拿到目录直接运行，不依赖 build/ 目录。
# 目录结构必须与二进制的 RUNPATH 对齐（$ORIGIN/lib/orange-pi-terminal），
# 否则换台机器/换个目录就报 "error while loading shared libraries"。
#
# 用法：
#   ./build_scripts/package_build.sh              # x86_64 成品
#   ./build_scripts/package_build.sh --pi         # 额外打 aarch64 包（需要交叉工具链）
set -euo pipefail

cd "$(dirname "$0")"

want_pi=0
[[ "${1:-}" == "--pi" ]] && want_pi=1

echo "== 构建 x86_64 =="
cmake --build build -j8

tag="$(date +%Y%m%d-%H%M)-$(git rev-parse --short HEAD)"
dest="$HOME/orpi-builds/$tag"
rm -rf "$dest"
mkdir -p "$dest/lib/orange-pi-terminal"

install -m 755 build/orange_pi_terminal "$dest/"
[[ -f build/network_proxy ]] && install -m 755 build/network_proxy "$dest/"
[[ -f build/terminal_kdf_worker ]] && install -m 755 build/terminal_kdf_worker "$dest/"
cp -a build/lib/orange-pi-terminal/. "$dest/lib/orange-pi-terminal/"
# QML 源随包带一份：排查界面问题时不必回头找源码树。
cp -a pi_terminal/qml "$dest/qml"

cat > "$dest/BUILD.txt" <<EOF
commit:   $(git rev-parse HEAD)
date:     $(date -Iseconds)
platform: linux-x86_64 (Qt 6.5.3 SDK)
run:      cd "$dest" && ./orange_pi_terminal --window-size 1024x600
EOF

if [[ $want_pi -eq 1 ]]; then
    echo "== 构建 aarch64 =="
    if [[ ! -f "${PI_TOOLCHAIN:-$HOME/pi-cross/toolchain-pi642.cmake}" ]]; then
        echo "跳过：找不到交叉工具链（${PI_TOOLCHAIN:-$HOME/pi-cross/toolchain-pi642.cmake}）" >&2
        echo "      /tmp 会被清理，工具链不要放那里。" >&2
    else
        cmake -S pi_terminal -B build-pi >/dev/null
        cmake --build build-pi -j8 --target orange_pi_terminal module_worker network_proxy terminal_kdf_worker
        pi_dest="$dest/pi-aarch64"
        mkdir -p "$pi_dest/lib/orange-pi-terminal"
        install -m 755 build-pi/orange_pi_terminal "$pi_dest/"
        [[ -f build-pi/network_proxy ]] && install -m 755 build-pi/network_proxy "$pi_dest/"
        [[ -f build-pi/terminal_kdf_worker ]] && install -m 755 build-pi/terminal_kdf_worker "$pi_dest/"
        [[ -f build-pi/module_worker ]] && install -m 755 build-pi/module_worker "$pi_dest/"
        cp -a build-pi/lib/orange-pi-terminal/. "$pi_dest/lib/orange-pi-terminal/" 2>/dev/null || true
        cp -a pi_terminal/qml "$pi_dest/qml"
        echo "Pi 包：$pi_dest"
    fi
fi

echo
echo "成品：$dest"
du -sh "$dest" | cut -f1
