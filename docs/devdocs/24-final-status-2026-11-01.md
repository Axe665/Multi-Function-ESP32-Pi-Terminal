# 2026-11-01 收尾状态：UI、联网策略、模块 API、文件 daemon

本文是这一轮改造的交接入口。代码、测试、构建环境与已知缺口都以本文和仓库当前
commit 为准；不要用旧快照文档推断“已经完成”。

## 1. 当前版本

- 项目根：`bundle/orpi-terminal-20261031/pi-terminal`
- 当前分支：`master`
- 本轮最后功能提交：`d038824 feat(modules): put grants in root policy and add session write grants`
- 文档提交：`481d932 docs(files): flag user-cache module root as a ProtectHome blocker`
- 本文件提交后以 `git log` 为准。
- 构建目录（本机，不在仓库内）：`/tmp/pt-build-qt653`
- 作者 SDK：Qt 6.5.3 `~/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64`

## 2. 已完成

### 2.1 全局字体与开发者选项

- `src/main.cpp` 先加载 Google Sans，再创建临时 `QQmlEngine` 预热
  `QtQuick.Controls`，抓取所有 `QQuickTheme` scope 的原始字体，只替换 `family`，
  保留原字号；Material 控件不再落回 Roboto。
- 普通 Text 走应用字体；代码/JSON/安全状态继续 monospace。
- `qml/ReadOnlyTextView.qml`：只读、不可选中；按住拖动和滚轮可纵向/横向平移；
  测试输出可 `followEnd`。
- `qml/DeveloperPanel.qml`、`qml/TestModePanel.qml` 已换用该组件。

### 2.2 联网策略 v2

- root 策略：`/etc/orange-pi-terminal/network-policy.json`，schema
  `orpi-net-policy-v2`、version 2。
- 删除域名 allowlist；只保留六个内置应用的 `{enabled}` 开关。
- v1 迁移：保留启用状态，丢弃 hosts。
- 本地代理策略 version 4；通道只有 `{enabled}`；目标只允许公网地址。
- `PublicNetwork` 拒绝 loopback、RFC1918、CGNAT、link-local、ULA、multicast、
  broadcast 和保留地址；音乐 `127.0.0.1:3000` 是唯一本地例外。
- 管理员 PIN 保存；helper 以 root 写固定系统路径。

### 2.3 第三方模块 API v2

- manifest 强制声明 `platform_api:1`、`network_api`、`file_api`；
  旧 manifest 和 API v1 在加载前拒绝。
- `PI_MODULE_API_VERSION = 2`；worker 侧导出函数和宿主侧都要版本一致。
- 网络：
  - `AppNetworkBroker`：异步 HTTP(S)、每 appId 独立 QNAM/cookie、16 MiB、
    30 s、5 次重定向、禁止敏感请求头。
  - `AppNetworkApi`：QML `appNetwork.request()`；独立 `QQmlEngine` 安装 NAM
    工厂，XMLHttpRequest/Image 也走同一权限判定。
  - C 模块：`pi_host_services.network_request()` 经 worker
    `appRequest`/`appResponse` 同步转发到同一 broker。当前只保证在模块数据/
    动作回调内可靠；模块独立线程/定时器请求需要后续异步读循环。
- 文件：
  - 每用户 `orange-pi-file-daemon`，Unix socket + 0700 + token 文件；
    模块 worker 是 DynamicUser，不能直连。
  - `FileApiBroker`/`FileApi`；QML `appFiles.request()`；C
    `pi_host_services.file_request()`。
  - 家目录只读；每包
    `~/.local/share/orange-pi-terminal/apps/<manifest.id>/` 可写；
    `.ssh`、`.gnupg`、`.pki`、`.password-store`、keyrings、浏览器/终端配置、
    其他应用数据、`.netrc`、`.git-credentials` 拒绝。
  - 分块读写，单块 1 MiB；stat/list/read/write/mkdir/rename/remove/ping。
  - `appFiles.requestWriteAccess()` 让用户选择单个文件或目录；默认 24 小时
    有效，写授权按 manifest id 持久化，应用重启后恢复未过期授权。
  - daemon 不信任请求里的 root：宿主用每用户会话 token 对
    `{appId, appRoot, readRoot, writeRoot, expires}` 做 HMAC-SHA256，
    daemon 校验签名和过期时间后才使用这些 root。模块无法伪造 app 能力。
  - `FileApi.writeGrantExpiresAt` 向模块暴露过期时间；卸载只撤销当前 token，
    持久授权仍在到期前可恢复。
- 管理员授权：
  - 第三方模块网络/文件授权写入 root 策略的 `modules` 对象，按 manifest id
    保存；与内置应用一起经管理员 PIN 保存。
  - `NetworkGate` 只保存运行期实例判定，缺省拒绝。
  - 信任弹窗披露 `network.broker`/`files.home_read`，并明确“信任签名不授予
    网络或文件权限”。

### 2.4 沙箱与模块包

- worker unit：`DynamicUser=yes`、`PrivateNetwork=yes`、`PrivateTmp=yes`、
  `ProtectHome=yes`、`ProtectSystem=strict`、`NoNewPrivileges=yes`、
  `RestrictAddressFamilies=AF_UNIX`。
