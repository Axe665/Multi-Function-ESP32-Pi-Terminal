# Phase 1：内置应用联网权限改为默认拒绝 + 管理员 root 策略

> 这是“业务面/数据面强加密 + 严格控制联网”三阶段中的 Phase 1。
> Phase 2（模块信任/mTLS/包 HTTPS）与 Phase 3（BLE AEAD）尚未开始；
> 本文只记录已经落地的内置应用权限，不得据此宣称模块链路已强加密。

## 1. 已定语义

- 六个应用：`browser`、`tv`、`weather`、`time`、`music`、`updates`。
- 默认全部拒绝；策略文件缺失/损坏也全部拒绝。旧 QSettings `net/*` 不继承。
- 管理员在“设置 → 联网权限 → 管理各功能联网”中编辑草稿；保存前必须重验
  当前管理员 PIN，沿用登录的 1 次/秒与 5 次锁定计数。
- v2 只有应用级开关，不再维护域名 allowlist；应用开启后只允许公网目的地，
  本机/私网/链路本地/组播一律拒绝。音乐本机 Node 是唯一例外
  （`127.0.0.1:3000`，只对 `music` 通道、明文）。
- 访客/普通用户只读：入口与总闸对非管理员禁用；后端保存还会再次校验管理员身份。

## 2. 策略文件

生产路径 `/etc/orange-pi-terminal/network-policy.json`，root:root 0644：

```json
{
  "schema": "orpi-net-policy-v2",
  "version": 2,
  "apps": {
    "browser": {"enabled": false},
    "tv": {"enabled": false},
    "weather": {"enabled": true},
    "time": {"enabled": false},
    "music": {"enabled": false},
    "updates": {"enabled": false}
  }
}
```

权限选择 0644 而不是 0600：文件不是秘密，完整性靠 root 所有权；主程序是普通
用户，必须能读。写入只能经 root helper，普通用户改不了。

## 3. 执行链

```
QML 策略页
  → NetworkPolicyController::save(apps, pin)
  → SessionManager::verifyAdminPinForPolicy(pin)     // 1/s + 5 次锁定
  → QProcess: pkexec <安装前缀>/libexec/orange-pi-terminal/net-policy-helper
  → helper: NetworkPolicy::parse() → QSaveFile 原子写
  → controller.refresh() → NetworkGate 六开关
  → TerminalApplication::writeNetPolicy() → /run/orpi-net-proxy/policy.json
  → ProxyServer 热载：channel enabled + 公网目的地检查
```

代理是第二道：即使应用层忘了查 `NetworkGate`，代理仍会按通道/host 拒绝。
`updates` 通道 34006 已预留；当前没有更新器，开启也必须配置 host。

### 3.1 代理策略 version 3

```json
{"version":4,
 "channels":{
   "browser":{"enabled":false},
   "music":{"enabled":true},
   "qml":{"enabled":true},
   "timesync":{"enabled":false},
   "updates":{"enabled":false},
   "tv":{"enabled":false}
 }}
```

- 每个通道只有 `enabled`；缺键/格式错误一律禁用；不做 host fallback。
- 代理对目标做公网地址检查；`music` 的 `127.0.0.1:3000` 是唯一本地例外。

## 4. 文件与测试

| 文件 | 作用 |
| :--- | :--- |
| `src/net/NetworkPolicy.{h,cpp}` | schema、默认值、host 语法/匹配、预置清单 |
| `src/net/NetworkPolicyController.{h,cpp}` | QML 读取/保存、管理员重验、gate 更新 |
| `src/net/net_policy_helper.cpp` | root 写入器；只接受 stdin，测试允许 `--policy` |
| `src/net/NetPolicy.{h,cpp}` | 运行期 proxy 策略（version 4，仅 enabled） |
| `src/net/ProxyServer.{h,cpp}` | 通道 + 公网目的地执行 |
| `src/security/AuthService.*` | `verifyAdminReauth`（带限速/锁定） |
| `src/security/SessionManager.*` | `verifyAdminPinForPolicy` |
| `qml/NetworkPermissionsPage.qml` | 管理员草稿、域名编辑、PIN 保存 |
| `qml/NetworkPermissions.qml` | 管理员入口、总闸、只读提示 |
| `qml/Main.qml` | 浏览器 HTTP 确认/横幅 |
| `qml/TvPlayer.qml` | HTTP 源不安全标记 |
| `packaging/com.orangepi.terminal.network-policy.policy.in` | Polkit action 模板（CMake 生成实际 exec.path） |

