# 2026-10-31 快照后的修复轮：代理、校时、PBR、恢复码、SDK 闸门

> 本文记录 `c81ddd3f` 快照之后的三批修改。目标不是新增产品功能，而是修复
> 研读阶段确认的边界缺口，并把“代码事实 / 已验证 / 未验证”分开写清。
> 代码提交：`8483219`（代理/校时）、`a3dd948`（PBR/安全）、SDK/文档为第三批。

## 0. 一句话

代理补上了明文 HTTP 转发与运行期策略回写；校时从共享 QML 通道拆成独立 C++ QNAM；
PBR 命令改为双向 AEAD 并严格校验事件；锁屏/恢复码/保留期从“界面约定”变成服务端拒绝；
SDK 修了 BLE UUID 示例并加了同步闸门，但 LAN TLS/BLE 认证仍是公开 SDK 的已知缺口。

## 1. 出站代理与校时（批次 1）

### 1.1 行为

- `NetworkGate::settingChanged → writeNetPolicy()` 移到 `startNetworkProxy()` 之前。
  旧顺序在“探测到 systemd 代理已存在就 return”时不会建立连接，运行期改开关不重写策略。
- 非 CONNECT 请求改写为 **origin-form**：absolute-URI 只留 path+query；清掉
  `Proxy-Connection`、`Proxy-Authorization`、`Connection` 提名的头、
  `TE/Trailer/Upgrade/Keep-Alive`，保留 Host/Content-Length/Transfer-Encoding。
- 状态码拆成 400（坏请求）/ 403（策略关闭）/ 502（上游不可达或超时）。
- 响应先 `flush` + 优雅断开，再延迟 `close()`；直接 `abort` 会丢掉上游已经写回但
  还在客户端写缓冲里的 body。
- `NetChannels.h` + `NetPolicy.cpp` 成为端口/通道/策略 JSON 的单一来源；
  新增 `timesync` 34005，`qml` 34004 只代表天气及其它 QML XHR。
- `TimeSyncClient`（`terminal_system`）持有独立 QNAM，`fetch(url, id)` +
  `finished/failed`；C++ 侧检查 `allow("timesync")` 并管 8s 超时。
  `TimeSync.qml` 只替换传输层，URL 构造、两线路回退、解析、自动校时不变。

### 1.2 测试

- `proxy_egress_contract`（9 例）：music/tv/qml/timesync 四通道的 origin-form、
  Host、hop-by-hop 清理；403/400/502；CONNECT 隧道；真实 `network_proxy` 子进程冒烟。
- `net_policy_contract`（5 例）：策略 version 2、五通道、天气与校时互不连坐。
- `time_sync_client_contract`（7 例）：HTTP 状态/body、门控、超时、取消、非法 URL。
- `music_native_api_requests` 新增 “真实 MusicService → 代理 → fake Node” 链路。
- `time_tools_page` 39 例继续通过（QML 注入测试替身）。

## 2. PBR 与安全语义（批次 2）

### 2.1 PBR

- 握手后**全部** ControlCommand（含 `pbr_info`/诊断）用 `k_pi_to_bridge` 加密；
  握手三段仍明文；Pi→桥计数器从 1 递增；无明文回退。
- 计数器接近 `2^64` 时主动 `restartHandshake()`；重握手期间 `sendCommand()` 返回
  `SESSION_REHANDSHAKING`，不排队、不回退明文。
- `hello_resp.boot_id4` 与事件 `boot_id` 前 8 个 hex 必须逐字节相等。
- `EventTtl` 用 `QElapsedTimer`：offset 只从 `hello_ok.uptime_ms` 设一次；
  `age = sender − (local + offset)`，只接受 0..3000 ms；缺字段拒绝。
- 严格事件集：`attach/status/detach/rfid_card` 必须有 schema/boot_id/session_id/
  uptime_ms/ttl=3000；ACK 单独白名单；**删除 schema-less legacy 分支**。
- `revokeBridge` 找到指纹对应 bridge_id 后发 `bridgeRevoked`；宿主转给
  `PogoControlTransport::abortBridge()`，匹配当前已绑定身份才关闭并零化密钥，
  不回错误帧（避免给攻击者 oracle）。

### 2.2 锁屏、恢复码、保留期

- `SecurityService::requireUser/requireAdmin` 检查 `session_->locked()` 与
  `mustChangePin()`；数据 API 返回 `SESSION_LOCKED` / `SESSION_PIN_CHANGE_REQUIRED`，
  不关库。`ModuleDataApi::ready()` 同样失败关闭，并随锁屏状态发 `readyChanged`。
- 恢复码：`AuthService::verifyRecoveryCode` 自带 recovery 计数（5 次锁 60s，
  1 次/秒；不占 PIN 计数，PIN 锁定期间可用）；成功后清两套计数。
- `SessionManager::loginWithRecoveryCode` 建立会话并置 `mustChangePin`；
  数据 API 直到 `setRecoveryPin(newPin)` 成功才放行（无需旧 PIN，直接用会话内 dbKey）。
- 恢复码轮换两段式：`beginRecoveryRotation()` 只生成并展示；
  `commitRecoveryRotation()` 在用户点“我已保存”后才写盘；取消则旧码继续有效。
