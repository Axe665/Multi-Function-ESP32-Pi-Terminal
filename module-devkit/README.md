# 模块开发者工具包

> 路径说明：旧文档里的 `esp/...` 现在就在仓库根 `esp/`（`esp/modules/`、`esp/bridge/`、`esp/shared/`）。
> 外部仓库 [gggitj/ESP-Modular-Terminal-Service](https://github.com/gggitj/ESP-Modular-Terminal-Service) 的相对路径不变。


面向固定 ESP32-S3 / LinkIt / Pi 终端平台的独立 SDK。复制本目录即可开发，不需要主仓库源码。主机 `.so` 在 Pi 上运行，ESP 负责传感器、控制面、数据面及插件包提供。

## 能力边界（先读）

这份公开 SDK 覆盖“打包、签名、验签、清单校验、明文 mock 联调”，**不等于**能直接
对接当前 Pi 终端：

- Pi 的 LAN 业务面强制 **TLS 1.2+ + 证书指纹 pin + CN == module_id**；
- Pi 的 BLE 业务面强制 **32 字节 session key + `0xB1‖challenge` HMAC 挑战应答**；
- 公开 SDK 的 ESP 数据面仍是裸 TCP / 无 HMAC 实现（`module_data_service`）。

因此用本 SDK 的 `examples/` 或 `template/` 构建的固件，在当前 Pi 上会停在
`session_ready` 之前。正式 `esp/modules/smart-planter` 是否已带安全数据面不在本快照内；
在补齐前，请把本文的“离线包验证”与“业务面联调”分开验收。

另外注意：BLE 示例配置的 write/notify UUID 是
`9b860002-214c-4de0-a9f4-f70e6a100002` / `9b860003-214c-4de0-a9f4-f70e6a100003`；
此前示例误写成两个 `…100001`，按旧示例接真实硬件会找不到特征（已修）。

## 目录导航

| 路径 | 内容 |
| --- | --- |
| `module_devkit.py` | 初始化、环境检查、离线测试、校验、`data_schema`、资源整理、签名发布 |
| `firmware-build.sh` | 构建指定模块工程的固定 BLE/LAN 变体，不烧录 |
| `ai_guide.py` | 为模块生成 AI 开发上下文 |
| `mock-device.py` | 本机回环 TCP/HTTP 模拟设备入口 |
| `sdk/include/` | 稳定主机 C ABI 和 C++ 辅助头文件 |
| `sdk/esp32/` | 独立 LinkIt、控制面、业务数据面、标准板组件 |
| `toolchain/module-aarch64.cmake` | aarch64 交叉工具链：自动探测 Qt 6.5.3 SDK，校验基线，关闭 RPATH |
| `template/` | 最小完整模块：ESP 固件 + 主机插件 + 通用 QML 页面 + 组件 + 测试 |
| `examples/smart-planter/` | 智能盆栽（id 80）：完整双端，植物图示、日/周温度历史、电量、LCD 与供电保护 |
| `examples/bed-sensor/` | 床边守护（id 84）：完整双端，四路 HX711、重心/离床/翻身/坐起状态机 |
| `examples/blood-pressure/` | 血压读数（id 83）：仅主机，录入/接收测量并校验边界 |
| `examples/planter-fake/` | 智能盆栽演示（id 80）：仅 x86_64，桌面假数据，不用于实机 |
| `projects/xiaotian-pogo/` | 啸天红外护栏（module_id 81）：独立 HTTPS 产品基线，**不是模块包** |
| `tools/` | 自带的签名/验签配包器和模拟协议实现 |
| `docs/` | AI 分阶段指南、物理验收清单、SDK维护与同步说明 |
| `artifacts/` | 本机比赛构建产物（v2 历史签名包）。**不能装到 v3 宿主**；保留用于追溯，重新签名前不得分发 |

### 主要文档

- [AI coding 引导](docs/AI-CODING-GUIDE.md)
- [物理 Pi 验收清单](docs/PHYSICAL-PI-TEST.md)
- [SDK 与正式 ESP 源码的维护关系](docs/MAINTENANCE.md)
- [智能盆栽完整示例](examples/smart-planter/README.md)
- [智能盆栽已测/未测范围](examples/smart-planter/VALIDATION.md)
- [简体中文LCD布局与颜色传输](examples/smart-planter/firmware/components/ui_env/LCD-DESIGN.md)
- [中文字体、许可证及生成方式](examples/smart-planter/firmware/components/ui_env/fonts/README.md)

## 从零开始

下面从 SDK 目录执行；在主仓库中先 `cd module-devkit`。

```sh
python3 module_devkit.py doctor
python3 module_devkit.py init /path/to/my-module --module-id 200 --name "我的模块"
python3 module_devkit.py test /path/to/my-module      # cmake + ctest + QML 离屏加载
python3 ai_guide.py /path/to/my-module --module-id 200 --transport LAN
python3 module_devkit.py validate /path/to/my-module
```

**数据格式（P1，可选）**：模块需要在 `manifest.json` 顶层声明 `data_schema`。SDK 提供三个离线命令：

```sh
python3 module_devkit.py schema init  /path/to/my-module
python3 module_devkit.py schema check /path/to/my-module
python3 module_devkit.py schema check /path/to/my-module --strict
python3 module_devkit.py schema migrate /path/to/my-module --to 2
```

`schema init` 只生成草稿，字段类型/required/范围仍需人工确认。`schema check` 解析 `appData.append` / `appendSample/Measurement/Reading` 的参数：对象字面量、`const payload = {...}`、`payload.field = ...`、`...base` 展开、`Object.assign`、同文件/跨文件函数返回值，以及 C++ 的 `QJsonObject` / `QVariantMap` + `appData.append(...)` / 裸 `appendSample(...)`。C++ 只取字段名，不猜类型；`emit_event` 的载荷是线上遥测，不属于 `data_schema`，不参与字段校验。动态键、无法静态解析的函数返回值会打印 `[WARN]`；`--strict` 下按失败处理。它仍是静态近似，不是编译器级分析；宿主运行时 `DataSchema::validateRecord` 是最终防线。`schema migrate` 默认只加字段；删/改字段必须加 `--force`，执行前会打印受影响字段清单。宿主已切 `PI_MODULE_API_VERSION=3`：缺 `data_schema`、`platform_api=2` 或 `min_host_api=3` 的包在加载前拒载。

让 AI 阅读生成的 `AI-CONTEXT.md` 和 `docs/AI-CODING-GUIDE.md`。最小模板不是完整业务实现；希望直接参考真实传感器、图示、历史存储和测试时，阅读智能盆栽示例。

**模块身份不能随意改后就保证接入。** 模块 ID、实例、地址、token 必须与既有 Pi profile 的接受范围一致；本项目实测智能盆栽使用 module_id=80。不修改 Pi 配置的前提下，应沿用已 provision 的身份及签名链。

## 模块能用到的宿主能力（v3）

新模块不只是「收数据、画页面」，宿主还提供了这些能力。完整签名与踩坑说明见
[docs/AI-CODING-GUIDE.md](docs/AI-CODING-GUIDE.md) 的「宿主能提供什么」一节。

**QML 侧（模块页直接可用，无需 import）**

| 属性 | 用途 |
| --- | --- |
| `appData` | 模块数据入口（v3 名；`moduleData` 是兼容别名）：`records`、`append`、`query`、`series`、`validateRecord` |
| `appAdvice` | 建议通道：`setModuleId` + `request({record, windowMs})`，异步回 `adviceReady` / `adviceFailed` |
| `appNetwork` | 异步 HTTP(S)：`request({method,url,headers,bodyBase64,timeoutMs})` → `finished(id, response)` |
| `appFiles` | 受控文件：`request(op, args)`；写权限需先 `requestWriteAccess()` |
| `sessionModel` / `userContext` / `hostTheme` | 会话、用户、主题 |

**C++ 侧（`pi_host_services`，SDK 已封装在 `pi_module_sdk.h`）**

`send_data`、`send_control`（仅桥板诊断）、`emit_event`、`publish_event`、`publish_action`、
`data_directory`、`log`、`network_request`、`file_request`。

三个容易踩的坑：

- **C++ 的 `network_request` / `file_request` 是同步阻塞**（最长 35 s），不要在 `on_data`
  热路径里调；QML 的 `appNetwork.request` 才是异步的。
- 返回的 `const char*` 只活到下一次调用。`pi_module_sdk` 已拷成 `std::string`。
- 老宿主的函数指针可能是空的，调用前判空（封装里已经做了）。

网络上行的业务数据一律走 `send_data`；`send_control` 是 PBR1 桥控制面，不是业务通道。

## Qt 基线：模块只有 6.5.3

**模块 SDK** 统一在 **Qt 6.5.3**，6.4.x 已不支持。模板与所有 `examples/` 的
`CMakeLists.txt` 都写 `find_package(Qt6 6.5 REQUIRED COMPONENTS Core)`，低于 6.5
直接配置失败——这是故意的，别为了编过把门槛调低。

仓库里的 `pi_terminal` 宿主源码仍在开发中（当前最低 6.4，API v2）；最新终端软件在
另一台机器上，同步前这些 v3 模块只能做离线验收，不能在本仓库宿主里加载。

**不要用板端系统 Qt 编模块。** Pi 的发行版 Qt 是 6.4.2，用它编出来的 `.so` 会和宿主的
6.5.3 运行时不匹配；症状是模块加载失败或运行时找不到符号，而错误现场离构建很远。
正确做法是用 `dist/sdk/qt653-arm64`（Qt 6.5.3 aarch64 开发树）交叉编译。

## 主机构建与资源整理

交叉编译用 devkit 自带的工具链，它会自动探测 `dist/sdk` 三件套并校验 Qt ≥ 6.5：

```sh
python3 module_devkit.py doctor        # 先看 aarch64 那一节的 OK/MISSING
cmake -S /path/to/my-module -B /path/to/host-build \
  -DMODULE_SDK_DIR="$PWD/sdk" \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchain/module-aarch64.cmake"
cmake --build /path/to/host-build --parallel
python3 module_devkit.py stage /path/to/my-module /path/to/host-build \
  /path/to/package --arch aarch64
```

三件套（`qt653-arm64` / `host-qt` / `pi-sysroot`）是 4 GB 级二进制，**不随本 SDK 源码分发**。
在项目仓库里用仓库根的 `./tools/fetch_artifacts.sh` 下载到 `dist/sdk/`；单独使用本 SDK 时，
从项目 Release（tag `sdk-v1`）取这三件放到 `<devkit>/dist/sdk/`。也可以用自己的路径覆盖：

```sh
export ORPI_QT_PREFIX=/path/to/qt653-arm64
export ORPI_SYSROOT=/path/to/pi-sysroot
export ORPI_HOST_QT=/path/to/host-qt
export ORPI_STUB=/path/to/isoc23_compat.o   # 可选，见下
```

工具链做了两件容易被忽略但必须做的事：

- **不写 RUNPATH**。CMake 交叉编译默认会把 Qt 的绝对路径写进产物的 RPATH/RUNPATH；
  模块要在目标机上由宿主进程加载，那条开发机路径并不存在。`release`/`stage` 之后
  `module_devkit.py` 会检查并拒绝带开发机路径的产物。
- **`isoc23` 兼容桩**。宿主的 aarch64 交叉包 glibc 是 2.39，sysroot 是 2.36；不补桩时
  产物会记录 `GLIBC_2.38` 需求，在目标板上报 `version 'GLIBC_2.38' not found`。
  工具链用 `-L` 把 sysroot 的 libc/libm 提前，并注入 `cross-build/isoc23_compat.o`。

`stage` 核对实际 ELF 架构并收集整个 QML 目录，不只收集入口页面。输出目录必须为空，避免混入旧资源。Pi 插件需要 ARM64；本机 x86_64 库不能当作 Pi 产物。

## 通用 QML 页面模板

`template/qml/ModulePage.qml` 是一份**结构与信息层级参照智能花盘、但不写死任何颜色**的
通用页面，`init` 生成的新模块直接就能跑起来。它已经接好宿主注入的全部接口：

- **数据**：`appData.query(record, {limit:1})` 定时取最近一行，用 `received_at` 判断在线
  （15 s 余量），而不是「有没有数据」——拔线后历史还在，只看有无数据会一直显示在线；
- **建议**：`appAdvice` 完整状态机（`ready` / `busy` / `NO_ADVICE` / `error` / `unavailable`），
  `adviceReady` 的 `payload` 是 `{items:[{text,risk}], source}`，`source` 区分云端模型与端侧本地方案；
- **布局**：建议入口卡 → 标题行 → Hero 卡（带主视觉插槽）→ 指标网格（列数随数量自适应，
  宽屏最多 4 列、窄屏 2 列）→ 页脚说明；建议页整幅同色底右滑，沿用花盘的平移动画。

颜色策略是这份模板的重点：宿主只注入 `background` / `surface` / `foreground` / `accent` / `scale`
五个令牌，模板**不写任何色值**，卡片层次靠 `veil(alpha)`（前景色低透明度）和
`accentVeil(alpha)` 派生。因此同一份页面在浅色与深色主题下都成立，也不会和宿主主题打架。

指标卡、趋势图、状态徽标拆成 `qml/components/MetricTile.qml`、`TrendChart.qml`、
`StateBadge.qml`；状态统一为 `live / stale / offline / loading / error / empty` 六种。

新模块主要改文件顶部「模块配置」那一段：`kicker`、`headline`、`heroNote`、
`sampleRecord`（换成自己 `data_schema` 里的记录名）、`metrics`、以及可选的 `heroVisual`。

## 模块业务逻辑测试

模板自带一个测试骨架，不需要真机、不需要装模块：

```sh
cmake -S /path/to/my-module -B /path/to/test-build \
  -DMODULE_SDK_DIR="$PWD/sdk" -DMODULE_TESTING=ON \
  -DCMAKE_PREFIX_PATH=/path/to/Qt/6.5.3/gcc_64
cmake --build /path/to/test-build --parallel
ctest --test-dir /path/to/test-build --output-on-failure
```

它用一个假 host 把 `emit_event` 抓下来，断言模块按 manifest 声明的 `data_schema` 发了记录。
真机上出现「页面没数据」时，先跑这个能区分是模块没发，还是宿主没接。

## 签名与固件

```sh
python3 tools/package_tool.py build /path/to/package /path/to/signed /secure/private.pem aarch64
python3 tools/package_tool.py install-local /path/to/signed /secure/public.pem /path/to/test-cache 80 aarch64
python3 module_devkit.py prepare-firmware /path/to/signed /path/to/embedded
export PI_MODULE_SDKCONFIG=/secure/sdkconfig
export PI_MODULE_PACKAGE_DIR=/path/to/embedded
./firmware-build.sh /path/to/my-module LAN /path/to/firmware-build
```

签名可留在持有私钥的机器上完成。示例中的 `80` 应与实际模块一致；BLE和LAN使用独立构建目录。固件构建会将嵌入包复制到目标工程的 `firmware/`，这些生成文件已忽略。

也可使用 `module_devkit.py release PROJECT OUTPUT KEY --arch aarch64 --toolchain TOOLCHAIN --firmware-mode LAN --sdkconfig CONFIG` 完成构建和配包闭环。需要本机可读取签名私钥；不希望私钥离开 Pi 时，使用上面的 `stage` 和分离签名流程。

## 平台规则与边界

- 控制面走 LinkIt/PBR1；业务只走认证 BLE 或固定 Pi 热点 LAN/TCP，不跨模式回退。
- `attach` 不是业务就绪；认证、身份、序号及 `session_ready` 都通过才算建立会话。
- 沿用 Pi 当前发布公钥时无须修改 Pi 配置；包须由匹配私钥签名。SDK不自带私钥，不能凭公钥生成匹配私钥。
- 可脱离实机开发、构建和签名，前提是已有工具链与匹配私钥；最终硬件验收仍需实机。
- `pi_module_stop()` 同步停止所有线程、定时器、回调和发送后才允许卸载。
- 没有可靠外部电源检测接线时，供电来源为 unknown；不能用电池电量计推断USB供电。硬件过放保护、自锁按钮及真正切电不是软件或SDK可以替代的。
- 不自动刷写ESP、不改Pi信任配置、不停止终端服务。私有配置、密钥及Flash备份不公开分发。
