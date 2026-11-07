# 部署引导（给下一台电脑的 AI / 运维）

> ## 给接手的 AI：这些是硬性要求，不是建议
>
> 每一步都必须真的执行完，**不能跳过、不能假装成功、不能用替代方案绕开**。
> **部署是必须的，不是可选项。** 直接运行 `./build_scripts/deploy_pi.sh`，它会自己申请 root 权限，
> 终端弹出密码提示后输密码即可完成安装。
>
> 不要只编译不安装，不要改用别的运行方式，不要在没有 systemd 单元的情况下宣称完成。
> 权限申请失败就停下来如实报告，不要绕过。
>
> **必须做的四步，按顺序：**
>
> 1. `./build_scripts/check_deps.sh` — 打印什么就装什么（apt / aqtinstall，照抄执行）；
> 2. 编译，直到 `cmake --build` 退出码为 0；
> 3. `./build_scripts/deploy_pi.sh`（自己申请 root）— **这一步最容易漏，必须执行**，漏了就是：
>    helper 不存在、模块沙箱不生效、网络策略不生效、systemd 服务没有；
> 4. 跑第 4 节的验收：`systemctl status` 两个服务 + 空库启动必须进开机向导。
>
> **跳过第 3 步的典型后果**：应用能启动，但所有需要特权的功能静默失败，
> 使用者会以为是"程序本身有 bug"，实际是没部署。
>
> **不要做的事**
> - 不要只在 build 目录跑二进制就宣称"部署好了"；
> - 不要在有账户的机器上提 PR（会让人以为 OOBE 坏了），见第 7 节；
> - 不要把 Qt SDK 塞进仓库（单文件超 GitHub 100 MB 上限）。

这份文档回答一件事：**在一台全新的 Linux 机器上，从 clone 到可用的完整步骤**，
以及哪些步骤不做会出现「没有管理员却进不了开机向导」「沙箱没生效」「helper 缺失」这类症状。

执行顺序固定：**依赖 → 编译 → 部署 → 验收**。前三步缺任何一步都会出现下面「症状表」里的问题。

---

## 0. 先看症状表（对号入座）

| 症状 | 缺哪一步 |
| --- | --- |
| 启动直接进桌面，**没有管理员也不弹开机向导** | 多半是数据库/数据目录没初始化成功；先确认 `~/.local/share/orange-pi-terminal` 可写、SQLCipher 能开库（部署后看 `journalctl`） |
| 模块加载失败、`module_worker` 启动即退出 | 没装 systemd 单元，或 `/usr/libexec/orange-pi-terminal/module_worker` 不存在 |
| 联网功能报错、helper 不存在 | 没执行 `build_scripts/deploy_pi.sh`（`net-policy-helper` 在 `/usr/libexec/…`，不装就是缺） |
| 模块**沙箱没生效**（能读到 home） | `orange-pi-worker@.service` 没装或没 daemon-reload，worker 没跑在 `DynamicUser` + `ProtectHome` 下 |
| 网络策略不生效 | polkit 策略没装（`com.orangepi.terminal.network-policy.policy`） |

---

## 1. 依赖

```bash
./build_scripts/check_deps.sh
```

分三层报告：

