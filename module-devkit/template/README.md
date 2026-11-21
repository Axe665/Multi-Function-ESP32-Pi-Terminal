# @MODULE_NAME@

> 模块：@MODULE_NAME@ ｜ id @MODULE_ID@ ｜ 形态：完整双端（ESP + 主机 + QML）

由 `module_devkit.py init` 生成的最小完整模块。能离线完成：主机插件构建、ABI/manifest/
data_schema 测试、QML 离屏加载、固件编译、签名打包和 mock 联调；实机烧录与 Pi 会话验收
仍需硬件。

目标宿主是 **API v3 / Qt 6.5.3**。仓库里 `pi_terminal` 源码仍在开发中（v2），要等最新终端
软件同步后才能在本仓库宿主里加载本模块。

## 目录

| 路径 | 内容 |
| --- | --- |
| `module.cpp` | 主机插件：ABI 入口、数据解析、action |
| `manifest.json` | 包身份与宿主契约：`module_id`、`platform_api=2`、`data_schema` |
| `qml/ModulePage.qml` | 模块页面：标题 / 主视觉 / 指标 / 趋势 / 建议滑页 |
| `qml/components/` | `MetricTile` / `TrendChart` / `StateBadge`，可改可删 |
| `firmware/` | ESP32-S3 固件：平台对讲 + 每秒模拟读数 |
| `tests/` | ABI/manifest/data_schema 单测 + QML 离屏加载 |

## 快速开始

```sh
python3 module_devkit.py test <本目录>
```

它依次做 cmake 配置、构建、ctest；Qt 默认优先使用 6.5.3，也可用 `--qt-prefix` 指定。

固件：

```sh
python3 module_devkit.py prepare-firmware <signed-package> <本目录>/firmware
export PI_MODULE_SDKCONFIG=/secure/sdkconfig
module-devkit/firmware-build.sh <本目录> LAN <build-dir>
```

`init` 生成的 `firmware/embedded_package.*` 是**占位包**（`placeholder=true`），只保证
`idf.py build` 能过；签名后必须用 `prepare-firmware` 覆盖。

## 宿主注入项

页面运行时只能看到这些 context property，拿不到宿主单例、数据库或密钥：

- `hostTheme`：`background` / `surface` / `foreground` / `accent` / `scale`。
- `appData`：v3 数据入口，`ready` / `schemaReady` / `moduleId` / `lastError`，
  `query(record,{limit})` / `series(record,field,spanMs,stepMs)` / `append(record,fields)`。
  `moduleData` 是兼容别名，保留一个版本周期；新代码写 `appData`。
- `appAdvice`：建议通道，`setModuleId` + `request({record,windowMs})`，异步回
  `adviceReady` / `adviceFailed`。
- `sessionModel` / `userContext`：会话与当前用户。
- `appNetwork` / `appFiles`：只有 manifest 声明 `network_api: broker` / `file_api: home-read`
  时才可用。

## 页面配置

主要改 `qml/ModulePage.qml` 顶部「模块配置」：

- `kicker` / `headline` / `heroNote` / `heroCaption`；
- `sampleRecord`：必须与 `manifest.json` 的 `data_schema.records` 同名；
- `metrics`：`{key,label,unit,note}`，`key` 对应记录字段；
- `trendField` / `trendSpanMs` / `trendStepMs`：留空 `trendField` 即隐藏趋势区；
- `heroVisual`：给一个 `Component` 替换默认几何占位。

## 状态样式

所有页面统一用 `StateBadge` 的六个状态：`live` / `stale` / `offline` / `loading` /
`error` / `empty`。不要每页自造颜色和文案位置；颜色全部从 `hostTheme` 派生。

## 下一步

1. 改 `manifest.json` 的 `name` / `id` / `capabilities` / `actions` / `data_schema`。
2. 改 `firmware/main/main.c` 的采样与 JSON 字段。
3. 改 `qml/ModulePage.qml` 的展示与交互。
4. 按 SDK 的 `docs/AI-CODING-GUIDE.md` 和 `docs/PHYSICAL-PI-TEST.md` 推进实机。
