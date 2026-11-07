# 联网权限（默认拒绝 + 管理员 root 策略）

> 实现：`pi_terminal/src/core/NetworkGate.{h,cpp}`（独立库 `terminal_gate`）、
> `pi_terminal/src/net/NetPolicy.cpp`（策略 JSON 的唯一构造点）、
> `pi_terminal/src/net/NetChannels.h`（端口/通道名单一来源）、
> `pi_terminal/src/ui/TimeSyncClient.{h,cpp}`（校时 C++ 传输层）、
> `pi_terminal/src/net/NetworkPolicy.{h,cpp}`（root 策略模型）、
> `pi_terminal/src/net/NetworkPolicyController.{h,cpp}`（QML 读取/保存）。
> 持久化：**root:root 0644** 的 `/etc/orange-pi-terminal/network-policy.json`，
> 由 Polkit/pkexec 调 `net-policy-helper` 写入；QSettings `net/*` 不再生效。

## 为什么单独成一个库

`NetworkGate` 原本在 `terminal_core` 里，但真正要用它的调用方分布在
`terminal_music`（音乐）、`terminal_ui`、`terminal_system`（浏览器）里，
而这些库**不链** `terminal_core`（反向链接会成环）。

所以把它抽成只依赖 `Qt6::Core` 的静态库 `terminal_gate`；实际消费者是 `terminal_core`、
`terminal_music`、`terminal_system`（`terminal_ui` 不直接链），
且 `terminal_gate` 自己不碰 QSettings —— 持久化放在 app 层，单元测试构造出来的
gate 不会读写真实配置。

## 语义

| 项 | 行为 |
| :--- | :--- |
| 总开关 | 运行期紧急总闸，默认开；它不授予任何应用权限 |
| 六个应用开关 | 浏览器 / 网络电视 / 天气 / 网络校时 / 音乐 / 更新下载；**默认全部拒绝** |
| 应用授权 | 只有管理员能改；保存前重验管理员 PIN（1 次/秒、5 次锁定） |
| 目的地边界 | 应用开关打开后只允许公网；本机/私网/链路本地/组播一律拒绝 |
| 本地 Node 例外 | 只有 `music` 通道允许 `http://127.0.0.1:3000` |
| 总开关关闭 | 所有功能一律拒绝；**应用开关状态保留**，重新打开总开关即原样恢复 |
| 判定入口 | 调用方在发请求前问 `allow(purpose)`；代理再按通道 + 公网目的地执行第二道 |
| 在途请求 | 阻止新建；持续连接（在线播放/流）立即停；一次性请求允许跑完 |
| 本地功能 | 不受影响：本地音乐、本地视频、文件、模块的 BLE/LAN 链路都不经此门 |

`allow()` 的字符串入口支持带后缀的老写法（如 `music.api`），按前缀映射到对应功能；
未知用途按 `Other` 处理——总开关开着就放行，不会被误拦。

## 持久化与首次启动

| 文件 | 内容 |
| :--- | :--- |
| `/etc/orange-pi-terminal/network-policy.json` | `orpi-net-policy-v2`：六个应用 `enabled`，无 hosts |
| `/run/orpi-net-proxy/policy.json` | 宿主按当前 gate 生成的运行期代理策略（version 4） |

- 策略文件缺失/损坏 = **默认拒绝**，不会从旧 QSettings 继承；升级后管理员要重新授权。
- 策略是 root:root 0644：完整性由 root 保证，应用只需读；普通用户/访客不能写。
- 保存链路：QML → `NetworkPolicyController::save()` → 管理员 PIN → `pkexec`
  → `net-policy-helper`（校验 v2 schema）→ 原子写 → 重新加载 → 更新 gate/代理。
- v1 策略可读：启用状态保留，旧 `hosts` 字段丢弃；新写入一律 v2。
- 旧六个 QSettings 键只作为升级前的历史数据，不再参与判定。

## 各功能的接入点

| 功能 | 判定位置 | 关闭后的表现 |
| :--- | :--- | :--- |
| 天气 | `WeatherEngine.qml` 的 `refresh()` / `probe()` / `search()` | 不发请求；保留缓存并显示「联网已关闭」 |
| 校时 | `TimeSync.qml` 的 `doSync()` + `TimeSyncClient::fetch()` | C++ 传输层先查 `allow("timesync")`；不发请求；手动校时说明原因，自动校时只更新状态行 |
| 音乐 | `MusicService::request()` 与整曲缓存下载 | 不拉起本机 Node、不发请求，回调「联网已关闭」 |
| 浏览器 | Viper 的 `RequestInterceptor::interceptRequest()` 开头 | **所有**请求就地取消（含主文档），页面显示 `ERR_BLOCKED_BY_CLIENT` + 页内横幅 |
| 网络电视 | `tv` 代理通道（`GstVideoItem` 的 `souphttpsrc proxy=`） | CONNECT/请求被拒 → 拉流失败；没有应用层 `allow(Tv)` 调用，页内无专门提示 |
| 更新下载 | 预留 `updates` 34006 通道；当前没有更新器 | 一律拒绝；未来实现必须走代理 |

