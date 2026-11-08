# Qt 6.5.3 for aarch64 — 构建、打包与部署

> **English:** Qt 6.5.3 with QtWebEngine, cross-compiled from source for aarch64 (arm64).
> Ships reproducible build scripts, a delivery packer, and a ready-to-install runtime (glibc 2.36+).
> Verified on Raspberry Pi 3B / Debian 12; runs on other arm64 boards with glibc ≥ 2.36.

![Qt 6.5.3](https://img.shields.io/badge/Qt-6.5.3-214c3d?style=flat-square&logo=qt&logoColor=white)
![aarch64](https://img.shields.io/badge/arch-aarch64%20%2F%20arm64-a07736?style=flat-square)
![glibc 2.36+](https://img.shields.io/badge/glibc-2.36%2B-214c3d?style=flat-square)
![verified](https://img.shields.io/badge/status-verified%20on%20hardware-214c3d?style=flat-square)

把 **Qt 6.5.3（含 QtWebEngine、Multimedia、TextToSpeech）** 从源码交叉编译到
**aarch64 / glibc 2.36+**，并交付三样东西：

1. **可复现的构建链** —— 配置、构建、安装、打包全部脚本化（`cross-build/`）；
2. **可直接安装的运行时包** —— 免构建，解压即用（`artifacts/`）；
3. **踩坑记录** —— 从宿主 glibc 混入到 Chromium 沙箱，每条都有定位过程（`docs/`）。

适用于 Raspberry Pi 3/4/5，以及其它满足 **glibc ≥ 2.36** 的 Debian 12 aarch64 板卡。
Pi 3B（1 GB RAM，1024×600）已实机验证，其余机型未逐项验证。

---

## 为什么自己编

- Qt 官方 `linux_arm64` 在线仓库没有 **6.5.3**，只有更新或更旧的版本；
- Debian 12 自带 Qt 6.4.2，与依赖 6.5.3 的项目二进制不兼容；
- 需要带 **QtWebEngine** 的完整运行时，且平台插件要能跑在目标板的 X11/EGL 上。

所以走源码交叉编译，并把整条链路固化成脚本：换一台宿主或换一块板卡时可以重来。

## 快速开始：安装预编译包（免构建）

`artifacts/` 里是已编好的交付包（258 MB，因 GitHub 单文件 100 MB 限制拆成 3 卷）：

| 文件 | 大小 |
| :--- | :--- |
| `artifacts/orpi-qt653-pi3.tar.zst.part00` | 90.0 MB |
| `artifacts/orpi-qt653-pi3.tar.zst.part01` | 90.0 MB |
| `artifacts/orpi-qt653-pi3.tar.zst.part02` | 77.7 MB |

> 文件名沿用历史命名（`orpi-qt653-pi3`），内容即 Qt 6.5.3 aarch64 运行时 + 示例项目产物。

合并并校验：

```bash
cd artifacts
cat orpi-qt653-pi3.tar.zst.part* > orpi-qt653-pi3.tar.zst
sha256sum orpi-qt653-pi3.tar.zst
# 74d1b6f1d479e04f536bbc487b495cf3f3979847f4d93ee99eadfa7b022b3e3c
```

在目标板（aarch64）上安装：

```bash
sudo tar -xf orpi-qt653-pi3.tar.zst -C /tmp
sudo bash /tmp/orpi-qt653-pi3/deploy-pi.sh
```

`deploy-pi.sh` 会把 Qt 装到 `/opt/qt653-arm64`、示例项目装到 `/usr`，并修好权限。
开机自启、全屏与沙箱配置见 [`deploy/README.md`](deploy/README.md)。

解压后 615 MB，包含：

- `opt/qt653-arm64/` —— Qt 6.5.3 aarch64 运行时（WebEngine、Multimedia、TextToSpeech，
  8 个平台插件 + xcb EGL 集成）
- `usr/` —— 示例项目产物（可执行、库、QML 预缓存、模块、语音资源）
- `部署说明.md`、`deploy-pi.sh`

## 快速开始：从源码构建

宿主：Ubuntu 24.04 x86_64（glibc 2.39）；目标 sysroot：Debian 12 aarch64（glibc 2.36）。
宿主依赖与 sysroot 准备见 [`cross-build/README.md`](cross-build/README.md)。

```bash
# 三件套解压到 dist/sdk/{qt653-arm64,host-qt,pi-sysroot}，或设置 ORPI_SDK_ROOT
./sdk/verify-sdk.sh                 # 先自检：缺哪项、怎么补，逐条打印
export ORPI_FLITE_ROOT=$(pwd)/build/flite   # 见下方"项目侧还需要一步"

./cross-build/build-qt653.sh        # 仅当没有现成 Qt 开发树时才需要（数小时）
./cross-build/build-project.sh      # 构建示例项目
./cross-build/make-deliverable.sh   # 产出 dist/orpi-qt653-pi3.tar.zst
```

### 没有交接盘：三件套怎么来

`artifacts/` 里只有**运行时**，编译还需要目标机 Qt 开发树、host Qt、Pi sysroot。
三者都不小，不进 git；用 [`sdk/`](sdk/README.md) 的脚本产出或校验：

```bash
./sdk/make-dev-sdk.sh /path/to/qt653-arm64     # include/lib/cmake/mkspecs → ~430 MB
./sdk/make-host-qt.sh                          # aqtinstall 拉 6.5.3 gcc_64 → ~290 MB
./sdk/make-sysroot.sh raspberrypi@<pi-ip>      # 从 Pi rsync 并清掉系统 Qt 6.4 → ~470 MB
./sdk/verify-sdk.sh                            # 11 项自检
```

**注意**：目标机 Debian 12 的 libstdc++ 是 GCC 12，必须用 `aarch64-linux-gnu-g++-12`；
用宿主默认 GCC 13 会缺 `std::ios_base_library_init`。`env.sh` 会自动选 12 并生成包装器。

## 仓库结构

```
├── sdk/                三件套产出与自检（dev 树 / host Qt / sysroot）
│   ├── verify-sdk.sh           11 项自检
│   ├── make-dev-sdk.sh         打目标机 Qt 开发树
│   ├── make-host-qt.sh         取/打 host Qt（moc 在 libexec/）
│   ├── make-sysroot.sh         从 Pi rsync sysroot 并清系统 Qt 6.4
│   └── build-flite.sh          预构建 flite（绕开 vendored 构建的引号 bug）
├── cross-build/         交叉编译链
│   ├── build-qt653.sh           Qt 6.5.3 配置 + 构建 + 安装
│   ├── build-project.sh         示例项目交叉编译
│   ├── make-deliverable.sh      生成交付包（分卷 + sha256）
│   ├── patch-qt-build.py        GLIBC 2.36 兼容补丁注入（幂等）
│   ├── isoc23_compat.c          __isoc23_* 符号兼容桩
│   ├── toolchain-pi653.cmake    CMake 工具链
│   └── env.sh                   环境变量
├── deploy/              目标板 systemd / 自启配置与一键安装脚本
├── docs/                部署说明、工作记录、问题与修复、Qt 源码改动
├── tools/pyshim/        Python 3.12 的 imp 垫片（Chromium 脚本需要）
├── src/                 附带示例项目（完整源码）
└── artifacts/           预编译交付包（分卷）
```

## 已验证

- 目标板：Pi 3B / Debian 12 / glibc 2.36 / 1024×600；
- 窗口全屏 `1024x600+0+0`，QML 预缓存 `STARTUP_READY cacheReady=true`；
- 所有 ELF 最高 GLIBC 需求 ≤ 2.35（示例项目二进制 2.34）；
- 开机自启（`systemctl --user` + XDG autostart），重启后 51 秒内主程序已运行；
- WebEngine Chromium 沙箱开启（无 `--no-sandbox`），systemd 沙箱属性全部生效。

## 附带示例项目

`src/` 是一个完整的模块化触屏终端项目（**Multi-Function ESP32 · Pi Terminal**），
作为本工具链的端到端验证样例：Qt/QML 桌面、模块 SDK、ESP32 控制桥与可打印外壳。
它用来证明「交叉编译产物在真实设备上跑得起来」，仓库主体仍是 Qt 构建与交付。

项目本身的介绍、模块体系与开发方式见 [`src/README.md`](src/README.md)。

## 关键坑

完整定位过程见 [`docs/问题与修复.md`](docs/问题与修复.md)。

1. 符号链接 + `..` 路径穿越 → 改用 **bind mount**；
2. 宿主 glibc 2.39 头/库优先 → **`__isoc23_*` 桩 + sysroot `-L`**，否则目标板报 `GLIBC_2.38 not found`；
3. sysroot 缺 xcb 开发文件 → `FEATURE_xcb=OFF`，需补包并单独构建 qtbase；
4. 旧 `libQt6Gui` 缺 `QX11Application` typeinfo → 用启用 xcb 的 Gui 替换（符号差集 0）；
5. 缺 `libqxcb-egl-integration.so` → OpenGL 上下文创建失败、窗口不显示。

## 文档索引

| 文档 | 内容 |
| :--- | :--- |
| [`cross-build/README.md`](cross-build/README.md) | 宿主依赖、sysroot、Qt 与项目的构建细节 |
| [`deploy/README.md`](deploy/README.md) | systemd 用户服务、全屏、自启 |
| [`docs/部署说明.md`](docs/部署说明.md) | 目标板安装、校验与安全配置 |
| [`docs/问题与修复.md`](docs/问题与修复.md) | 逐条踩坑记录 |
| [`docs/工作记录.md`](docs/工作记录.md) | 构建与实机验证时间线 |
| [`docs/QT-SOURCE-CHANGES.txt`](docs/QT-SOURCE-CHANGES.txt) | 对 Qt 源码的改动清单 |
| [`docs/PROJECT-PATCHES.txt`](docs/PROJECT-PATCHES.txt) | 对示例项目的改动清单 |

## 许可

`src/` 沿用原项目许可；本仓库新增的构建脚本与文档为 MIT。
`artifacts/` 内的二进制包由上述源码构建而来。
