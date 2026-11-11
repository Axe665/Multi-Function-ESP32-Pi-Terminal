# 端-边-云架构资料

| 文件 | 内容 |
|---|---|
| [`端边云架构图-v2.3.png`](端边云架构图-v2.3.png) | 架构图（2560×1440） |
| [`端边云架构图-v2.3.html`](端边云架构图-v2.3.html) | 同一张图的可交互版本，浏览器打开 |
| [`端边云技术方案-v2.3.docx`](端边云技术方案-v2.3.docx) | 完整技术方案（内部基线） |
| [`架构草案.md`](架构草案.md) | 草案笔记：端侧改造（数据格式、HyperVisor）、三终端联调、边/云职责 |

v2.3（2026-11-11）相对 v2.2 只改模型选型与内存/延迟预算，不动三台终端、边、云的主架构：

| 项 | v2.2 | v2.3 |
|---|---|---|
| 端侧模型 | 规则 + ONNX；Qwen2.5-0.5B 离线兜底（默认关） | **判断和文案分开**：规则 + trend-mlp 负责判断，Gemma 3 270M 只把候选建议写成 ≤40 字中文（候选为空时可补一条低置信度建议）；0.5B 删除 |
| 端侧输出 | `text / risk / confidence / source` | 模型只出 `text / confidence`，`risk` 由规则给，宿主合并成现有 advice payload |
| 端侧训练 | 未定义 | CPT 1–2B token + SFT 2–5 万条 + 中文词表裁剪（附录 G） |
| 端侧常驻内存 | ≤120 MB | HyperVisor ≤120 MB；ONNX ≤60 MB + 文案模型 ≤200 MB |
| 端侧延迟预算 | ONNX p95 <200 ms | trend-mlp p95 <50 ms；端侧文案生成 p95 ≤15 s |
| 云端模型 | Qwen2.5-7B q4 | Qwen3.5-9B q4，关 thinking，4K 上下文 |
| 云端卡型 | P104-100 8GB | 待定（只定模型，不锁型号） |

v2.2 的三个文件已移到 [`../archive/端边云-v2.2/`](../archive/端边云-v2.2/)。

## 端侧还没实现的部分（2026-11 核对）

文档 §3 / §4 / §5.10 / §8 描述的是目标形态，当前 `pi_terminal/` 里没有对应代码：

| 章节 | 要求 | 现状 |
|---|---|---|
| §3.2–3.4 | manifest 带 `data_schema`，通用表 `module_records`，字段级校验 | `ModuleManager` 只认 `platform_api=1`；`ModuleDataApi` 仍只有 `appendSample`，字段硬编码，未知字段丢弃 |
| §3.6 | `module-devkit schema init/check/migrate` | 没有 schema 子命令 |
| §4 | `mt-hypervisor` 常驻进程、假名聚合、k≥5、`agg`/`outbox`、`appAdvice` | 全部没有；跨用户的窗口聚合与假名化都不存在 |
| §4.3 / 附录 G | 规则 + trend-mlp 判断、Gemma 3 270M 写文案（llama.cpp）、云端 Qwen3.5-9B，校验不过回规则模板 | 三类运行时一个都没有：`gemma` / `llama.cpp` / `onnxruntime` / `qwen` 在代码与构建里都搜不到，也没有云端调用与降级链 |
| §4.7 | 第 7 条出网通道 `34007`（advice） | `NetChannels` 只到 34006 |
| §5.7 | 设备证书 / CSR / 与边配对 / mTLS 上报 | 只有桥板与模块的 HostIdentity，没有与边之间的设备身份 |
| §5.10 | headless 构建、10 用户轮换、`--user-rotate` | 没有 headless 目标，没有轮换测试 |
| §8.2 / §8.3 | `device_salt`、L1-out 默认出端、per-subject 删除 token | 都没有；本地隐私只有保留天数 |

边、云两仓按 `orpi.telemetry.v1` 已经能收，但这份包目前没有端在发。

> 这些是**规划文档**，描述目标架构，不代表当前代码已全部实现。
> 代码现状以 [`../project-code-map.md`](../project-code-map.md) 和 `pi_terminal/` 为准。

## 边 / 云实现核对（2026-11）

边、云两仓按 v2.3 §5 / §6 逐条核对过；功能项与两仓 README 的「逐条对照」表一致，
这里只列**还没完全做到**的部分，避免把「驱动已内置但默认没开」写成「已支持」。

| 层 | 章节 | 要求 | 现状 |
|---|---|---|---|
| 边 | §5.4 | 稳健 z（MAD）+ 连续窗口 | 用 7 天同时段基线的 z，连续 2 个窗口 ≥2.5 才算异常；没有 MAD |
| 边 | §5.7.3 | 证书到期前 30 天自动续期 | 只在到期前 30 天写审计提醒；续期由终端提交 CSR 调 `/renew`，边不代签 |
| 边 | §5.7.6 | 吊销后 1 min 内断开 | 消息层按 `device_id` 立即拒收；broker 要重载 CRL 才真正断连 |
| 边 | §5.1 / §13.2 | 宿主跑 Avahi + chrony | compose 里 mDNS 在容器侧；NTP 由宿主负责，未在目标机验证 |
| 边 | §8.2 | 边库磁盘加密 | SQLCipher 驱动已内置，设 `EDGE_DB_KEY` 才加密；默认明文 |
| 云 | §6.1 | 数据卷 `uploads` | 没有上传功能；实际卷是 `pgdata` / `caddy_data` / `backups` / `ollama_models` |
| 云 | §6.4 | AI 报告「生成状态」 | 生成是同步的；报告列表显示模型与 token，没有单独的状态字段 |
| 云 | §6.8 | 模型文件 SHA256 清单 | `/health` 报 Ollama 的 `digest`，配 `CLOUD_OLLAMA_SHA256` 才比对；没有随包清单 |
| 云 | §8.2 | Postgres 卷加密 | 需要宿主 LUKS；代码只保证备份 gpg AES256 |
| 云 | §11.3 | 9B q4 p95 ≤30 s、72 h | 模型未拉取、无推理卡；本机只验了规则模板与 Ollama 桩服务 |
| 云 | §6.8 / §11.3 | NVIDIA / AMD 真卡 | `/health` 与 compose 覆盖文件已支持 CUDA / ROCm，未在真卡上跑过 |

2026-11 用容器冒烟验证过的链路：

- 群体分析开关：边 `PUT /settings` 关掉后，总览、设备详情、series、heatmap、anomalies、advice、batches、wordcloud 全部 `insufficient`；
  报表只带设备在线状态；云 `edges.group_analysis=false`，总览标出该边、日聚合与对比不再包含它；重新打开后恢复。
- mDNS：云广播的 `ca_fp` 与边预置 `cloud-ca` 的 DER 指纹一致（`d7f1ea4c0b11d9de`），边 `/discovery` 的 `source` 为 `mdns`，
  报表经 mDNS 地址走 mTLS 上报成功；指纹对不上时写 `mdns.cloud_rejected` 审计。
- 公网边界：8443 只通 `/ingest/edge-report` 与 `/health`，其余 403，无客户端证书连不上。
- 备份：`pg_dump` 保留 14 天、周日 gpg 加密副本、每月恢复演练。

> 文档自身还有两处待统一的口径：附录 D 与 §13.3 仍按现有 P104-100 写（“卡待定”指下一张卡，
> 两处需要明确是不是同一件事）；§6.3 的模式 A 写 `deepseek-chat` / `qwen-plus`，而代码默认
> `qwen3.5`（可用 `CLOUD_PUBLIC_MODEL` 改）。都不影响当前实现。