## 出站代理（C/S）

前面那些判定都在**应用层**——新代码忘了调用 `allow()` 就绕过去了。为了让"不能联网"有真正的
边界，另起一个本地出站代理进程，五条网络栈按通道接进来。

```
音乐 NAM ─────┐
QML XHR(天气) ─┼─→ HTTP 代理 127.0.0.1:3400{1..5} ─→ 外网
校时 C++ QNAM ─┤        （代理按"哪个端口收到连接"判通道）
WebEngine ────┤
GStreamer ────┘
```

| 通道 | 端口 | 接法 |
| :--- | ---: | :--- |
| `browser` | 34001 | Chromium 参数 `--proxy-server=http://127.0.0.1:34001`（`QQuickWebEngineProfile` 没有 proxy API，只能在 `main.cpp` 里启动前设）+ `--disable-quic` |
| `music` | 34002 | `MusicService::setNetworkProxy()`，宿主注入 |
| `tv` | 34003 | `souphttpsrc` 的 `proxy=` 属性 |
| `qml` | 34004 | `QQmlEngine::setNetworkAccessManagerFactory()` 提供的 NAM 默认带代理；**只跟 Weather 开关** |
| `timesync` | 34005 | `TimeSyncClient` 的独立 QNAM；只跟校时开关，关天气不再连坐校时 |
| `updates` | 34006 | 预留；当前没有更新器 |

**策略**由宿主写 JSON（生产 `/run/orpi-net-proxy/policy.json`，开发回退到
`$XDG_RUNTIME_DIR/orange-pi-net-policy.json`），代理由 `QFileSystemWatcher` 热载。
先写策略、再拉起代理，读不到文件时代理**全拒**（缺键也按拒——宁可拒绝，不因拼写错误
静默放行）。策略 `version` 为 4，`channels` 含
browser/music/tv/qml/timesync/updates 六项；每项只有
`{"enabled":true}`，没有域名 allowlist。代理对每个目标做公网地址校验。

**协议**是标准 HTTP 代理：CONNECT 隧道 + 明文 HTTP 的 absolute-URI 请求，不做 MITM。
非 CONNECT 请求会改写成 **origin-form**（只留 path+query），并清掉
`Proxy-Connection`、`Proxy-Authorization`、`Connection` 提名的头、
`TE/Trailer/Upgrade/Keep-Alive`，保留 Host 与 body。状态码：

| 状态 | 含义 |
| ---: | --- |
| 400 | 请求行/绝对 URI/头非法，或对非 CONNECT 用了 https |
| 403 | 通道被策略关闭，或目标不是公网地址 |
| 502 | 上游不可达或握手超时 |

客户端能看到“被策略拒”与“网络坏了”的差别：

- Qt Network → `ContentAccessDenied`
- WebEngine → `ERR_TUNNEL_CONNECTION_FAILED`
- GStreamer → 连接失败

**故障**：主程序看护代理进程，退避重启（最多 5 次）；期间六条栈都指向没人监听的端口
= 全部失败，不会偷偷直连（fail-closed）。

**运行期回写**：`NetworkGate::settingChanged → writeNetPolicy()` 在
`startNetworkProxy()` 之前连接。这样即使探测到 systemd 代理已存在、函数提前返回，
之后改开关仍会重写策略文件（旧实现把连接放在探测之后，生产形态下策略会冻结在启动瞬间）。

**公网边界**：应用开关打开后，代理仍拒绝回环、RFC1918 私网、链路本地、唯一本地、
组播、广播与保留地址；域名先解析并检查全部地址。唯一例外是 `music` 的
`http://127.0.0.1:3000`。浏览器/电视启用后也只做公网 HTTP(S)。

**可观测**：`net-proxy: allow #N channel=... target=host:port` 与
`net-proxy: deny #N channel=... why=... line=...`，各限流到 1/20 条。

### 第三方模块网络 API

- `AppNetworkBroker`：宿主进程内异步 HTTP(S) 请求，复用 `PublicNetwork` 公网判定；
  每 appId 独立 QNAM/cookie，16MiB 响应上限、30s、5 次安全重定向。
