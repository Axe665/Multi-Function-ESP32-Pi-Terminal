# 文档索引

按“第一次上手 → 构建部署 → 运行与安全 → 性能 → 专项实现 → 开发记录”排序。
历史轮次记录在 [`devdocs/`](devdocs/)，不要按目录顺序当教程读。

## 1. 入门

| 文档 | 内容 |
|---|---|
| [../README.md](../README.md) | 项目定位、架构图、最小上手路径 |
| [project-code-map.md](project-code-map.md) | 代码结构总览（QML / 源码 / 目录职责） |
| [native-runtime-modules.md](native-runtime-modules.md) | 主程序与 `libterminal_*` 动态库的边界 |

## 2. 构建与部署

| 文档 | 内容 |
|---|---|
| [build-from-scratch.md](build-from-scratch.md) | 从零编译：依赖、Qt 6.4/6.5 两套、交叉工具链 |
| [DEPLOY.md](DEPLOY.md) | 部署引导（给下一台电脑的 AI / 运维） |
| [handover.md](handover.md) | **交接指南**：新机器从零到编译/部署/出 deb |
| [deb-packaging.md](deb-packaging.md) | DEB 打包：两个包、/opt 布局、构建与校验 |
| [known-issues.md](known-issues.md) | **已知问题与修复**：GLIBC、worker 路径、代理冲突、fake-IP |
| [changes-vs-main.md](changes-vs-main.md) | 相对 main 主线新增内容清单 |
| [archive/deployment-20261018.md](archive/deployment-20261018.md) | 当前 Pi 的部署与维护细节 |
| [../build_scripts/](../build_scripts/) | 构建/检查依赖/部署/验证/打包脚本 |
| [../toolchain/README.md](../toolchain/README.md) | Qt 6.5.3 aarch64 交叉 SDK（完整仓库） |
| [../sdk/README.md](../sdk/README.md) | ESP 固件完整仓库 |
| [../module-devkit/docs/ESP-TOOLCHAIN.md](../module-devkit/docs/ESP-TOOLCHAIN.md) | ESP-IDF 5.5.4 工具链安装与构建 |

## 3. 运行、安全与网络

| 文档 | 内容 |
|---|---|
| [networking.md](networking.md) | 联网权限：默认拒绝 + root 策略 + 代理 + nftables |
| [pbr-secure-v1/](pbr-secure-v1/) | PBR 串口控制面协议、向量、签认记录 |
| [../pi_terminal/packaging/](../pi_terminal/packaging/) | systemd 单元、polkit、egress 脚本 |

## 4. 性能与渲染

| 文档 | 内容 |
|---|---|
| [performance.md](performance.md) | **性能与优化总纲**：A53/LTO/PGO、启动与登录、测量方法、限制 |
| [blur-performance.md](blur-performance.md) | 模糊预缓存算法与实机数据 |
| [pi-ui-regression.md](pi-ui-regression.md) | UI 修复与无人值守截图回归（含 Qt 6.4 差异） |

## 5. 功能专项

| 文档 | 内容 |
|---|---|
| [native-music.md](native-music.md) · [music-playback-design.md](music-playback-design.md) | 音乐播放与队列 |
| [tv-hls-player-notes.md](tv-hls-player-notes.md) · [vlc-joystick.md](vlc-joystick.md) | 网络电视 / VLC / 摇杆 |
| [viper-browser-port.md](viper-browser-port.md) | Viper 浏览器内核集成 |
| [voice-tts.md](voice-tts.md) | 本地 flite 语音 |
| [weather.md](weather.md) | 天气 |
| [time-tools.md](time-tools.md) | 时钟/计时器/秒表/闹钟 |
| [arkpets-local.md](arkpets-local.md) | 桌宠彩蛋 |
| [enclosure-cad-merge.md](enclosure-cad-merge.md) | 外壳 CAD 与打印资料 |

## 6. 产品与资料

| 文档 | 内容 |
|---|---|
| [PRODUCT-MODULE-COMPOSITE-CASES.md](PRODUCT-MODULE-COMPOSITE-CASES.md) | 40 个产品选题 |
| [PARTS-LIST.md](PARTS-LIST.md) | 元件购买清单 |
| [../module-devkit/README.md](../module-devkit/README.md) | 模块 SDK 与模板 |
| [../hardware/enclosure/](../hardware/enclosure/) | STL / STEP / 3MF |

## 7. 开发记录

历史归档在 [`archive/`](archive/)（早期 P0 任务、MR 评审、旧部署快照）。

- [`devdocs/`](devdocs/)：按日期的轮次记录，含任务清单、评审意见、验证结论；
- 最近一轮：[`devdocs/51-pbr-ttl-and-egress-2026-11-07.md`](devdocs/51-pbr-ttl-and-egress-2026-11-07.md)。

> 约定：`devdocs/` 是**过程记录**，可能包含已被后续提交推翻的描述；事实以
> 代码、`docs/` 下专题文档和 `tests/` 为准。发现冲突时先改专题文档，再在
> devdocs 里补一条“已被 XX 取代”。
