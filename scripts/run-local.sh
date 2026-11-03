#!/usr/bin/env bash
# 无 root / 容器环境的启动器。
#
# 有些环境（CI、受限容器、no_new_privs 的沙箱）根本拿不到 root：
#   sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
# 这时 deploy.sh 一步也做不了，但程序仍可跑起来，只是特权能力降级。
#
# 本脚本把能用户态完成的部分都做了，并把降级的开关设好：
#   - network_proxy 用用户态 runtime 目录跑（不需要 systemd、不需要 root）
#   - ORANGE_PI_MODULE_INPROCESS=1：模块在进程内加载，绕开需要 systemd DynamicUser 的 worker 沙箱
#   - 模块根回落到仓库内的目录，而不是系统目录
#
# 用法：scripts/run-local.sh [--window-size 1024x600]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${TERMINAL_BUILD_DIR:-$ROOT/pi_terminal/build}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp/orpi-runtime-$(id -u)}"

if [ ! -x "$BUILD/orange_pi_terminal" ]; then
    echo "找不到 $BUILD/orange_pi_terminal，先编译：" >&2
    echo "  cd pi_terminal && source scripts/env.sh && cmake -S . -B build && cmake --build build -j8" >&2
    exit 1
fi

mkdir -p "$RUNTIME" 2>/dev/null || true

# 1) 模块：进程内加载。没有 systemd 就没有 DynamicUser/ProtectHome 那套隔离，
#    但至少模块能跑；对外部模块包要自己承担信任风险。
export ORANGE_PI_MODULE_INPROCESS="${ORANGE_PI_MODULE_INPROCESS:-1}"

# 2) 模块根：优先仓库内的（不需要装到 /usr/lib）。
if [ -d "$ROOT/pi_terminal/modules" ] && [ -z "${ORANGE_PI_MODULE_ROOT:-}" ]; then
    export ORANGE_PI_MODULE_ROOT="$ROOT/pi_terminal/modules"
fi

# 3) 网络代理：用户态起一份，策略写在 runtime 目录里。
PROXY_POLICY="$RUNTIME/orange-pi-net-policy.json"
if [ -x "$BUILD/network_proxy" ]; then
    if ! pgrep -f "network_proxy --policy $PROXY_POLICY" >/dev/null 2>&1; then
        ("$BUILD/network_proxy" --policy "$PROXY_POLICY" >"$RUNTIME/net-proxy.log" 2>&1 &)
        sleep 1
    fi
    echo "network_proxy 已启动，策略：$PROXY_POLICY（日志 $RUNTIME/net-proxy.log）"
else
    echo "警告：$BUILD/network_proxy 不存在，出站请求会失败" >&2
fi

# 4) 说明降级项，避免把它当成程序 bug。
cat <<'NOTE'
== 用户态运行（无 root）==
  - 模块沙箱：未启用（没有 systemd DynamicUser / ProtectHome）
  - 系统级网络策略：未启用（nftables 规则需要 root）
  - polkit 授权、文件守护服务：未启用
  其余功能（界面、账户、计算器、时间、本地媒体）不受影响。
NOTE

exec "$BUILD/orange_pi_terminal" "$@"
