# @MODULE_NAME@

> 模块：@MODULE_NAME@ ｜ id @MODULE_ID@ ｜ 形态：完整双端（ESP + 主机 + QML）

由 `module_devkit.py init` 生成的最小完整模块。能离线完成：主机插件构建、ABI/manifest
测试、QML 离屏加载、固件编译、签名打包和 mock 联调；实机烧录与 Pi 会话验收仍需硬件。

## 目录

| 路径 | 内容 |
| --- | --- |
| `module.cpp` | 主机插件：ABI 入口、数据解析、action |
| `manifest.json` | 包身份与宿主契约（`module_id`、`platform_api`、`network_api`、`file_api`） |
| `qml/ModulePage.qml` | 模块页面，只依赖宿主注入项 |
| `qml/components/` | `MetricTile` / `TrendChart` / `StateBadge`，可改可删 |
| `firmware/` | ESP32-S3 固件：平台对讲 + 每秒模拟读数 |
| `tests/` | ABI/manifest/action 单测 + QML 离屏加载 |

## 快速开始

```sh
python3 module_devkit.py test <本目录>
```

它依次做 cmake 配置、构建、ctest。Qt 可用 `--qt-prefix` 指定，或让 cmake 自己找。

固件：

```sh
python3 module_devkit.py prepare-firmware <signed-package> <本目录>/firmware
export PI_MODULE_SDKCONFIG=/secure/sdkconfig
module-devkit/firmware-build.sh <本目录> LAN <build-dir>
```

`init` 生成的 `firmware/embedded_package.*` 是**占位包**（`PLACEHOLDER`），只保证
`idf.py build` 能过；签名后必须用 `prepare-firmware` 覆盖。

## 宿主注入项

页面运行时只能看到这些 context property，拿不到宿主单例、数据库或密钥：

- `hostTheme`：`background` / `surface` / `foreground` / `accent` / `scale`。
- `sessionModel`：当前模块的实时数据，字段在 `sessionModel.data`。
- `moduleData`：当前用户的数据接口（`appendSample` / `historySeries` / ...），可能不存在。
- `appNetwork` / `fileApi`：只有 manifest 声明 `network_api: broker` / `file_api: home-read` 时才可用。

## 状态样式

所有页面统一用 `StateBadge` 的六个状态：`live` / `stale` / `offline` / `loading` /
`error` / `empty`。不要每页自造颜色和文案位置。

## 下一步

1. 改 `manifest.json` 的 `name` / `id` / `capabilities` / `actions`。
2. 改 `firmware/main/main.c` 的采样与 JSON 字段。
3. 改 `qml/ModulePage.qml` 的展示与交互。
4. 按 SDK 的 `docs/AI-CODING-GUIDE.md` 和 `docs/PHYSICAL-PI-TEST.md` 推进实机。
