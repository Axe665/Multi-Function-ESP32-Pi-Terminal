#!/usr/bin/env bash
# 主进程出站白名单（nftables）。
#
# 为什么按 cgroup 而不是 UID：主程序与用户自己的浏览器、终端、ssh 跑在同一个
# UID 下，按 UID 拦会把这些一起断掉。按 cgroup 只约束终端自己的进程树。
#
# 为什么代理必须在另一个 cgroup：主进程只允许连本地回环与局域网，而代理要出外网。
# 两者同 cgroup 的话规则会把代理也拦掉。所以代理跑在独立 systemd 单元里
# （见 docs/networking.md「系统级兜底」）。
#
# 用法：
#   sudo ./net-egress.sh install system.slice/pi-module-terminal.service
#   sudo ./net-egress.sh install user.slice/user-1000.slice/user@1000.service/app.slice/orpi.scope
#   sudo ./net-egress.sh status
#   sudo ./net-egress.sh remove
#
# 卸载就是删表；规则只在表存在期间生效，删表立即恢复。
set -euo pipefail

TABLE=orpi_egress
PROXY_PORTS='{ 34001, 34002, 34003, 34004, 34005 }'

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $EUID -eq 0 ]] || { echo "需要 root（nftables）" >&2; exit 1; }

case "${1:-}" in
install)
    cgroup="${2:-}"
    [[ -n "$cgroup" ]] || usage
    # 规则里的 level = cgroup 相对路径的层数
    level=$(awk -F/ '{print NF}' <<<"$cgroup")
    nft delete table inet "$TABLE" 2>/dev/null || true
    nft -f - <<EOF
table inet $TABLE {
    chain out {
        type filter hook output priority 0; policy accept;

        # 回环：本地代理（34001-34004）与 systemd-resolved 的 stub 都在这里。
        socket cgroupv2 level $level "$cgroup" ip  daddr 127.0.0.0/8 accept
        socket cgroupv2 level $level "$cgroup" ip6 daddr ::1 accept

        # 局域网与链路本地：模块的 BLE/LAN 链路、USB 网卡、邻居发现。
        socket cgroupv2 level $level "$cgroup" ip  daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 169.254.0.0/16 } accept
        socket cgroupv2 level $level "$cgroup" ip6 daddr { fe80::/10, fc00::/7 } accept

        # 其余一律拒绝：TCP 回 RST（快速失败，不让界面等超时），UDP 直接丢。
        socket cgroupv2 level $level "$cgroup" meta l4proto tcp counter reject with tcp reset
        socket cgroupv2 level $level "$cgroup" counter reject
    }
}
EOF
    echo "已加载 inet $TABLE，作用域 cgroup=$cgroup (level $level)"
    echo "代理端口 $PROXY_PORTS 在回环内，无需单独放行。"
    ;;
status)
    nft list table inet "$TABLE" 2>/dev/null || echo "未加载"
    ;;
remove)
    nft delete table inet "$TABLE" 2>/dev/null && echo "已卸载" || echo "本来就没有"
    ;;
*)
    usage
    ;;
esac
