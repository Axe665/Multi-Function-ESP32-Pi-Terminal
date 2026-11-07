# 关于本机（设备信息 / build 日期 / 软件更新占位）

> 2026-10-31。设置页最后一行从「运行记录」换成「关于本机」入口，点开是右侧滑入的二级页。
> 本文记录范围、实现边界、**build 日期规则**与验证证据。

## 0. 一句话现状

设置 → 关于本机：本机名称可改（只写应用设置）、型号固定「模块化终端（第一代）」、处理器/内存/存储/内核全部运行时真实读取、
版本号是 `build YYYY-MM-DD`（每次构建由 CMake 重新生成），最底部「软件更新」只弹一个占位弹窗。

## 1. 页面里有什么

| 区块 | 内容 | 数据来源 |
|---|---|---|
| 铭牌 | 本机名称（默认「模块化终端（第一代）」，可改名）+ 型号「模块化终端（第一代）」 | 名称：`QSettings` 的 `about/device-name`；为空回落到默认值 |
| 设备信息 | 处理器（型号 × 核数 · 架构）、内存（总量 / 可用）、存储（总量 / 可用）、内核（`Linux <版本>`） | `/proc/cpuinfo`（含 `model name` / `Hardware` / `Processor`）、`/proc/device-tree/model`、`QThread::idealThreadCount()`、`QSysInfo`、`/proc/meminfo`、`statvfs("/")` |
| 版本号 | `build 2026-10-31` | CMake 每次构建生成的 `build-info.h`（`ORANGE_PI_BUILD_DATE`） |
| 运行记录 | 原来设置页最后一行的日志列表 | `systemTools.logs`（内容未改，只是换了位置） |
| 软件更新 | 按钮「检查更新」→ 占位弹窗「功能完善中，敬请期待。」+「知道了」 | 纯 UI，无网络、无假下载 |

顺序按需求固定为：名称 → 型号 → 处理器 → 内存 → 存储 → 内核 → 版本号 → 运行记录 → 软件更新。

## 2. build 日期规则（重要）

**每次改完代码，必须重新构建一次，日期才会更新。**

- `pi_terminal/cmake/WriteBuildInfo.cmake` 在**每次构建**时把当天日期写进
  `<build 目录>/build-info.h` 的 `ORANGE_PI_BUILD_DATE`。
- 为什么不用 `__DATE__`：`__DATE__` 只在包含它的编译单元重编时才变。只改 QML 的增量构建
  不会重编 `main.cpp`，日期会一直停在旧值，和「每次改动同步日期」的诉求冲突。
- 写入前会比较内容，日期没变就不写文件，避免每天第一次之后的无谓重编。
- `build-info.h` 是生成物，**不要手改**，也不要提交进仓库。
- 验证：`cat pi-terminal/build/build-info.h` 应看到当天日期；界面「版本号」行应与它一致。

## 3. 实现边界（没有做什么）

- **不改作者原有的产品名与型号**：登录页 / 锁屏右上角的「树莓派终端 1.0」、`applicationName`
  （`OrangePiTerminal`）、托盘提示「Orange Pi 模块化终端」全部原样保留。本机名称只存在于设置里。
- **不写 `/etc/hostname`**，不调用 `hostnamectl`，改名不影响 shell、SSH 或其它程序。
- 型号「模块化终端（第一代）」是本轮暂定值，集中在 `AboutDevicePage.qml` 的 `modelName` 一处，将来换真实型号只改这里。
- 不做联网检查更新、不做下载、不伪造版本号；软件更新弹窗里也没有假进度条。
- 硬件信息读不到时显示「未知」，不编造数值。

## 4. 代码位置

| 文件 | 作用 |
|---|---|
| `src/core/MachineInfo.{h,cpp}` | `Q_INVOKABLE snapshot()`：CPU / 内存 / 存储 / 内核 / buildDate |
| `src/app/TerminalApplication.cpp` | 注册 `machineInfo` 上下文属性 |
| `qml/AboutDevicePage.qml` | 二级页：滑入、改名、信息行、运行记录、软件更新弹窗 |
| `qml/AboutInfoRow.qml` | 信息行（图标 + 标签 + 右对齐的值） |
| `qml/Main.qml` | 设置页「关于本机」入口、`aboutDeviceOpen`、页面挂载、Escape 守卫 |
| `qml/I18n.qml` | 新增文案的中英对照 |
| `qml/icons/material/{dark,light}/{info,tag,system_update,developer_board}.svg` | 自绘 Material 风格图标（24dp 网格） |
| `src/ui/SystemTools.cpp` | `pageSettingPrefixes()` 增加 `about/`，允许页面写本机名称 |
| `CMakeLists.txt` + `cmake/WriteBuildInfo.cmake` | build 日期生成目标与 `build-info.h` |

## 5. 交互细节

- 页面从右侧滑入 240 ms（OutCubic），与「连接设置」同一套模式；返回箭头或 Esc 关闭。
- 点铅笔进入编辑态；**点输入框才弹虚拟键盘**（复用 `FloatingKeyboard`，键盘代码未改）。
  键盘弹出后页面自动把编辑行滚到可视区，避免输入内容被键盘挡住。
