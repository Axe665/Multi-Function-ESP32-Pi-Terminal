#!/usr/bin/env bash
# 本机 systemd user 冒烟：验证 daemon 能否作为 user service 启动并创建 0600 socket。
# 不涉及 Pi 硬件；需要可用的 `systemctl --user` 和已构建的 orange-pi-file-daemon。
set -euo pipefail
DAEMON="${1:-/tmp/pt-build-qt653/orange-pi-file-daemon}"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/orpi-file-smoke.service"
TOKEN="${XDG_RUNTIME_DIR:?}/orpi-file-smoke.token"
SOCKET="${XDG_RUNTIME_DIR}/orpi-file-smoke.sock"

cleanup() {
  systemctl --user stop orpi-file-smoke.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$TOKEN" "$SOCKET"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
trap cleanup EXIT

test -x "$DAEMON" || { echo "missing daemon: $DAEMON" >&2; exit 2; }
mkdir -p "$(dirname "$UNIT")"
printf 'systemd-smoke-token' > "$TOKEN"
chmod 600 "$TOKEN"
cat > "$UNIT" <<EOF
[Unit]
Description=Orange Pi file daemon smoke
[Service]
Type=simple
ExecStart=$DAEMON --socket=%t/orpi-file-smoke.sock --token-file=%t/orpi-file-smoke.token
Restart=no
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user start orpi-file-smoke.service
for _ in $(seq 1 20); do
  systemctl --user is-active --quiet orpi-file-smoke.service && break
  sleep 0.1
done
systemctl --user is-active orpi-file-smoke.service
test -S "$SOCKET"
mode=$(stat -c '%a' "$SOCKET")
test "$mode" = "700" || { echo "unexpected socket mode: $mode" >&2; exit 1; }
echo "systemd user file daemon OK ($SOCKET, mode $mode)"
