# 模块平台 API：当前落地与剩余项

> 2026-11-01。内置应用保留内部实现；强制接入对象为第三方模块。
> 收尾状态、验证命令和上线阻塞项见
> [2026-11-01 收尾状态](24-final-status-2026-11-01.md)。

## 已确认边界

- 所有第三方模块必须声明 `platform_api` 与 `network_api`；文件能力用 `file_api` 声明。
- 所有模块必须返回 `PI_MODULE_API_VERSION = 2`；旧 manifest / 旧 ABI 直接拒绝。
- 联网默认拒绝，管理员按第三方应用授权；应用只能申请/查询，不能自行打开。
- 联网数据面只允许 HTTP(S) 公网；本机、私网、链路本地、组播一律拒绝。
- 文件 API：家目录只读但排除敏感目录；每包 `apps/<package-id>/` 可写；
  用户选择单个文件后才发会话级读写令牌；外置每用户 daemon，宿主中转。

## 已实现

### Root 策略 v2

- `/etc/orange-pi-terminal/network-policy.json` 只含六个内置应用的 `enabled`。
- v1 迁移保留启用状态并丢弃 hosts；v2 写入拒绝 `hosts` 字段。
- 运行期代理策略 v4 只含 `{enabled}`；代理做公网地址检查。

### 模块网络 broker（QML 部分）

- `src/net/PublicNetwork.{h,cpp}`：代理与模块 API 共用的公网判定。
- `src/core/AppNetworkBroker.{h,cpp}`：宿主进程异步 HTTP(S)，每 appId 独立 QNAM，
  16 MiB 响应上限、30 s、5 次安全重定向。
- `src/core/AppNetworkApi.{h,cpp}`：
  - 模块 QML 的 `appNetwork.request()` / `finished`；
  - 模块页独立引擎的 NAM 工厂，XHR / 网络 Image 也走权限与公网检查。
- `NetworkGate` 增加按模块实例的动态开关，默认拒绝；主开关关闭时全部拒绝。
- `ModulePageHost` 在加载页前绑定模块实例、安装 NAM 工厂、注入 `appNetwork`。
- C 模块的 `pi_host_services.network_request(context, json)` 已接到同一 broker：
  worker 发 `appRequest`，宿主在 worker 请求等待循环内同步完成 broker 请求并回
  `appResponse`；响应 JSON 生命周期到下一次调用。该路径只保证在模块数据/动作回调
  内可靠，独立的模块线程/定时器请求仍需后续异步读循环。
- `ModuleManager` 按 worker session（模块实例）注入 broker；`ConnectionManager`
  在宿主启动时把 `NetworkGate` 传给模块管理器。
- 文件 API 已接上：`pi_host_services.file_request` 与 QML `appFiles` 共用
  `FileApiBroker` → 每用户 `orange-pi-file-daemon`。详见
  [文件 API / 外置 daemon](23-file-api-2026-11-01.md)。

### 强制声明

- `ModuleManager::verifyManifest()` 要求 `platform_api=1`、合法 `network_api` 和 `file_api`；
  缺失/未知值直接拒绝。
- 宿主与 worker 都要求模块返回 API 版本 2；示例/测试模块已迁移。
- 旧模块在加载前被拒绝，不再走“缺声明也能运行”的兼容路径。

## 尚未完成

1. C 模块网络/文件回调只在数据/动作回调内可靠；模块自建线程/定时器请求
   需要后续异步读循环。
2. Pi/ESP32 实机验证按用户要求跳过；x86_64 的 systemd user daemon 已实测。
3. root 安装 helper 已实现并测试签名复制/篡改拒绝，但 pkexec 实际提权安装
   需要现场管理员密码，本会话无法替用户完成。
4. 安装期权限确认界面仍需细化；目前信任弹窗披露 `network.broker`/`files.home_read`，
   实际授权统一在管理员 PIN 保护的联网权限页完成。
5. 文件写授权默认 24 小时并持久化在用户 QSettings；同 UID 威胁模型下不是
   root 级强制策略。

第三方模块的联网/文件授权已进入 root 策略 `network-policy.json` 的 `modules` 对象，
和内置应用一起经管理员 PIN 保存；`NetworkGate` 只保存运行期实例判定。
模块安装使用 `module_install_helper.py`：用户缓存只做 staging，helper 重新验签
后复制到 root 模块目录；`moduleRoot()` 拒绝 home 路径。
