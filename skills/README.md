# skills 目录

本目录是**给下一台开发机上的 AI / 维护者**用的项目技能，不是通用教程。
每个技能一个子目录，入口是 `SKILL.md`，细项放 `references/`。

| 技能 | 适用场景 |
|---|---|
| [`esp32-pogo-debugger/`](esp32-pogo-debugger/SKILL.md) | 固件、PBR1/BLE/LAN 协议、Qt/QML 终端维护、UI 审计、模糊预缓存、媒体、部署与清理 |
| [`build-release/`](build-release/SKILL.md) | aarch64 交叉构建、RUNPATH、树莓派全量部署、沙箱/安全/联网三连证、测试套件、出 deb |
| [`deb-packaging/`](deb-packaging/SKILL.md) | 两个 deb 的拆分、/opt 布局、Qt 裁剪、lintian 与安装校验 |

## 本轮用到的通用技能（DSH 技能目录，不在本仓）

构建/性能类：`cmake`、`cross-gcc`、`gcc`、`linkers-lto`、`pgo`、`linux-perf`、
`hardware-counters`、`flamegraphs`、`heaptrack`、`valgrind`、`cpu-cache-opt`、
`memory-hierarchy-and-caches`、`branch-prediction-and-speculation`。

Qt/QML 类：`qt-cmake-project`、`qt-qml`、`qt-qml-review`、`qt-cpp-review`、
`qt-qml-profiler`、`qt-6-5-to-6-4-downgrade`。

工程类：`clean-code`、`refactoring-patterns`、`technical-writing`、
`documenting-legacy-codebases`、`working-with-legacy-code`。

需要时在 DSH 会话里显式加载；本仓只保留与项目强绑定的两个技能，避免把通用技能
正文复制进来造成版本漂移。
