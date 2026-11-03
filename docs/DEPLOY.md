# 部署引导（给下一台电脑的 AI / 运维）

这份文档回答一件事：**在一台全新的 Linux 机器上，从 clone 到可用的完整步骤**，
以及哪些步骤不做会出现「没有管理员却进不了开机向导」「沙箱没生效」「helper 缺失」这类症状。

执行顺序固定：**依赖 → 编译 → 部署 → 验收**。前三步缺任何一步都会出现下面「症状表」里的问题。

---

## 0. 先看症状表（对号入座）

| 症状 | 缺哪一步 |
| --- | --- |
| 启动直接进桌面，**没有管理员也不弹开机向导** | 多半是数据库/数据目录没初始化成功；先确认 `~/.local/share/orange-pi-terminal` 可写、SQLCipher 能开库（部署后看 `journalctl`） |
| 模块加载失败、`module_worker` 启动即退出 | 没装 systemd 单元，或 `/usr/libexec/orange-pi-terminal/module_worker` 不存在 |
| 联网功能报错、helper 不存在 | 没执行 `scripts/deploy.sh`（`net-policy-helper` 在 `/usr/libexec/…`，不装就是缺） |
| 模块**沙箱没生效**（能读到 home） | `orange-pi-worker@.service` 没装或没 daemon-reload，worker 没跑在 `DynamicUser` + `ProtectHome` 下 |
| 网络策略不生效 | polkit 策略没装（`com.orangepi.terminal.network-policy.policy`） |

---

## 1. 依赖

```bash
./scripts/bootstrap-deps.sh
```

它会报告 Qt（验证版本 6.5.3，最低 6.4）、GStreamer、X11/OpenGL、Node.js。
加密依赖（OpenSSL/mbedTLS/SQLCipher）**已在 `third_party/vendor/deps`**，不用装。

缺 Qt 时脚本会打印 `aqtinstall` 命令。

## 2. 编译

```bash
cd pi_terminal
source scripts/env.sh          # 指到作者 SDK 的 Qt；或自行 export CMAKE_PREFIX_PATH
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8
```

## 3. 部署（要 root，一步到位）

```bash
sudo ./scripts/deploy.sh            # 默认 build 目录 pi_terminal/build
```

脚本做的事（幂等）：

1. `cmake --install build --prefix /usr` — 主程序、`network_proxy`、`orange-pi-file-daemon`、
   `terminal_kdf_worker`、`module_worker`、`net-policy-helper`、共享库、声库、music-api；
2. 装三个 systemd 单元到 `/etc/systemd/system/`：
   `orange-pi-worker@.service`（模块沙箱）、`orange-pi-net-proxy.service`、`orange-pi-file-daemon.service`；
3. 装 polkit 策略到 `/usr/share/polkit-1/actions/`；
4. 建 `/usr/lib/orange-pi-terminal/modules`（worker 只读挂载点）；
5. `systemctl enable --now` 启动 net-proxy 与 file-daemon；
6. 自检 11 项并打印 `[ok]/[缺]`。

## 4. 验收

```bash
# 服务在跑
systemctl status orange-pi-net-proxy --no-pager
systemctl status orange-pi-file-daemon --no-pager

# 空库启动应当直接进开机向导（没有任何账户）
XDG_DATA_HOME=/tmp/fresh-data XDG_CONFIG_HOME=/tmp/fresh-config orange_pi_terminal --window-size 1024x600
```

预期：出现「开始使用 / 第 1 步，共 5 步」。如果直接进桌面，说明数据目录里已有账户，
换个空的 `XDG_DATA_HOME` 再试。

## 5. 沙箱说明（不是"没部署"，是 systemd 提供的）

模块 worker 的隔离不在应用代码里，而在 `orange-pi-worker@.service`：

- `DynamicUser=yes` + `PrivateNetwork=yes` + `ProtectHome=yes` + `ProtectSystem=strict`
- `NoNewPrivileges=yes`、`RestrictAddressFamilies=AF_UNIX`、`MemoryDenyWriteExecute=yes`
- 模块只能经宿主文件 API 访问数据，worker 完全看不到 home

所以**不装这个单元 = 沙箱不生效**。这是部署步骤，不是编译步骤。

## 6. 网络策略

- 主进程出站由 nftables 白名单限制，脚本 `pi_terminal/packaging/net-egress.sh`，
  按 cgroup 而不是 UID（避免误伤同用户的浏览器/ssh）；
- 代理跑在独立 systemd 单元里（`DynamicUser`），策略文件在 `/run/orpi-net-proxy/policy.json`；
- `net-policy-helper` 通过 polkit 授权改规则，策略文件在 `/usr/share/polkit-1/actions/`。

## 7. 卸载

```bash
sudo systemctl disable --now orange-pi-net-proxy orange-pi-file-daemon
sudo rm -f /etc/systemd/system/orange-pi-{worker@,net-proxy,file-daemon}.service
sudo rm -f /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy
sudo rm -rf /usr/lib/orange-pi-terminal /usr/libexec/orange-pi-terminal
sudo rm -f /usr/bin/{orange_pi_terminal,network_proxy,orange-pi-file-daemon,terminal_kdf_worker}
sudo rm -rf /usr/share/orange-pi-terminal /usr/lib/orange-pi-terminal
```

用户数据在 `~/.local/share/orange-pi-terminal` 与 `~/.config/ModularTerminal`，卸载不清。