- `AppNetworkApi`：模块 QML 的 `appNetwork.request()` 显式入口；同时为模块页独立
  `QQmlEngine` 安装 NAM 工厂，XMLHttpRequest/网络 Image 也走同一权限判定。
- C 模块通过 `pi_host_services.network_request()` 使用同一 broker（worker IPC
  `appRequest`/`appResponse`，在模块数据/动作回调内同步返回）。
- 管理员在“设置 → 联网权限 → 第三方应用”按 manifest id 授权，和内置应用一起
  写入 root 策略的 `modules` 对象并需要管理员 PIN；运行期 `NetworkGate` 只保存
  实例判定，缺省拒绝。
- `file://`/`qrc:` 资源仍由 QML 直接加载；文件 API 见
  `docs/devdocs/23-file-api-2026-11-01.md`。

### 边界

- 只能看到 `CONNECT` 的 host:port，**看不到 URL 路径**（HTTPS 加密，不做 MITM）；
- 不防同一登录用户下的恶意进程（同 UID）——系统级 nftables（`packaging/net-egress.sh`）
  负责 cgroup 白名单；worker 另有 `PrivateNetwork=yes` 沙箱；
- 系统级规则落地前，代理本身是可以被绕过（直连）的，只是应用内没有这样的代码路径。

## 生产形态：代理作为 systemd 单元

`pi_terminal/packaging/orange-pi-net-proxy.service`（模板；CMake 装到
`share/orange-pi-terminal/systemd/`，需要管理员复制到 `/etc/systemd/system/` 并 enable）：

```ini
DynamicUser=yes                                    # 独立 UID
RuntimeDirectory=orpi-net-proxy
RuntimeDirectoryMode=0777                          # 宿主可写、代理可读
ExecStart=/usr/bin/network_proxy --policy /run/orpi-net-proxy/policy.json
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

**为什么策略放在 `/run/orpi-net-proxy/` 而不是 `$XDG_RUNTIME_DIR`**：后者是 0700，
独立 UID 的代理读不到。公共运行目录 + 0644 的文件是唯一不需要跨用户授权的做法。

**主进程不再自己拉代理**：启动时先探测 34001，已有代理解就跳过
（`net-proxy: already running on port 34001, not spawning another`）。
否则两者会在同一个 cgroup 里，系统级规则会把代理也拦掉。

**开发机验证的限制**：本机 `DynamicUser` 起不来——`ExecStart` 在 `$HOME` 下（0700，
临时 UID 进不去），且二进制链接的是 `$HOME` 里那套 Qt SDK，退到系统 Qt 6.4 就报
`version Qt_6.5 not found`。所以开发机用「独立 cgroup + 同 UID」的 transient unit
验证了链路（unit 在 `/system.slice/orpi-proxy-test.service`、app 探测复用、策略落到
`/run/orpi-net-proxy/policy.json`）；**独立 UID 这一段标 NOT TESTED**，生产镜像里
ExecStart 在系统前缀、链接目标机 Qt，不存在上述两个问题。

## 系统级兜底（nftables）

代理解决了"应用内没有直连路径"，但内核层面任何进程仍能自己开 socket。兜底规则把主进程的
出站限制成白名单：**只允许回环与局域网，其余全拒**。

**按 cgroup 匹配，不按 UID。** 主程序与用户自己的浏览器、终端、ssh 跑在同一个 UID 下，
按 UID 拦会把这些一起断掉。cgroup 只覆盖终端自己的进程树。

```
sudo pi_terminal/packaging/net-egress.sh install <cgroup 相对路径>
sudo pi_terminal/packaging/net-egress.sh status|remove
```

规则要点：

- 放行 `127.0.0.0/8` / `::1`：本地代理 34001-34005 与 systemd-resolved 的 stub 都在这；
- 放行 `192.168/16`、`10/8`、`172.16/12`、`169.254/16`、`fe80::/10`、`fc00::/7`：
  模块的 BLE/LAN 链路、USB 网卡、邻居发现；
- 其余 TCP 回 RST（界面立刻失败，不用等超时），其余协议直接 reject。

**代理必须跑在另一个 cgroup**：主进程只准连回环，而代理要出外网；两者同 cgroup 会被一起拦。
所以生产上代理是独立 systemd 单元，主进程启动时先探测端口——已有代理就不再自己拉一个
（`network_proxy: already running on port 34001, not spawning another`）。

### 验证（2026-10-30，PC）

在一个临时 scope 里加载规则后：

| 动作 | 结果 |
| :--- | :--- |
| `curl https://example.com`（IPv4） | `000`，被拒 |
| `curl -6 https://example.com`（IPv6） | `000`，被拒 |
| `curl -x http://127.0.0.1:34004 https://example.com` | `200` |

