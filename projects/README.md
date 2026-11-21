# projects：独立产品基线

这里的目录是**独立产品**，不是 `module-devkit` 的模块包，也不跟 `esp/modules/` 的模块固件共用加载链。

| 目录 | 产品 | 形态 | 说明 |
|---|---|---|---|
| `xiaotian-pogo/` | 啸天红外护栏 pogo | 独立 HTTPS 设备 | 固件 2.1 + Pi 面板 + USB/HTTPS 工具；module_id 81，走 `xiaotian_https_v2` |
| `native-browser-wheel/` | 原生 Qt/QML 网页方向轮盘 | 独立 UI 组件 | 与终端 Qt Quick/WebEngineView 架构一致的独立实现 |

模块与产品的权威索引见仓库根 [MODULES.md](../MODULES.md)。
