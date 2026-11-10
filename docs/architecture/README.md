# 端-边-云架构资料

| 文件 | 内容 |
|---|---|
| [`端边云架构图-v2.2.png`](端边云架构图-v2.2.png) | 架构图（2560×1440） |
| [`端边云架构图-v2.2.html`](端边云架构图-v2.2.html) | 同一张图的可交互版本，浏览器打开 |
| [`端边云技术方案-v2.2.docx`](端边云技术方案-v2.2.docx) | 完整技术方案 |
| [`架构草案.md`](架构草案.md) | 草案笔记：端侧改造（数据格式、HyperVisor）、三终端联调、边/云职责 |

## 端侧还没实现的部分（2026-11 核对）

文档 §3 / §4 / §5.10 / §8 描述的是目标形态，当前 `pi_terminal/` 里没有对应代码：

| 章节 | 要求 | 现状 |
|---|---|---|
| §3.2–3.4 | manifest 带 `data_schema`，通用表 `module_records`，字段级校验 | `ModuleManager` 只认 `platform_api=1`；`ModuleDataApi` 仍只有 `appendSample`，字段硬编码，未知字段丢弃 |
| §3.6 | `module-devkit schema init/check/migrate` | 没有 schema 子命令 |
| §4 | `mt-hypervisor` 常驻进程、假名聚合、k≥5、`agg`/`outbox`、`appAdvice` | 全部没有；跨用户的窗口聚合与假名化都不存在 |
| §4.7 | 第 7 条出网通道 `34007`（advice） | `NetChannels` 只到 34006 |
| §5.7 | 设备证书 / CSR / 与边配对 / mTLS 上报 | 只有桥板与模块的 HostIdentity，没有与边之间的设备身份 |
| §5.10 | headless 构建、10 用户轮换、`--user-rotate` | 没有 headless 目标，没有轮换测试 |
| §8.2 / §8.3 | `device_salt`、L1-out 默认出端、per-subject 删除 token | 都没有；本地隐私只有保留天数 |

边、云两仓按 `orpi.telemetry.v1` 已经能收，但这份包目前没有端在发。

> 这些是**规划文档**，描述目标架构，不代表当前代码已全部实现。
> 代码现状以 [`../project-code-map.md`](../project-code-map.md) 和 `pi_terminal/` 为准。
