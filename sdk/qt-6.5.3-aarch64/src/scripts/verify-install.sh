#!/usr/bin/env bash
# 安装验收：确认部署不只是"文件在那儿"，而是沙箱与网络策略真的能用。
#
# 这些检查全部只读，普通用户即可运行（个别项需要 root 时会标注跳过）。
# 任何一项 [FAIL] 都说明部署不完整，不允许宣称完成。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX=/usr
fail=0
ok()   { printf '  [ OK ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=1; }
skip() { printf '  [skip] %s\n' "$1"; }
has()  { eval "$2" >/dev/null 2>&1; }

echo "== 1. 产物 =="
for f in "$PREFIX/bin/orange_pi_terminal" "$PREFIX/bin/network_proxy" \
         "$PREFIX/bin/terminal_kdf_worker" "$PREFIX/bin/orange-pi-file-daemon" \
         "$PREFIX/libexec/orange-pi-terminal/module_worker" \
         "$PREFIX/libexec/orange-pi-terminal/net-policy-helper" \
         "$PREFIX/lib/orange-pi-terminal/libterminal_ui.so" \
         "$PREFIX/share/orange-pi-terminal/voices"; do
    if has "" "test -e '$f'"; then ok "$f"; else bad "$f 不存在"; fi
done

echo "== 2. systemd 单元 =="
for unit in orange-pi-worker@.service orange-pi-net-proxy.service orange-pi-file-daemon.service; do
    if has "" "systemctl cat '$unit'"; then ok "$unit 已安装"; else bad "$unit 未安装"; fi
done

echo "== 3. 模块沙箱属性（这是沙箱是否存在的唯一依据）=="
sandbox_props=$(systemctl show orange-pi-worker@probe.service \
    -p DynamicUser -p PrivateNetwork -p ProtectHome -p ProtectSystem \
    -p NoNewPrivileges -p RestrictAddressFamilies 2>/dev/null || true)
check_prop() {
    local key=$1 want=$2
    if printf '%s\n' "$sandbox_props" | grep -qi "^${key}=${want}"; then
        ok "$key=$want"
    else
        bad "$key 不是 $want（模块沙箱不完整）"
    fi
}
check_prop DynamicUser yes
check_prop PrivateNetwork yes
check_prop ProtectHome yes
check_prop ProtectSystem strict
check_prop NoNewPrivileges yes

echo "== 4. 服务运行状态 =="
for svc in orange-pi-net-proxy orange-pi-file-daemon; do
    if has "" "systemctl is-active --quiet '$svc'"; then ok "$svc 运行中"; else bad "$svc 未运行"; fi
done

echo "== 5. polkit 策略 =="
if has "" "test -f /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy"; then
    ok "network-policy.policy 已安装"
else
    bad "polkit 策略缺失（helper 无法授权改规则）"
fi

echo "== 6. 网络策略 =="
if has "" "test -d /run/orpi-net-proxy"; then
    ok "net-proxy runtime 目录存在"
else
    bad "/run/orpi-net-proxy 不存在（net-proxy 未启动或未部署）"
fi
if [ "$(id -u)" -eq 0 ]; then
    if has "" "nft list ruleset 2>/dev/null | grep -q orpi"; then
        ok "nftables 规则已下发"
    else
        skip "nftables 规则未下发（尚未产生策略事件时会话可接受）"
    fi
else
    skip "nftables 规则检查需要 root"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "验收通过：沙箱与网络策略均已就位。"
else
    echo "验收失败：部署不完整，不要宣称完成。"
fi
exit "$fail"
