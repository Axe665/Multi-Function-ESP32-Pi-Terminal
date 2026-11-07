# 2026-10-30 → 10-31 轮：网络门控、临时用户、登录页改版

> 本轮跨度长，从"天气缓存"一路做到"临时用户整批隔离"。本文按主题归档，
> 每个主题都写清「做了什么 / 怎么验证 / 没验证什么」。

## 0. 一句话

四条网络栈统一走本地代理 + 内核兜底；临时用户从零实现（无 PIN 进入、独立目录、退出即删）；
登录页做了确认键与左右分栏；并修掉一个潜伏很久的双 SQLite 符号冲突。

## 1. 天气与网络门控

- `WeatherEngine` 增加 cache TTL（6 小时）、`fetchedAt`、`{key}` 占位、`NetworkGate` 前置判断。
- `NetworkGate` 从"死的开关"改成真的：7 个 Purpose、默认**放行**、`permits()` 无副作用、
  `allow()` 写 reason 并 emit。持久化到 `net/*`。
- 设置页新增「联网权限」分区：总开关 + 六个子开关 + 三态状态行。

## 2. 出站代理（`network_proxy`）

四条网络栈（Qt Network / QML XHR / Chromium / GStreamer）没有共同出口，
唯一共同语言是 HTTP CONNECT 代理。

- 每个通道一个端口：browser=34001 music=34002 tv=34003 qml=34004。
- 策略文件 JSON，`QFileSystemWatcher` 热重载；缺文件/缺键一律 fail-closed。
- Chromium 走 `--proxy-server` + `--disable-quic`（QUIC 是 UDP，绕过 HTTP 代理）。
- 主进程启动时先探测 34001：已有代理就复用，不重复拉起。

## 3. 系统级兜底（nftables）

按 **cgroup** 匹配而不是 UID（主程序与用户自己的浏览器/ssh 同 UID，按 UID 会全断）：

```
放行 127.0.0.0/8 与 ::1（本地代理、systemd-resolved）
放行 192.168/16、10/8、172.16/12、169.254/16、fe80::/10、fc00::/7（模块链路）
其余 TCP 回 RST，其他协议 reject
```

**踩过的坑**：第一版只写了 `ip daddr`（IPv4），验证时 `curl` 直接走 IPv6 绕过去了。
现已 v4/v6 双覆盖，并改成白名单式。

## 4. 桥板 `bridge_id` 持久化

固件首次生成 `bridge_id` 时**没有写回 NVS**，每次上电换一个；Pi 侧也只校验格式不校验归属。

- 固件：首次生成即 `nvs_set_str` + commit（写失败只告警，不阻断启动）。
- Pi 侧：`PbrControl::bridgeIdMatches()`，握手时从 TrustStore 候选记下 bridge_id，
  逐事件比对；不一致丢弃并记日志，不回错误帧（避免给攻击者 oracle）。

**升级影响**：已配对设备若记录与实际值不同，升级后事件会被全部拒绝。
恢复路径与"升级前先 `pbr_info` 核对"写进 `docs/pbr-secure-v1/BRIDGE-ID.md`。

## 5. 临时用户（本轮最大一块）

此前只有文档里一句「设计见交接文档 §7」——而那个 §7 **从未存在**。
本次从零实现并补了 `13-guest-session-2026-10-31.md`。

| 项 | 决定 |
| :--- | :--- |
| 数据 | 每次会话独立目录，退出即删 |
| 加密 | SQLCipher + 随机内存密钥（访客没有 PIN） |
| 权限 | 日常应用可用；禁设置、用户与权限、连接管理、配对 |
| 进入 | 登录页左下角「访客登录」，无 PIN |
| 退出 | 顶栏登出图标（访客=结束会话并删数据） |
| 锁屏 | 固定 5 分钟，且访客改不动 |
| 浏览器 | WebEngine 存储/缓存/下载切到会话临时目录，退出整棵删 |

**踩过的坑**：`syncCards()` 只在启动时构建一次卡片表，访客登录后仍是登出状态那份，
权限过滤等于没做。挂到 `SessionManager::changed` 才生效。

**另一个**：`recentApps` 是内存 ListModel、跨会话存活，访客打开过什么会留给下一个人。
现在登出即清。

## 6. 登录页

- PIN 输满 6 位后**不再自动提交**，需点确认键（KDF 很贵，手滑输错不该白等一次）。
- 密码框显示 `●●●●●●`，右侧 × 清空，确认键在键盘 0 左侧（对号）。
- 左右分栏：左身份（头像+用户名）、右整套密码面板。
- 顶栏统一登出图标（`logout` + 红色），编辑=`build`（扳手），恢复默认=`refresh`（转圈箭头）。
- 手绘了 `build/home/logout` 三个 Material Symbols 图标。

