# planter-fake —— 盆栽演示模块（模块 80）

> 模块：智能盆栽 · 演示看板 ｜ id 80 ｜ 形态：桌面演示（仅 x86_64，不用于实机）

桌面演示用的假盆栽模块：页面与真机盆栽页同一套卡片语言，数据由页面
`qml/ModulePage.qml` 的 `demoMode` 定时生成（每 3 s 平滑变化），不需要
真实传感器，也不需要 IoT 链路。

## 为什么假数据不在 module.cpp 里生成

模块跑在 `module_worker` 的同步阻塞循环里（`module_worker_main.cpp` 只构造
`QCoreApplication`，没有 `exec()`），**没有 Qt 事件循环，QTimer 不会触发**。
所以定时器必须放在有事件循环的一端——页面 QML（主应用引擎）。

`module.cpp` 保持标准 ABI：收到 `on_data` 就记一分钟桶并回补
`history_day/history_week`，符合真模块的契约，只是本演示不依赖它。

## 构建

```bash
cmake -S . -B build -DCMAKE_PREFIX_PATH=/opt/Qt/6.5.3/gcc_64 \
  -DMODULE_SDK_DIR=<repo>/module-devkit/sdk
cmake --build build --parallel 8
# 产物：build/libmodule.so
```

## 铺到桌面演示

`pi_terminal/tools/desktop_demo.py` 打包的是构建目录里的 example 模块，
所以先要把本模块的三样东西铺进 `.orpi-test-build/modules/example/`：

- `manifest.json`（`library=libmodule.so`、`qml_page=qml/ModulePage.qml`）
- `libmodule.so`
- `qml/ModulePage.qml` 及 `MetricTile.qml` / `PlantScene.qml` / `TrendChart.qml`

注意顺序：**必须先 `cmake --build` 再铺**，否则 example 模块会被重新生成覆盖。

## 演示数据开关

`ModulePage.qml` 顶部 `property bool demoMode: true`。接真实传感器模块时改为
`false`，页面就只显示 `sessionModel.data` 推送的读数。