1. **内置**（`third_party/deps`，不用装）：OpenSSL / mbedTLS / SQLCipher；
2. **编译必需**：Qt（目标机基线 6.4.2，开发可用 6.5.3，最低 6.4）、GStreamer 运行时、X11/OpenGL 开发包；
3. **功能级**（缺了不影响编译，但对应功能不可用）：
   `nft`（nftables，网络策略兜底）、`python3`（宠物库与测试脚本）、`espeak-ng`（中文语音播报）、
   可选 `node`（在线音乐 API）、`udisksctl`（U 盘自动挂载）。

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
./build_scripts/deploy_pi.sh                 # 不需要加 sudo，脚本会自己申请提权
```

**这一步必须执行，没有替代路径。** 脚本检测到非 root 时会自动 `exec sudo` 重入，
终端会弹出密码提示——这是预期行为，输密码即可。

脚本做的事（幂等）：

1. `cmake --install build --prefix /usr` — 主程序、`network_proxy`、`orange-pi-file-daemon`、
   `terminal_kdf_worker`、`module_worker`、`net-policy-helper`、共享库、声库、music-api；
2. 装三个 systemd 单元到 `/etc/systemd/system/`：
   `orange-pi-worker@.service`（模块沙箱）、`orange-pi-net-proxy.service`、`orange-pi-file-daemon.service`；
3. 装 polkit：网络策略到 `/usr/share/polkit-1/actions/`，worker 单元规则到
   `/etc/polkit-1/rules.d/50-orpi-worker.rules`（否则用户级终端起不了系统级 worker）；
4. 建 `/usr/lib/orange-pi-terminal/modules`（worker 只读挂载点）；
5. `systemctl enable --now` 启动 net-proxy 与 file-daemon；
6. 自检 11 项并打印 `[ok]/[缺]`。

## 3.5 必须验收：沙箱与网络策略是否真的生效

```bash
./build_scripts/verify_install.sh
```

这不是"文件在不在"的检查，而是**能力检查**：

| 检查 | 含义 |
| --- | --- |
| `orange-pi-worker@.service` 的 `DynamicUser/PrivateNetwork/ProtectHome/ProtectSystem/NoNewPrivileges` | 模块沙箱是否真的存在 |
| `orange-pi-net-proxy`、`orange-pi-file-daemon` active | 代理与文件守护是否在跑 |
| polkit 策略文件 | `net-policy-helper` 能否被授权改 nftables |
| `/run/orpi-net-proxy` | 网络策略文件的落点是否就绪 |

**任何 `[FAIL]` 都表示部署不完整**：此时程序能启动，但沙箱与网络策略缺失，
必须修完再宣称完成。

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

## 7. 提 PR 之前：清掉本机数据残留

**这条是硬要求**。本机跑过之后，`~/.config/ModularTerminal/OrangePiTerminal/users.json`
里会有账户；别人拉到 PR 分支一跑，会**直接进锁屏而不是开机向导**，
很容易被误判成"编译坏了 / OOBE 挂了"。

提 PR 前执行：

```bash
rm -rf ~/.config/ModularTerminal/OrangePiTerminal
rm -rf ~/.local/share/ModularTerminal/OrangePiTerminal
```

想验证「空库首启」而不动自己的数据，用隔离目录：

```bash
XDG_CONFIG_HOME=$(mktemp -d) XDG_DATA_HOME=$(mktemp -d) \
  build/orange_pi_terminal --window-size 1024x600
```

### 程序本身也做了兜底

注册表为空但目录里有上一次的残留时，启动会自动清理（日志：

```
profile: cleared stale data from a previous run: …
onboarding: no users, starting first-run setup
```

清理范围：`auth_locks.json`、`uid_index.key`、`users/`（配置目录），
以及 `arkpets/`、`voice-packs/`、`music-api/`、`music-covers/`、`viper-browser/`、`QtWebEngine/`（数据目录）。
日志文件保留。需要保留现场排查时加 `--keep-stale-data`。

## 8. 卸载

```bash
sudo systemctl disable --now orange-pi-net-proxy orange-pi-file-daemon
sudo rm -f /etc/systemd/system/orange-pi-{worker@,net-proxy,file-daemon}.service
sudo rm -f /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy
sudo rm -rf /usr/lib/orange-pi-terminal /usr/libexec/orange-pi-terminal
sudo rm -f /usr/bin/{orange_pi_terminal,network_proxy,orange-pi-file-daemon,terminal_kdf_worker}
sudo rm -rf /usr/share/orange-pi-terminal /usr/lib/orange-pi-terminal
```

用户数据在 `~/.local/share/orange-pi-terminal` 与 `~/.config/ModularTerminal`，卸载不清。