- 编辑行：输入框 + 保存 + 取消；「恢复默认」在名称行右侧（编辑态出现）。
- 保存 / 恢复默认后自动收起键盘。
- 设置页入口只对管理员与普通用户显示；访客（临时会话）看不到本机信息，也不能改本机名称。

## 6. 验证

- `cmake --build build -j` 与 `cmake --build build-tests --target terminal_ui orange_pi_terminal` 均通过；
  两个 build 目录的 `build-info.h` 都是构建当天。
- Xvfb 1024×600 实测（截图在仓库外的 `orpi-run-20261031/ab*.png`）：
  - 设置页最后一行入口卡片 → 右侧滑入；
  - 处理器 `AMD Ryzen 7 8745HS w/ Radeon 780M Graphics × 16 · x86_64`、内存 `11 GB（可用 6.4 GB）`、
    存储 `116 GB（可用 50 GB）`、内核 `Linux 7.0.0-113038-tuxedo`、版本号 `build 2026-10-31`；
  - 改名保存写入 `OrangePiTerminal.conf` 的 `[about] device-name`，重启后仍生效；
  - 「恢复默认」把该键写空、界面回落「模块化终端（第一代）」；
  - 软件更新弹窗（图标 + 文案 + 「知道了」）；
  - 切到 English 后整页与弹窗均为英文（`About this device` / `AVAIL free of TOTAL` / `Coming soon.`）。
- 日志里与本页相关的 QML 报错为 0。仅有的两条 `Layout polish loop` 来自既有的
  `UserSecurityPage.qml`（不可见页宽度 0 时布局），与本次改动无关。

## 7. 没验证的

- 真实 Orange Pi / ARM 板上的 `cpuModel` 走 `Hardware` 或设备树分支的实际字符串（只在 x86_64 主机验证过）。
- 普通用户与访客两条账号路径的截图（可见性条件写在 QML 里，未逐条截图）。
- 英文界面逐条目检（词表已补齐，见 `I18n.qml`）。

## 8. 第二轮修复（同日）

用户实测反馈的四个问题，已全部修掉并复验：

| 问题 | 根因 | 修法 |
|---|---|---|
| 改名输入框上方有「输入本机名称」字样 | `CarField` 的 `placeholderText` 被 Material 样式当成浮动标签 | 去掉 `placeholderText` |
| 键盘打开后关不上 | 输入框的 `onActiveFocusChanged` 在键盘关闭、焦点回流时又请求一次键盘，刚关就被顶起来 | 键盘只在**点击输入框**时请求（`TapHandler`），并给「取消」补上 `keyboardDismissRequested` |
| 锁屏「已锁定」输满 6 位没有确认键 | `PinPad.showCancel` 默认为真，左下角是「取消」，确认键只在登录页出现 | 锁屏设 `showCancel: false`（左下角变 ✓），「退出登录」挪到锁屏右上角图标 |
| 设置页「网络与连接」下的供电 / 热点 / 接口地址太技术 | — | 移入开发者面板，拆成 `INTERFACES` / `POWER` / `HOTSPOT` 三个只读框；设置页只留热点开关 + 一行状态 |

同轮另外两件事：

- **开发者面板的代码框完全只读**：`readOnly` + `selectByMouse: false` + `cursorVisible: false` + `activeFocusOnTab: false`，
  拖选不再出选区；鼠标形状从 I-beam 改为箭头。要拿内容只能点顶部的 Copy all / Export。
- **关于本机新增 GPU 与网卡**：GPU 读 `/sys/class/drm/card*/device/uevent` 的 `DRIVER` / `PCI_ID`，
  再用 `/usr/share/misc/pci.ids` 解出厂商+型号（本机：`Advanced Micro Devices, Inc. [AMD/ATI] Phoenix3 · amdgpu`）；
  无线 / 有线网卡各一行，列接口名、IPv4、MAC（本机：`wlp3s0 · 192.168.31.72 · 50:FE:0C:26:DA:10` / `enp2s0 · B0:25:AA:96:A7:E5`）。
  网卡过滤 `lo`、`docker`、`veth`、`br-`、`virbr`、`tun`、`tap` 等虚拟接口。

### 验证

- 键盘：打开 → 点 X 关闭后保持关闭；再打开 → 点「取消」同时收起键盘。
- 锁屏：60 秒自动锁 → 输 6 位 → 左下角 ✓ 变亮 → 点击解锁成功；右上角出现退出登录图标。
- 开发者面板：NETWORK 下方依次出现 INTERFACES / POWER / HOTSPOT；在只读框里拖拽不出选区。
- 设置页：网络与连接组只剩「开启热点 / 关闭热点 / 热点，已关闭」。
- 关于本机：处理器 → 图形处理器 → 内存 → 存储 → 内核 → 版本号 → 无线网卡 → 有线网卡 顺序正确。

### 仍然没验证的

- 锁屏右上角「退出登录」只做了代码路径确认（信号与旧「取消」相同），未单独截图。
- 英文界面下 GPU / 网卡几行的词表是否逐条命中（`GPU` / `Wi-Fi adapter` / `Ethernet adapter` / `Not detected` 已补进 `I18n.qml`）。
- ARM 板上的 GPU 读取走设备树兜底分支，只在 x86_64 + amdgpu 上验证过。
