#!/bin/bash
# 在 Pi 上以 root 执行：全量安装 Qt 6.5.3 + 项目
set -e
echo "[1/6] 停止占用服务"
systemctl stop orange-pi-net-proxy orange-pi-file-daemon 2>/dev/null || true
pkill -f /usr/bin/network_proxy 2>/dev/null || true
sleep 1
echo "[2/6] 解压"
rm -rf /tmp/orpi-qt653-pi3
tar -xf /tmp/orpi-qt653-pi3.tar.zst -C /tmp
[ -d /tmp/orpi-qt653-pi3/opt/qt653-arm64 ] || { echo "解压失败"; exit 1; }
echo "[3/6] 安装 Qt"
mkdir -p /opt/qt653-arm64
cp -a /tmp/orpi-qt653-pi3/opt/qt653-arm64/. /opt/qt653-arm64/
echo "[4/6] 安装项目"
cp -a /tmp/orpi-qt653-pi3/usr/. /usr/
echo "[5/6] 权限"
chmod 755 /usr/bin/orange_pi_terminal /usr/bin/network_proxy /usr/bin/orange-pi-file-daemon \
          /usr/bin/terminal_kdf_worker /usr/bin/terminal_flite_zh 2>/dev/null || true
find /opt/qt653-arm64 -type d -exec chmod 755 {} +
find /opt/qt653-arm64 -type f -exec chmod 644 {} +
chmod 755 /opt/qt653-arm64/libexec/QtWebEngineProcess /opt/qt653-arm64/libexec/* 2>/dev/null || true
chmod 755 /opt/qt653-arm64/lib/*.so* /opt/qt653-arm64/plugins/platforms/*.so 2>/dev/null || true
find /usr/lib/orange-pi-terminal /usr/libexec/orange-pi-terminal /usr/share/orange-pi-terminal -type d -exec chmod 755 {} + 2>/dev/null || true
find /usr/lib/orange-pi-terminal /usr/share/orange-pi-terminal -type f -exec chmod 644 {} + 2>/dev/null || true
chmod 755 /usr/lib/orange-pi-terminal/*.so* /usr/lib/orange-pi-terminal/modules/*/*.so 2>/dev/null || true
chmod 755 /usr/libexec/orange-pi-terminal/module_worker /usr/libexec/orange-pi-terminal/net-policy-helper 2>/dev/null || true
echo "[6/6] 服务"
systemctl daemon-reload
systemctl start orange-pi-net-proxy 2>/dev/null || true
echo "DEPLOY-DONE"