第一版规则只写了 `ip daddr`（IPv4），`curl` 直接走 IPv6 绕过去了——这正是"兜底必须覆盖
两种协议"的现场证明。规则现已同时覆盖 v4/v6，并改为白名单式（放行回环+局域网，其余 reject）。

### worker（模块）的现状

模块 worker 的默认拒绝**早就成立，而且比 nftables 更彻底**：
`orange-pi-worker@.service` 里有 `PrivateNetwork=yes` + `RestrictAddressFamilies=AF_UNIX`，
等于连 AF_INET socket 都不允许创建。

将来要按模块授权联网时，单元需要改成：
`PrivateNetwork=no` + `IPAddressDeny=any` + 按 manifest 授权注入 `IPAddressAllow=`，
并放开 `RestrictAddressFamilies` 到 `AF_UNIX AF_INET AF_INET6`。
这两项都是**按单元**的 systemd 属性，天然是"每个软件一个主体"，与将来"安装软件自定义权限"
是同一套机制。本轮不动它——没有需要联网的模块，提前放开只会扩大攻击面。

## 浏览器：逐请求拦截

浏览器是所有联网功能里唯一能"逐请求"拦的：Viper 的 profile 上挂了
`QWebEngineUrlRequestInterceptor`（adblock / DNT / 自定义 UA 都走它），而
`QWebEngineProfile` 只能挂一个 interceptor，Qt 又没有 getter 拿回已挂的那个，
所以只能改 vendored Viper —— 这是本仓库**唯一**一处 `third_party` 改动，共三处：

1. `RequestInterceptor.h` 加 `static void setNetworkBlocked(bool)`；
2. `.cpp` 里一个 `std::atomic_bool` + 在 `interceptRequest()` **最开头**判定
   （置位时 `info.block(true); return;`，全拦，含主文档）；
3. 限流日志 `network gate: blocked N request(s), latest <url>`，便于验收。

为什么用 atomic 而不是直接拿 `NetworkGate*`：interceptor 在 WebEngine 的 IO 线程
被调用，而 `NetworkGate` 是 QObject（`allow()` 还会 emit 信号）。宿主在主线程把
结论写进 atomic，IO 线程只读。

宿主侧 `ViperBrowserController::setNetworkGate()` 订阅 `NetworkGate::changed`，
用 **`permits()`** 而不是 `allow()` —— `allow()` 被拒时会 emit `changed`，
而这个槽就挂在 `changed` 上，会无限递归。`permits()` 是纯查询：不改 reason、不发信号。

**入口不拒绝**：点浏览器仍然能打开，只是所有请求被取消、页内显示横幅。
否则"请求被拦"这条路径根本走不到，用户只会看到"点了没反应"。

## 已知边界

- **网络电视只做通道级**：`tv` 通道关闭时 `souphttpsrc` 的 CONNECT/请求会失败，
  但 GStreamer 只能在拉流前判定，不能逐请求拦；页内也没有专门的“联网已关闭”提示。
- 开关只管**外网**。模块的 BLE/LAN、Pogo 串口不受影响（`NetworkGate` 注释第 1 条）。
- 三态（接口就绪 / 模块链路 / 互联网可达）互不推导，界面上分开显示。

### 开机加载与 cgroup 绑定（2026-11-07 修正）

`net-egress.sh` 只负责装规则，不会自己开机执行。仓库现附
`pi_terminal/packaging/orpi-egress.service`（`build_scripts/deploy_pi.sh` 会安装并 enable），
开机把脚本装到 `/usr/local/sbin/orpi-net-egress.sh` 后加载一次。

**绑 app.slice，不要绑具体 unit。** `nft` 的 `socket cgroupv2 ... "<path>"` 在加载时把
路径解析成 **cgroup 实例 ID**：`pi-module-terminal.service` 每次重启都会重建 cgroup，
旧规则绑在已消失的实例上，`nft list` 里路径会退化成数字，组内流量不再被拦——**静默失效**。
因此单元绑定 `user.slice/user-1000.slice/user@1000.service/app.slice`（level 4），
并在 `ExecStartPre` 里等该 slice 出现。

**代理 drop-in 不能写 `printf %s`。** `%s` 是 systemd specifier（用户 shell），
展开后策略文件会变成 9 字节的 `/bin/bash`，代理解析失败后 `allowed=[]`，六条通道全拒。
仓库的 `packaging/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf` 已改用
`printf "\42..."` 的八进制转义。
