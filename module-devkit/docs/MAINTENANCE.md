# SDK 源码归属与维护

> 路径说明：旧文档里的 `esp/...` 现在就在仓库根 `esp/`（`esp/modules/`、`esp/bridge/`、`esp/shared/`）。

## 正式工程与独立 SDK

- 仓库正式模块固件：`esp/modules/smart-planter/`（智能盆栽，id 80）。
- 控制桥固件：`esp/bridge/S3_PiBridge_LinkIt_Host/`。
- 共享传感器、数据面及 LVGL：`esp/shared/`。
- SDK 示例的固件：`module-devkit/examples/smart-planter/firmware/`，是正式源码的独立导出副本。
- 主机插件、QML 及其业务测试：只在 SDK 示例维护，不放进 ESP 执行代码。
- SDK 通用模板、CLI、AI 引导属于 SDK 本身，不覆盖到正式 ESP 工程。
- 啸天基线是独立产品，放在 `projects/xiaotian-pogo/`；不是模块包，不参与本同步。
- 2026-10-18 历史交接快照在 `archive/20261018-env-module-handover/`，不是当前维护入口。

为满足外部开发者拿不到主仓库的条件，SDK 不能通过符号链接或相对主仓库路径引用正式固件；
部分源文件必须随包提供。它们是有清单的导出副本，不是两个并行维护分支。

## 同步工具（仅主仓库维护者使用）

从主仓库根目录运行：

```sh
python3 tools/sync_module_devkit.py --check
python3 tools/sync_module_devkit.py --write
```

工具使用明确映射，校验每个源文件和副本 SHA256，清单位于
`module-devkit/sdk/SOURCE-MANIFEST.json`。主仓库快照若没有 `esp/`（独立仓库），
缺失的 canonical source 会输出 `SKIP` 而不是让整条闸门失败；仍会校验
`package_tool.py`、`mock_module.py` 等实际存在的副本。
`ctest -R module_devkit_sync_check` 已接入同一检查。

- `--check` 只读。
- `--write` 只更新尚未被手工修改的已登记副本，或新增缺失文件。
- SDK 副本与上次登记哈希不符时拒绝覆盖，需维护者先审查合并。
- 多余文件只报告，不自动删除；不复制 sdkconfig、密钥或嵌入包。
- 公开 SDK 的 ESP 数据面目前只有裸 TCP/BLE 无 HMAC，不能对接强制 TLS+挑战应答的
  当前 Pi；LAN TLS/BLE 认证由正式 `esp/modules/smart-planter` 线推进，导出副本尚未带上。
- 固件顶层/main CMake 各有必要差异：正式工程使用仓库组件及外部包目录；SDK 示例
  使用自带 SDK 组件及构建脚本准备的包文件。它们不做逐字同步。

### `pi_module_api.h` 故意不同步

devkit 的 `sdk/include/pi_module_api.h` 是 **v3**（`PI_MODULE_API_VERSION=3`、
`platform_api=2`、要求 `data_schema`），仓库里的 `pi_terminal/src/modules/api/pi_module_api.h`
仍是 **v2**。最新终端软件在另一台机器上开发，等宿主迁到 v3 后再把这一对加回同步映射；
当前不要为了通过闸门把 devkit 的门槛降到 v2。

### mDNS 是可选特性

`esp/shared/module_data_service/` 和 devkit 的 `module_data_service` 都带
`module_data_mdns.c`，但 `CONFIG_MODULE_DATA_MDNS_ENABLED` 默认关闭。启用需要工程
通过 `idf_component.yml` 获取 `espressif/mdns`（或预置 managed_components）；本仓库
要保持离线可构建，所以默认走 BLE/手动连接，缺少组件不会编译失败。

## SDK 目录说明

- 根目录保留稳定 CLI 入口和 README，避免移动脚本破坏独立使用命令。
- `template/` 是最小完整工程：固件 + 主机插件 + QML 页面 + 组件 + 测试；
  `sdk/tests/qml_load_test.cpp` 是所有模块共用的离屏 QML 加载检查。
- `docs/` 集中开发流程及验收文档。
- `examples/smart-planter/tests/` 保存长期原生回归及 QML 布局预览，不复制测试产物。
- LCD 长期测试随固件放在 `examples/smart-planter/firmware/components/ui_env/tests/`；
  字体 C 数组、来源清单、Roboto 及 Noto 许可证完整保留。
- `artifacts/` 保留 v2 历史签名包，不能装到 v3 宿主；重新签名前不得分发。
- 分发 SDK 源码时排除 `artifacts/`、生成的嵌入包、构建目录、缓存和任何私有配置。
  LVGL 许可证必须保留。
