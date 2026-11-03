#!/usr/bin/env bash
# 把编译产物部署成系统安装（需要 root）。幂等，可重复执行。
#
# 做的事：
#   1. cmake --install 到 /usr（二进制、共享库、声库、music-api、模块工具）
#   2. 安装 3 个 systemd 单元：worker@.service、net-proxy、file-daemon
#   3. 安装 polkit 策略（允许 net-policy-helper 改 nftables）
#   4. 建模块只读目录
#   5. 启用并启动 net-proxy 与 file-daemon
#   6. 自检并打印状态
#
# 用法：sudo scripts/deploy.sh [build-dir]   默认 build-dir=pi_terminal/build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/pi_terminal/build}"
PREFIX=/usr

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root：sudo $0 $*" >&2
    exit 1
fi
if [ ! -f "$BUILD/CMakeCache.txt" ]; then
    echo "找不到构建目录 $BUILD，先编译：" >&2
    echo "  cd pi_terminal && source scripts/env.sh && cmake -S . -B build && cmake --build build -j8" >&2
    exit 1
fi

echo "== 1/6 安装到 $PREFIX =="
cmake --install "$BUILD" --prefix "$PREFIX"

echo "== 2/6 systemd 单元 =="
UNITS=/etc/systemd/system
install -Dm644 "$ROOT/pi_terminal/packaging/orange-pi-worker@.service"     "$UNITS/orange-pi-worker@.service"
install -Dm644 "$ROOT/pi_terminal/packaging/orange-pi-net-proxy.service"  "$UNITS/orange-pi-net-proxy.service"
install -Dm644 "$ROOT/pi_terminal/packaging/orange-pi-file-daemon.service" "$UNITS/orange-pi-file-daemon.service"
systemctl daemon-reload

echo "== 3/6 polkit 策略 =="
POLICY="$BUILD/com.orangepi.terminal.network-policy.policy"
if [ -f "$POLICY" ]; then
    install -Dm644 "$POLICY" /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy
else
    echo "  跳过：$POLICY 不存在（没配置过？）"
fi

echo "== 4/6 模块目录 =="
# worker 用 ProtectSystem=strict + ReadOnlyPaths 挂载，必须是 root 拥有、只读。
install -d -m 0755 /usr/lib/orange-pi-terminal/modules
install -d -m 0755 /usr/lib/orange-pi-terminal

echo "== 5/6 启用服务 =="
systemctl enable --now orange-pi-net-proxy.service  || echo "  net-proxy 启动失败，见 journalctl -u orange-pi-net-proxy"
systemctl enable --now orange-pi-file-daemon.service || echo "  file-daemon 启动失败，见 journalctl -u orange-pi-file-daemon"

echo "== 6/6 自检 =="
ok=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "  [ok]   $1"; else echo "  [缺]   $1"; ok=1; fi; }
chk "主程序"          "test -x $PREFIX/bin/orange_pi_terminal"
chk "module_worker"   "test -x $PREFIX/libexec/orange-pi-terminal/module_worker"
chk "net-policy-helper" "test -x $PREFIX/libexec/orange-pi-terminal/net-policy-helper"
chk "network_proxy"   "test -x $PREFIX/bin/network_proxy"
chk "kdf worker"      "test -x $PREFIX/bin/terminal_kdf_worker"
chk "共享库"          "test -f $PREFIX/lib/orange-pi-terminal/libterminal_ui.so"
chk "声库"            "test -d $PREFIX/share/orange-pi-terminal/voices"
chk "polkit 策略"     "test -f /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy"
chk "模块目录"        "test -d /usr/lib/orange-pi-terminal/modules"
chk "net-proxy 运行中" "systemctl is-active --quiet orange-pi-net-proxy"
chk "file-daemon 运行中" "systemctl is-active --quiet orange-pi-file-daemon"

echo
if [ "$ok" -eq 0 ]; then
    echo "部署完成。运行：orange_pi_terminal"
else
    echo "有缺失项，按上面 [缺] 逐条排查（journalctl -u <单元名>）。"
fi
exit "$ok"