测试：

- `net_policy_contract`：默认拒绝、六通道、host 匹配、非法策略。
- `net_policy_helper_contract`：helper 的合法/非法输入与写入。
- `network_policy_controller`：缺文件拒绝、错误 PIN 不写盘、正确 PIN 落盘并更新 gate。
- `network_policy_qml_page`：真实 QML 页面加载、Repeater/开关、草稿切换。
- `test_runner_discovery`：开发者 Test mode 的 ctest 发现契约，断言 Phase 1
  新增测试出现并归入 Network 组。
- `network_master_switch`：门控默认拒绝语义。
- `proxy_egress_contract`：本机/私网拒绝、本机 Node 例外、原有 origin-form/403/502。
- `time_sync_client_contract`、`music_native_api_requests`、`weather_tools` 门控回归。

这些 ctest 名称会由开发者选项的 Test mode 自动发现；`TestRunner::classify()`
已把 `net_policy_*` / `network_policy_*` 归到 **Network** 组。

### 4.1 本轮清理的失效测试

- 删除 `tests/session_test.cpp`：它从未注册进 ctest，只被旧的 GUI 集成脚本调用；
  依赖 BLE/hotspot 假模块，当前环境 60s 超时。会话/锁屏语义已由
  `session_gate_test`、`security_lock_and_recovery`、`module_worker_async` 等覆盖。
- 删除 `tools/mock_pogo_control/`：PBR 命令 AEAD/严格事件后，它仍发旧明文帧；
  没有任何测试或产品路径引用，保留只会误导。
- `tests/run_integration.py` 删除 `MockBridge` GUI 分支和旧 session 调用；测试
  改为只验证签名包、缓存复用、篡改拒绝，并重命名为 `signed_package_integration`。
  该测试现在通过（2s），不再是环境失败。
- 保留 `tools/mock_bridge.py` / `mock_bridge_multi.py` 作为**手工演示工具**并在
  18 号文档标注：严格 PBR 后不能用于安全联调，不能当成测试通过证据。

全量 ctest 见 §6。

## 5. 未验证/边界

- 示例命令里的 `/usr/libexec` 是 **/usr 前缀**；CMake 会按
  `CMAKE_INSTALL_FULL_LIBEXECDIR` 生成 helper 路径和 Polkit `exec.path`，
  默认 `/usr/local` 前缀安装时两者会一起变成 `/usr/local/...`。
- **Polkit/pkexec 没有 root 安装验证**：本机无 root 密码，只验证了 helper 的
  `--policy` 临时路径、策略解析/属性页和调用路径。正式机需要安装
  `.policy` 与 helper，并确认 `pkexec` 对管理员用户可用。
- `.policy` 文件已提供，但应用当前用通用 `pkexec` 调用；如果发行版要求
  自定义 action 的授权语义，需要在打包时把 `org.freedesktop.policykit.exec`
  或 D-Bus 服务接上，不能只装 XML 就假设生效。
- 浏览器页面内 HTTP 跳转用常驻横幅，不是每次弹模态框；地址栏/历史导航有模态确认。
  这是为不阻断页面内导航做的取舍。
- 电视只加标记，不改源；现有 68/74 个 HTTP 源仍可用。
- `updates` 通道是预留；没有更新器。
- 音乐 CDN 预置只覆盖 `music.163.com` / `*.music.126.net`；未知 CDN 必须管理员添加，
  否则播放失败关闭。
