# ESP 固件源码入口

设备侧固件按角色分类。模块目录名、显示名、`manifest.id` 与 `module_id` 的权威索引见仓库根 [MODULES.md](../MODULES.md)。

| 目录 | 角色 | 模块名 | module_id |
|---|---|---|---|
| `bridge/S3_PiBridge_LinkIt_Host/` | 控制桥：LinkIt 模块通道、RC522 NFC、PBR1 上行；2026-11-21 通用透传发布包在 `releases/2026-11-21/` | —（不是模块） | — |
| `modules/smart-planter/` | 模块固件：传感器、LCD、供电保护、认证 BLE/LAN、插件包嵌入 | 智能盆栽 · 环境看板 | 80 |
| `shared/module_data_service/` | TCP/BLE 业务会话及插件包传输 | — | — |
| `shared/module_control_service/` | LinkIt/PBR 控制面 | — | — |
| `shared/pi_sensor_device/` | BME280、BH1750、MAX17043（含采样时间和有效标记） | — | — |
| `shared/lvgl/` | LVGL 8.4.0 运行时子集，保留原许可证 | — | — |

`modules/smart-planter/` 是正式模块源码入口；`module-devkit/examples/smart-planter/firmware/` 是供外部开发者独立使用的导出副本，不依赖主仓库。

啸天红外护栏是独立 HTTPS 产品，不在 `esp/` 分类内：固件、面板和工具在 [`projects/xiaotian-pogo/`](../projects/xiaotian-pogo/README.md)。

```sh
# 从仓库根目录检查正式固件与 SDK 副本的一致性
python3 tools/sync_module_devkit.py --check
```

## 构建

加载 ESP-IDF 5.5.4，提供私有配置和 SDK 生成的签名嵌入包后：

```sh
export PI_MODULE_SDKCONFIG=/secure/sdkconfig
export PI_MODULE_PACKAGE_DIR=/path/to/embedded-package
build_scripts/build_module_variant.sh smart-planter LAN /path/to/module-lan-build
```

桥板：

```sh
build_scripts/build_esp32.sh S3_PiBridge_LinkIt_Host
```

不自动烧录。模块板与控制桥必须按 USB by-id 分辨；Flash、分区及备份必须在每次烧录前核对。私有配置不在构建脚本中覆盖。

## 历史参考包

2026-10-18 的历史交接包在仓库顶层 [`archive/20261018-env-module-handover/`](../archive/README.md)，包含当时的完整源码、配置和镜像。**不是当前构建入口**，仅作追溯，也不再更新。

## 电源保护边界

供电来源未知时不自动低压休眠，避免直接供电误关机；必须用电池保护硬件兜底。可靠供电来源识别需要实际 PG/VBUS 检测接线，大按键硬件断电尚未接入。仅有 MAX17043 不足以判定整机供电来源。
