# SDK来源

本基线复制本工作区 `publish/esp32-smart-planter/module-devkit/sdk/esp32/components/` 中的 board_pins、diagnostics、linkit_sdk，保留原文件注释；上游项目为 https://github.com/masbc666/Multi-Function-ESP32-Debugger 及本项目后续移植版本。

本地唯一SDK行为变更：linkit_core.c的模块类型映射增加0x51 ↔ XIAOTIAN，便于桥板日志辨认。UART/pogo握手时序和帧格式不变；应用安装配置明确禁用ESP-NOW，不接管Wi-Fi。

原工作区快照没有附这些SDK组件的独立许可证文件。本交付用于现有团队项目继续联调；对外分发或商业使用前由维护者核对上游授权，不在此自行声明许可证。