## 7. 两个反复踩的坑（值得记住）

### 7.1 双份 SQLite 符号冲突

`libterminal_system.so` 静态链接了 Viper 的 `libviper-sqlite3.a`，把完整 `sqlite3_*`
以强符号导出；主程序又链接 `libsqlcipher.so`。两个强符号进同一动态符号表，
动态链接器只绑一个：`sqlite3_open` 走 A 副本、`sqlcipher_activate` 走 B 副本，
两套全局状态互不知晓 → `sqlite3_initialize` 自锁，登录后窗口无响应。

修法：`target_link_options(terminal_system PRIVATE "LINKER:--exclude-libs,libviper-sqlite3.a")`。

**这个 bug 骗了我很久**：Xvfb 下正常、真实桌面必卡，一度被归因成"同步 vs 异步"。

### 7.2 Qt Quick 的 z 不是父容器作用域

登录页的关机/更多按钮连续四轮"看不见"。试过 z、filled、覆写 background、自绘、写死颜色，
全无效。最后用一个**纯红方块量像素**定位：

```
红方块 R 通道 = 12.8（几乎全黑）
z 提到 25000 → 仍然 12.8
```

根因：`Overlay` 整层压在 `ApplicationWindow.contentItem` **之上**，放在 Main.qml 里的
元素 z 调到多少都在 Overlay 下面。搬进 `SessionGate.qml`（本身在 Overlay 里）立刻见效。

**教训**：一次正确的诊断（纯色方块 + 量像素）抵得上十次"改一版看一眼"。

同类问题：`Popup` 渲染在窗口 overlay 上，z **不跟随父元素**，必须单独设
（`z: 40000` 才压得住 SessionGate 的 20000）。

## 8. KDF 子进程（已实现，未接线）

目标：Pi 上登录 ≤1 秒，且迭代数保持 600k 不动。

- `terminal_kdf_worker`：常驻子进程，行协议，只做 PBKDF2。
  输出与 Python `hashlib.pbkdf2_hmac` 逐字节一致。
- `KdfClient`：异步客户端，15s 超时，崩溃/超时一律回调失败。
- `AuthService::beginVerify/finishVerify`：把 `verifyPin` 拆两段，为外部 KDF 让路。

**未接线原因**：收到 KEK 后主线程打开 SQLCipher 库会自锁（三次实测，含 singleShot 与直接调用）。
在把 `openDatabase` 也移出主线程之前，UI 仍走同步 login，worker 不启动。

## 9. 验证状态

| 项 | 状态 |
| :--- | :--- |
| 全量测试 | 52 项 51 通过（唯一失败是环境 WebGL 的 `signed_session_integration`） |
| 访客进入/权限/退出即删 | ✅ 主机实测（Xvfb + 真实二进制） |
| 浏览器存储隔离 | ✅ 实测（guest-web 目录创建与删除） |
| 最近使用清理 | ✅ 实测 |
| 登录页按钮/弹窗 | ✅ 实测（截图） |
| 天气/代理/网络门控 | ✅ 单测 + 主机实测 |
| **Pi 实机** | ❌ 从 10-30 19:44 起 `192.168.77.1` 不可达（ping 无响应、ssh 被关闭） |
| **aarch64 构建** | ❌ 交叉工具链原先放在 `/tmp/xc/`，被系统清理；需迁到持久位置重建 |
| 桥板固件真机 | ❌ 无板子，只做 `idf.py build` 编译验证 |

## 10. 已知未完成

1. **密码页左右分栏偏左**：内容中心约 426，页面中心 512。两个 `ColumnLayout` 的
   `preferredWidth` 没真正约束住。
2. **KDF 子进程接线**：需把 `openDatabase` 一并移出主线程（完整 DB 进程）。
3. **aarch64 工具链重建**：`/tmp` 不是放工具链的地方。
4. **Pi 部署验证**：等设备恢复。

## 11. 成品与构建

`package-build.sh` 每轮收尾打一份可分发的本机成品：

```
~/orpi-builds/<时间戳>-<短 commit>/
├── orange_pi_terminal
├── network_proxy
├── terminal_kdf_worker
├── lib/orange-pi-terminal/*.so    ← 必须在这一层，对齐 RUNPATH $ORIGIN
├── qml/
└── BUILD.txt
```

`--pi` 可打 aarch64 包，但工具链缺失时会明确跳过，不产半成品。
