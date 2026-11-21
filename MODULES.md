# 模块索引

本表是模块命名与身份的**唯一权威**。目录、`manifest.id`、中文名、`module_id` 必须一起改，并同步跑
`python3 -m unittest tools/tests/test_modules_index.py`。

- 目录名：英文 kebab-case 产品名，ESP 侧在 `esp/modules/<目录名>/`，SDK 侧在 `module-devkit/examples/<目录名>/`。
- `manifest.id`：包命名空间，`<命名空间>.<功能>`；`name` 是终端上显示的中文名。
- `module_id`：1–255，必须落在目标 Pi profile 的接受范围内，不能只改这里就假设能接入。
- 形态：**完整双端**（ESP 固件 + 主机插件 + QML）、**仅主机**（没有 ESP 固件）、**独立产品**（不是模块包）。
- 构建基线：模块 SDK 为 **Qt 6.5.3 / API v3**（`platform_api=2`、`min_host_api=3`、必须有
  `data_schema`）。仓库里的 `pi_terminal` 源码仍在开发中（v2），最新终端软件在另一台机器上；
  同步前这些模块只能做离线构建、单测和 QML 加载验收。

## 模块

| 目录名 | 中文名 | `manifest.id` | `module_id` | 形态 | 传输 | ESP 目录 | SDK 示例 |
|---|---|---|---|---|---|---|---|
| `smart-planter` | 智能盆栽 · 环境看板 | `planter.environment` | 80 | 完整双端（ESP + 主机 + QML） | 固定 Pi 热点 LAN | `esp/modules/smart-planter/` | `module-devkit/examples/smart-planter/` |
| `bed-sensor` | 床边守护 | `bed.guardian` | 84 | 完整双端（ESP + 主机 + QML） | BLE | 仅在 SDK 示例内 | `module-devkit/examples/bed-sensor/` |
| `blood-pressure` | 血压读数 | `health.pressure` | 83 | 仅主机（无 ESP 固件） | 固定 Pi 热点 LAN | — | `module-devkit/examples/blood-pressure/` |

## 演示工程

| 目录名 | 中文名 | `manifest.id` | `module_id` | 形态 | 说明 |
|---|---|---|---|---|---|
| `planter-fake` | 智能盆栽 · 演示看板 | `planter.fake` | 80 | 桌面演示（仅 x86_64） | 页面自己生成假数据，不接传感器；`module_id` 与真盆栽相同是故意的，不能用于实机部署 |

## 独立产品（不是模块包）

| 目录 | 产品 | `module_id` | 形态 | 说明 |
|---|---|---|---|---|
| `projects/xiaotian-pogo/` | 啸天红外护栏 pogo | 81 | 独立 HTTPS 设备 | 固件 2.1 + 独立 Pi 面板 + USB/HTTPS 工具；走 `xiaotian_https_v2`，不是 `module_data_service` 模块包。旧的 `xiaotian.fence` id 82 mock 已移入 `archive/2026-11-21-xiaotian-fence-mock/` |

## 不是模块

| 目录 | 角色 |
|---|---|
| `esp/bridge/S3_PiBridge_LinkIt_Host/` | 控制桥固件：LinkIt 模块通道、RC522 NFC、PBR1 上行 |
| `module-devkit/template/` | 新模块的最小完整工程，`module_devkit.py init` 的生成源 |

## 新增模块

1. `python3 module-devkit/module_devkit.py init <目录> --module-id <ID> --name "<中文名>"`
2. 在本表登记；`module_devkit.py validate <目录>` 与索引测试必须通过。
3. 若模块也有正式固件，放到 `esp/modules/<目录名>/`，并把 ESP 目录列填上。
4. 独立产品放 `projects/<目录名>/`，并在“独立产品”区登记，不要伪装成模块包。