- 保留期：`UserDatabase::pruneHistory` 在**同一事务**里删
  `module_history/samples/readings/measurements/audit`；`applyRetention` 只在
  登录且未锁屏时跑，登录开库 + 每日定时各一次；0=永久，`module_kv` 不动。

### 2.3 测试

- `pbr_command_aead`（2 个用例，PTY）：真实 `PogoControlTransport` 写串口后，
  用 `k_pi_to_bridge` 解出 kind=2/dir=0、seq=1/2 的命令；未认证时拒绝发送。
- `pbr_replay_and_dedup` 增加 `evaluateWithOffset` 的 0/3000/±1ms 用例。
- `pibridge_protocol` 改为断言 schema-less attach 被拒。
- `security_lock_and_recovery`（1 个用例）：锁屏拒数据/模块写入、恢复码登录、
  强制改 PIN、撤销身份信号。
- `user_pin_session` 增加恢复码独立锁定与 `resetPinWithDbKey`。
- `sqlcipher_user_isolation` 的保留期用例扩展到样本/测量表。
- 全量 ctest：63 项，54 通过，9 项与基线相同的环境失败（见 §4）。

## 3. SDK（批次 3）

- 修 `config/product.ble.example.json` 与 `config/product.ble-hotspot-package.example.json`：
  write/notify UUID 改为 `…100002` / `…100003`，与 `module_data_ble_gatt.c` 和 Pi 测试一致。
- `tools/sync_module_devkit.py --check` 缺 `esp/` canonical source 时输出 **SKIP**
  而不是整闸红；仍校验 `pi_module_api.h`、`package_tool.py`、`mock_module.py` 三份副本。
  `--write` 已把主仓 mock 同步进 SDK，`SOURCE-MANIFEST` 收窄为当前存在的 3 个文件。
- 新增 ctest `module_devkit_sync_check`，漂移即失败。
- **明确边界**：公开 SDK 的 ESP 数据面仍是裸 TCP、BLE 无 HMAC；当前 Pi 的
  `HotspotLanTransport` 强制 TLS+指纹、`BleTransport` 强制挑战应答。用公开 SDK
  构建的固件目前无法建立 `session_ready`。LAN TLS/BLE 认证不在本轮实现范围内，
  需要与正式 `esp/S3_Pi_Module` 一起补。
- `mock_bridge.py` 仍只发旧式明文事件；严格事件 + 命令 AEAD 后它不能再用于
  PBR 联调，只能作为帧格式/串口冒烟。真正的 PBR 验证用 `pogo_control_test` 的 PTY
  用例或未来支持 AEAD 的 bridge mock。

## 4. 验证环境与未验证项

构建环境（本机 x86_64）：

- Qt 6.4.2、VLC 3.0.20、Node 24、Xvfb 可用；SQLCipher、mbedtls、OpenSSL 开发包
  用 `apt download` + `dpkg-deb -x` 解到 `/tmp/pt-deps`，通过
  `SQLCIPHER_ROOT` / `MBEDTLS_*` / `OPENSSL_*` 传入；GStreamer 头用仓库内
  `third_party/gst/amd64`。
- 全量 63 项 ctest：54 通过；9 项失败与改动前基线**完全相同**：
  `pairing_ui_page`、`arkpets_sprite_packing`、`shared_runtime_install`、
  `ui_responsive_touch`、`ui_highdpi_touch`、`signed_session_integration`、
  3 个 `media_vlc_*`。失败原因仍是环境（WebGL/音频设备/安装根），不是本轮引入。

未验证：

- **Pi 实机 / aarch64 交叉编译**：本轮没有设备，也没有重建交叉工具链；
- **ESP32 桥板/模块固件**：`esp/` 不在快照；命令 AEAD 需要 L 侧固件同步升级，
  否则旧板会在握手后收不到可解析的命令（这是有意的破坏性变更）；
- **真实 HLS/天气/音乐在线**：代理测试用本地 origin；真实 GStreamer/WebEngine
  与线上接口没有跑；
- **恢复码 UI 的实机点按**：QML 编译与 C++ 后端测试通过，但没有在真实触屏上
  走完“恢复码 → 改 PIN → 新码展示”的整条手势路径；
- **`SessionGate` 的新弹窗**没有专门的 QML 自动化用例；`login_qml_test` 只覆盖
  LoginPage 与 LockScreen。

## 5. 兼容性清单

| 变更 | 影响 | 处理 |
| :--- | :--- | :--- |
| Pi→桥命令 AEAD | 旧桥板固件不识别加密命令 | 升级 Pi 与桥板固件必须同批；回滚需同时回滚 |
| 删除 schema-less 事件 | 旧固件 attach/detach 被拒 | 同上；不再提供运行时 legacy fallback |
| 新增 34005 timesync | 旧 systemd 代理只有 4 通道，校时会失败 | 重启/升级 `network_proxy` 单元 |
| 策略 version 2 | 旧代理忽略新键即可（缺键 fail-closed） | 同批升级代理 |
| 恢复码登录 | 新增 `mustChangePin` 状态 | QML 登录页/弹窗已接入 |
| 保留期清 audit | 旧库首次登录会删过期审计 | 预期行为；0=永久可规避 |
