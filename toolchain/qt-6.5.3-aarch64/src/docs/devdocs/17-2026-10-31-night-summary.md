# 2026-10-31 夜间轮：设置页收尾、关于本机、联网权限二级页

> 本文汇总 `15-about-device-2026-10-31.md`、`16-network-permissions-2026-10-31.md` 之外的其余改动，
> 以及本轮的统一构建/验证方式。打包快照时以本文为入口。

## 0. 一句话

设置页从「一堆技术信息平铺」收成：联网权限（总开关 + 二级页）、网络与连接（热点开关）、
开发者选项（管理员）、关于本机（设备信息/版本/软件更新）。同时修掉键盘关不上、
锁屏无确认键、联网权限子开关点了没反应三个 bug。

## 1. 改动清单

### 1.1 关于本机（新页）

- 设置页最后一行入口 → 右侧滑入二级页（240ms）。
- 内容：本机名称（可改，默认「模块化终端（第一代）」）、型号（同名字符串）、
  处理器、GPU、内存、存储、内核、版本号（`build YYYY-MM-DD`）、无线/有线网卡、运行记录、软件更新（占位弹窗）。
- 名称只写应用设置 `[about] device-name`；不改 `/etc/hostname`，也不动作者原有产品名
  （「树莓派终端 1.0」、`OrangePiTerminal`、托盘名）。
- 细节见 `15-about-device-2026-10-31.md`。

### 1.2 build 日期（不再用 `__DATE__`）

- `pi_terminal/cmake/WriteBuildInfo.cmake` 在**每次构建**时生成 `<build>/build-info.h` 的
  `ORANGE_PI_BUILD_DATE`；内容相同则不重写，避免无谓重编。
- 规则：**每次改完代码重新构建一次**，版本号才会跟着走。`build-info.h` 是生成物，不要手改、不要提交。

### 1.3 GPU 与网卡

- GPU：`/sys/class/drm/card*/device/uevent` 的 `DRIVER` / `PCI_ID`，再用 `/usr/share/misc/pci.ids`
  解出厂商+型号；pci.ids 缺失时退为驱动 + PCI ID；ARM 无 PCI 时退到设备树 `compatible`。
- 网卡：`QNetworkInterface`，只留物理接口（过滤 `lo`/`docker`/`veth`/`br-`/`virbr`/`tun`/`tap`），
  无线与有线各一行，列接口名、IPv4、MAC。

### 1.4 键盘关不上（bug）

- 根因：改名输入框的 `onActiveFocusChanged` 在键盘关闭、焦点回流时又请求一次键盘。
- 修法：键盘只由**点击输入框**触发（`TapHandler`）；「取消 / 保存 / 恢复默认」都收键盘。
- 输入框不再显示「输入本机名称」占位字样。

### 1.5 锁屏确认键（bug）

- `PinPad.showCancel` 默认 true，锁屏左下角是「取消」，输满 6 位没有可点的确认。
- 锁屏改为 `showCancel: false`（左下角变 ✓，满 6 位变亮），「退出登录」挪到右上角图标。

### 1.6 网络信息搬进开发者面板

- 设置页「网络与连接」只剩热点开关 + 一行状态、供电与接口地址移走。
- 开发者面板新增 `INTERFACES` / `POWER` / `HOTSPOT` 三块只读框（与其它栏同款）。
- 面板里所有代码框：`readOnly` + `selectByMouse: false` + `cursorVisible: false` +
  `activeFocusOnTab: false`，拖选出不了选区，鼠标是箭头；内容只能 Copy all / Export。

### 1.7 联网权限二级页（bug + 重构）

- bug：子开关 `checked` 绑的是 `networkGate.featureEnabled(...)` 方法，QML 追不到依赖，
  `changed` 后按钮不刷新 → 看起来"点了没反应"。改用 `browserAllowed` 等 Q_PROPERTY。
- 结构：设置页只留总开关 + 说明 + 「管理各功能联网」；二级页放六个开关、各自说明、
  总开关关闭时的锁定提示。没有底部小字，没有连接三态卡（已按要求删除）。
- 细节见 `16-network-permissions-2026-10-31.md`。

## 2. 构建与运行

```bash
cd pi-terminal
cmake -S pi_terminal -B build -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/orange_pi_terminal --window-size 1024x600
```

- 桌面（X11）直接跑；无显示器时用 `Xvfb :99 -screen 0 1024x600x24` + `DISPLAY=:99`。
- 测试树：`cmake -S pi_terminal -B build-tests -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release`。
- `build/` 与 `build-tests/` 是构建产物，未打进快照压缩包。

## 3. 本轮验证方式

- 每项都在 Xvfb 1024×600 上实际点过：截图见仓库外 `orpi-run-20261031/`（`ab*.png` 关于本机、`np*.png` 联网权限）。
- 日志检查：`grep -c "polish loop"`、`TypeError|Cannot assign` 均为 0（仅 `UserSecurityPage` 有两条既有的布局警告）。
- 没有新增 ctest；`ctest` 的 UI 审计在 build-tests 里本来就有既有失败（`ui_responsive_touch` 等，历史运行次数 0），本轮未处理。

## 4. 已知未验证 / 遗留

- ARM 板上的 GPU（设备树分支）与 `pci.ids` 缺失路径只在 x86_64 + amdgpu 上验证过。
- 英文界面下新增页面只做了词表补齐，未逐条截图。
- 锁屏右上角「退出登录」只确认了代码路径（与旧「取消」同一信号），未单独点过。
- `ui_responsive_touch` / `ui_highdpi_touch` / `pairing_ui_page` 在 build-tests 里失败，
  与历史一致（`CTestCostData.txt` 运行次数 0），未排查。
- `FetchBudget` 仍未实例化（此前遗留）。
