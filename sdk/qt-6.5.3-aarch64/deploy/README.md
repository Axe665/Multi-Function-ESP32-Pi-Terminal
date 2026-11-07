# Pi 端部署配置

| 文件 | 目标位置 | 作用 |
| :--- | :--- | :--- |
| `deploy-pi.sh` | `/tmp/`（执行）| 停服务 → 解压 → 装 Qt/项目 → 修权限 → 起服务 |
| `pi-module-terminal.service` | `~/.config/systemd/user/` | 用户服务：启动终端 |
| `99-exec-usr-bin.conf` | `~/.config/systemd/user/pi-module-terminal.service.d/` | 指向新版本、全屏、恢复沙箱 |
| `modular-terminal.desktop` | `~/.config/autostart/` | 登录后 `systemctl --user start` |

```bash
# Pi 上安装
sudo tar -xf orpi-qt653-pi3.tar.zst -C /tmp
sudo bash /tmp/orpi-qt653-pi3/deploy-pi.sh

# 服务与自启
mkdir -p ~/.config/systemd/user/pi-module-terminal.service.d ~/.config/autostart
cp pi-module-terminal.service ~/.config/systemd/user/
cp 99-exec-usr-bin.conf ~/.config/systemd/user/pi-module-terminal.service.d/
cp modular-terminal.desktop ~/.config/autostart/
systemctl --user daemon-reload
systemctl --user restart pi-module-terminal
```

`--demo` 会附加模拟模块 80；接真实模块硬件时去掉它并改成对应的 `--config` 产品配置。