- 普通用户/访客的后端保存拒绝已做；但如果同 UID 恶意进程直接调用 helper，
  仍受 Polkit/文件权限约束，不在应用层可防范围。
- **模块 BLE/LAN/包仍未强加密**；Phase 2/3 未做，旧模块硬拒绝也尚未实现。

## 6. 验收

本机全量 ctest：67 项，67 通过，0 失败；`ui_responsive_touch` 与
`ui_highdpi_touch` 各 61 个布局用例、0 错误。新增 4 项全部通过；
原 `signed_session_integration` 改为 `signed_package_integration` 后已通过；
`arkpets_sprite_packing` 在切换到系统 Python 3.12 后也通过。

### 6.2 环境修复

完整依赖与版本清单见 [构建与测试环境清单](20-build-test-environment.md)。
后续构建统一使用作者 Qt SDK 6.5.3。用该 SDK 重新配置/编译/跑全量 ctest：
**67 项，67 通过，0 失败**，`ui_responsive_touch` / `ui_highdpi_touch`
均为 0 错误。Qt 6.5.3 不再触发 Qt 6.4 的 `QQuickLayout` 崩溃；在字体下限、
临时管理员夹具之后，又修复了隐藏页/弹窗的延迟构建、`activeBrowser` 当前标签
映射和 WebEngine 触摸夹具，UI 审计错误从 281 降到 0。

- 安装 `vlc-plugin-base`：VLC 之前只有 `libvlc` 没有 codec/access 插件，
  3 个 `media_vlc_*` 都卡在 `decodedFrames()==0`；安装后全部通过。
- `shared_runtime_install` 的 `ldd` 环境加入本地解包的 SQLCipher 目录；
  安装树的 `libsqlcipher.so.1` 不再 `not found`。
- `TerminalRuntime` 的 `--window-size` 改为下一轮事件循环执行 resize：
  Qt 6.4.2 在窗口首次 polish 期间直接 resize 会进入无效的
  `QQuickLayout::effectiveSizePolicy_helper`；延迟后 1024x600 启动稳定。
- `StatusDock.qml` 的任务区从嵌套 `RowLayout` 改为普通 `Row`：这是 Qt 6.4
  在 1024 宽度下启动崩溃的实际触发点，修复后 Pi 原生 1024x600 可启动。
- `UserSecurityPage.qml` 补回 `SecurityStatusSection`：页面此前只保留
  属性/刷新函数却没有渲染，`pairing_ui_page` 找不到刷新按钮；补回后通过。
- `auditPage()` 显式调用 `finishTransition()`：`zoomAnimation.complete()` 不保证
  触发 `onFinished`，否则会留下 `section!=0` 的隐藏 appShell。

剩余 2 个 UI 测试仍失败：Qt 6.4.2 + Xvfb 下，`--ui-audit` 的多尺寸 resize
在后续页面切换后仍会触发 `QQuickLayout` 崩溃；同样的 1024x600/1024x768
以 `--window-size` 启动是稳定的。该问题是 Qt/审计环境的布局崩溃，不是
Phase 1 功能回归；没有删除这两个测试来“变绿”。

### 6.1 root 实测（2026-11-01）

- 以 root 安装 helper 到 `/usr/local/libexec/orange-pi-terminal/net-policy-helper`，
  Polkit action 到 `/usr/local/share/polkit-1/actions` 和 `/usr/share/polkit-1/actions`；
  `pkaction --action-id com.orangepi.terminal.network-policy --verbose` 能读出描述/默认值。
- 以 root 用真实 stdin 跑 helper：合法策略写入 `/etc/orange-pi-terminal/network-policy.json`，
  权限 `root:root 0644`；带 `https://evil` 的非法策略返回 2，文件保持原内容。
- 测试后策略已恢复为**全部拒绝**。
- `pkexec` 的交互认证仍无法在无 Polkit agent 的当前会话自动化；应用控制器
  通过测试用的 `ORANGE_PI_NET_POLICY_HELPER` 直连路径验证了保存/重载/gate 更新。
  正式机仍需用真实管理员会话点一次保存确认。
