# 从零编译（含依赖说明）

目标：**clone 下来就能编译**。能内置的依赖都已经放进仓库；只有体积太大或必须匹配系统的
（Qt、GStreamer、X11 开发包）需要你自己装，缺失时用一个脚本检查并给出命令。

## 1. 仓库里已经带了什么

| 目录 | 内容 | 需要安装吗 |
| --- | --- | --- |
| `third_party/deps/` | OpenSSL 3.0.13、mbedTLS、SQLCipher 的头文件与库 | **不需要** |
| `third_party/flite/`、`gst/`、`vlc/`、`Viper-Browser/`、`YesPlayMusic/`、`sqlite-amalgamation/` | 第三方源码；`gst/<arch>/plugins/` 已带运行期插件 | **不需要** |
| `sdk/qt-6.5.3-aarch64/` | Qt 6.5.3 aarch64 交叉 SDK 完整仓库（含 artifacts/sysroot） | **不需要**（交叉编译用） |
| `sdk/esp-firmware/` | ESP 固件完整仓库 | **不需要**（固件用） |
| `pi_terminal/assets/` | 界面资源、电视源、语音声库（`voices/`） | **不需要** |
| `pi_terminal/tts/` | flite 声库构建材料 | **不需要** |

`pi_terminal/CMakeLists.txt` 会自动把 `third_party/deps` 加进搜索路径——
OpenSSL、mbedTLS、SQLCipher 都在这里找到，**不用装 `libssl-dev` / `libsqlcipher-dev`**。

## 2. 需要自己准备什么

| 依赖 | 为什么不能内置 | 怎么来 |
| --- | --- | --- |
| **Qt 6.4.2**（目标机基线；开发可用 6.5.3；最低 6.4） | 与系统图形栈绑定，官方 SDK 约 1.2 GB | 发行版系统包，或 `build_scripts/check_deps.sh` 给出的 aqtinstall 命令 |
| **GStreamer 运行时** | 与系统多媒体栈绑定 | 同上 |
| **X11 / OpenGL 开发包** | 系统库 | 同上 |
| Node.js（可选，仅在线音乐） | 运行时可选 | 同上 |
| `nft` / `python3` / `espeak-ng` | 功能级依赖：网络策略兜底 / 宠物库 / 语音播报 | 同上（`build_scripts/check_deps.sh` 会逐项检查） |

### Qt 版本

| | 版本 | 出处 |
| --- | --- | --- |
| **目标机基线** | **Qt 6.4.2**（Debian 12 / Ubuntu 24.04 系统包） | `pi_terminal/CMakePresets.json` 的 `linux-qt642` |
| **开发机可用** | **Qt 6.5.3 gcc_64**（作者 SDK） | `linux-qt653` preset、`pi_terminal/scripts/env.sh` 的默认回退 |
| 最低要求 | Qt 6.4 | `pi_terminal/CMakeLists.txt` 的 `find_package(Qt6 6.4 …)` |
| 必需组件 | Quick、QuickControls2、WebEngine(Quick/Widgets/Core)、Multimedia、TextToSpeech、SerialPort、Bluetooth、ShaderTools、Test | 同上 |

低于 6.4 直接配置失败。6.4.2 是目标机基线，`linux-qt642` preset 与 CI 约定都以它为准；
6.5.3 是开发机的可选加速路径，两条路径必须都能编过。

`QtQuickTemplates2` 的私有头（`QQuickTheme`）是可选的：官方安装器自带，Debian/Ubuntu 需要
`qt6-declarative-private-dev`。缺失时主程序退化为仅 `QGuiApplication::setFont()`，构建与运行都不受影响。

先跑检查：

```bash
./build_scripts/check_deps.sh
```

它会逐项报告 `[ok]` / `[缺]`，缺失项直接打印可复制的命令（apt / aqtinstall）。
脚本**只检查、不擅自改你的系统**。

## 3. 编译

```bash
# 如果 Qt 不在默认位置，先指过去（作者 SDK 默认在 ~/.local/share/orange-pi-terminal-sdk）
export CMAKE_PREFIX_PATH=/path/to/qt/6.5.3/gcc_64

cd pi_terminal
source scripts/env.sh              # 把 SDK 的 Qt 加进 PATH / CMAKE_PREFIX_PATH
cmake --preset linux-qt653         # 或 linux-qt642（系统 Qt 6.4.2 基线）
cmake --build --preset linux-qt653 --parallel 8
```

### 交叉编译到 Pi（使用仓库内 SDK，免下载）

```bash
# sdk/qt-6.5.3-aarch64 里带 sysroot 与 Qt 运行库
export ORPI_SYSROOT=$PWD/../sdk/qt-6.5.3-aarch64/sysroot
export ORPI_QT_PREFIX=$PWD/../sdk/qt-6.5.3-aarch64/qt653-arm64
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64        # 只用于 moc/qmlcachegen

cd pi_terminal
cmake --preset aarch64-cross        # A53；aarch64-lto / aarch64-pgo-* 同理
cmake --build --preset aarch64-cross --parallel 8
```

或者直接用作者脚本（等价）：

```bash
build_scripts/build_terminal.sh
```

产物：`pi_terminal/build/orange_pi_terminal`。

> **只编主程序会“登录卡死”**：`orange_pi_terminal` 还依赖两个配套可执行文件
> `terminal_kdf_worker`（PBKDF2 子进程）和 `network_proxy`（本地代理）。只执行
> `cmake --build build --target orange_pi_terminal` 时它们不会被编出来，表现为：
>
> - 日志 `kdf-worker: unavailable, login will block on the main thread`；
>   点登录后在主线程同步跑 600k PBKDF2（Qt 纯 C++ 实现，比 OpenSSL 慢很多），
>   桌面机也会冻结数秒到十几秒，之后才进桌面，看起来就是“输密码卡死”；
> - 日志 `net-proxy: ... missing, every outbound request will fail`，联网模块全挂。
>
> 正确做法：`cmake --build build --parallel 8`（不带 `--target`，编全部目标），
> 或直接用 `build_scripts/build_terminal.sh`。手动拷贝时至少带上
> `orange_pi_terminal`、`terminal_kdf_worker`、`network_proxy` 三个可执行文件，
> 并在同目录或 `$PATH` 可见。

## 4. 运行

```bash
./build/orange_pi_terminal --window-size 1024x600
```

首次运行没有管理员会进入开机向导；也可以直接建一个：

```bash
echo "你的6位PIN" | ./build/orange_pi_terminal --init-admin "验收员" --init-pin-stdin
```

## 5. 常见问题

**`Could NOT find OpenSSL`**
仓库里的 `third_party/deps` 没被找到。确认目录存在，并且是从
`pi_terminal/` 目录配置的（CMake 用 `${CMAKE_CURRENT_SOURCE_DIR}/../third_party/deps`）。

**`SQLCipher not found`**
同上。项目刻意**不会**降级成普通 SQLite（T-10 要求加密），找不到就 FATAL_ERROR。

**`Qt6WebEngineQuick` 找不到**
Qt 安装时没勾 WebEngine 组件。用 aqtinstall 的话加 `-m qtwebengine`。

**运行时 `error while loading shared libraries: libsqlcipher.so.1`**
构建目录的 RPATH 通常已经指过去了；如果手动拷贝了二进制，记得
`export LD_LIBRARY_PATH=<repo>/third_party/deps/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH`。

**没有声音 / 中文播报没声**
需要 GStreamer 插件与 espeak-ng；语言页会显式报"语音引擎不可用"，不会静默失败。