- `ReadOnlyPaths` 覆盖 `/usr/lib` 和 `/usr/local/lib` 的模块目录。
- 模块包对 worker 只读；模块不能直接读写用户 home，只能走文件 API。
- 安装到 root：`tools/module_install_helper.py` 以 pkexec 重新校验签名描述符
  和整棵树，再原子复制到 root 模块目录；普通用户缓存只作为 staging。
  `moduleRoot()` 检测到 home 路径会回落到系统目录，避免 ProtectHome 下静默
  加载失败。

### 2.5 旧模块硬拒绝

- `ModuleManager::verifyManifest()` 要求 v2 字段；旧模块在信任/加载前失败。
- worker 内嵌 manifest 的 API version 与宿主不一致也拒绝。

## 3. 验证

本机 x86_64 + Xvfb/llvmpipe，**没有 Pi/ESP32 实机验证**。

```bash
cd bundle/orpi-terminal-20261031/pi-terminal
source pi_terminal/scripts/env.sh
ninja -C /tmp/pt-build-qt653
ctest --test-dir /tmp/pt-build-qt653 --output-on-failure -j4
```

最近一次全量结果：**70/70 通过**。

关键回归：

- `net_policy_contract`：v1 迁移、v2 拒绝 hosts/未知 app/非法 module id、
  modules 往返。
- `network_policy_controller`：管理员 PIN、root 策略 modules 保存。
- `network_policy_qml_page`：真实策略页 QML、内置 app 开关、第三方模块开关、
  moduleDraft 保存。
- `module_network_broker_contract`：公网限制、非 HTTP 拒绝、NAM 拒绝、
  QML 显式失败。
- `file_daemon_contract`：app 数据读写、家目录读、敏感路径拒绝、越界写拒绝、
  用户选择目录/单文件、签名能力、伪造签名拒绝、过期与跨会话恢复。
- `module_install_helper_contract`：签名包复制、root 模块树、篡改拒绝。
- 本机 systemd user 会话额外实测：临时 `orange-pi-file-test.service` 启动
  daemon 成功，socket 为 `srwx------`，停止后清理。
- `worker_ipc_contract`、`module_page_engine_isolation`、`startup_splash_lifecycle`：
  IPC、模块页独立引擎、启动/二级页生命周期。
- `module_devkit_sync_check`：SDK 头与 canonical 源同步。

## 4. 未完成 / 上线阻塞项

按严重程度排序：

1. **Pi/ESP32 实机验证跳过**
   - 按用户要求不在本轮做 Pi 硬件验证；x86_64 + Xvfb 结果不代表 Pi。
   - 本机 systemd user daemon 已实测 active/socket；Pi 的 systemd、
     触摸文件选择器、BLE/Wi-Fi 仍待现场验收。
2. **root 模块安装 helper 的 pkexec 路径未在无密码环境实测**
   - helper 的签名校验/复制/篡改拒绝已用 `--allow-user-root` 测试；
     pkexec 需要现场管理员输入密码，本会话无 root 密码，无法替用户完成
     安装到 `/usr/lib/orange-pi-terminal/modules`。
   - 生产部署仍需预创建 root 目录并安装 helper/polkit 配置。
3. **C 模块独立异步请求**
   - C 网络/文件回调在模块数据/动作回调内可靠；模块自建线程/定时器发起请求
     需要后续异步读循环。
4. **安装期权限确认 UI**
   - 信任弹窗只披露请求，实际授权在管理员 PIN 保护的联网页完成；
     没有安装完成后的专门网络/文件权限确认页。
5. **跨会话写授权的安全取舍**
   - 默认 24 小时，持久化在用户 QSettings；同一 UID 的进程仍可改它。
     这是同 UID 威胁模型下的已知边界，不是 root 级强制。
   - 语音声库/Flite 只在仓库与测试环境验证，未做 Pi 实时播放回归。

## 5. 文档索引

- `docs/networking.md`：网络边界、代理、模块 API、root 策略。
- `docs/devdocs/22-module-platform-api-2026-11-01.md`：模块 API v2。
- `docs/devdocs/23-file-api-2026-11-01.md`：文件 daemon/API、敏感路径、
  写 token 与限制。
- `docs/native-runtime-modules.md`：模块安装根目录、worker 沙箱、Qt 运行库。
- `docs/pi-ui-regression.md`：字体、`ReadOnlyTextView`、右侧滑入页生命周期。
- `docs/voice-tts.md`：声库与 TTS。
- `docs/project-code-map.md`：源文件地图（如过期，运行
  `python3 tools/generate_project_code_map.py` 重新生成）。

## 6. 打包说明

完整交付包会把以下内容放在同一个 zip：

- `orpi-terminal-20261031/pi-terminal/`：完整源码、`docs/`、声库
  `pi_terminal/assets/voices/`（9 套，约 158 MB）、TTS 资源、模块开发包、
  测试与 `.git` 历史。
- `orpi-terminal-20261031/esp-firmware/`：ESP32 模块开发包与 smart-planter
  固件源码。
- `handover/`：工作区根目录的研读笔记、时间功能交接、PR 记录、截图等。
- `PACKAGE-README.md` 与 `MANIFEST.sha256`。

未包含：`build/`、`build-pi/`、`node_modules/`、`.tmp/`、`.venv/`、`pristine/`
以及与本项目无关的天气实验副本。
