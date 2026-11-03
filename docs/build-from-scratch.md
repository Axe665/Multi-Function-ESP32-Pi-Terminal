# 从零编译（含依赖说明）

目标：**clone 下来就能编译**。能内置的依赖都已经放进仓库；只有体积太大或必须匹配系统的
（Qt、GStreamer、X11 开发包）需要你自己装，缺失时用一个脚本检查并给出命令。

## 1. 仓库里已经带了什么

| 目录 | 内容 | 需要安装吗 |
| --- | --- | --- |
| `third_party/vendor/deps/` | OpenSSL 3.0.13、mbedTLS、SQLCipher 的头文件与库 | **不需要** |
| `third_party/flite/`、`gst/`、`vlc/`、`Viper-Browser/`、`YesPlayMusic/`、`sqlite-amalgamation/` | 原作者已有的第三方源码 | **不需要** |
| `pi_terminal/assets/` | 界面资源、电视源、语音声库（`voices/`） | **不需要** |
| `pi_terminal/tts/` | flite 声库构建材料 | **不需要** |

`pi_terminal/CMakeLists.txt` 会自动把 `third_party/vendor/deps` 加进搜索路径——
OpenSSL、mbedTLS、SQLCipher 都在这里找到，**不用装 `libssl-dev` / `libsqlcipher-dev`**。

## 2. 需要自己准备什么

| 依赖 | 为什么不能内置 | 怎么来 |
| --- | --- | --- |
| **Qt 6.5.3**（最低 6.4） | 1.2 GB，且与系统图形栈绑定 | `scripts/bootstrap-deps.sh` 会给出安装命令 |
| **GStreamer 运行时** | 与系统多媒体栈绑定 | 同上 |
| **X11 / OpenGL 开发包** | 系统库 | 同上 |
| Node.js（可选，仅在线音乐） | 运行时可选 | 同上 |

### Qt 版本

| | 版本 | 出处 |
| --- | --- | --- |
| **验证版本**（作者 SDK） | **Qt 6.5.3 gcc_64** | `pi_terminal/CMakePresets.json`、`pi_terminal/scripts/env.sh` 默认都指向 `…/qt/6.5.3/gcc_64` |
| 最低要求 | Qt 6.4 | `pi_terminal/CMakeLists.txt` 的 `find_package(Qt6 6.4 …)` |
| 必需组件 | Quick、QuickControls2、WebEngine(Quick/Widgets/Core)、Multimedia、TextToSpeech、SerialPort、Bluetooth、ShaderTools、Test | 同上 |

低于 6.4 直接配置失败；6.4~6.5.2 理论上可用但**没有验证过**，
提交 PR 前请用 6.5.3 编译一遍，避免因为组件 API 差异出现只在老版本上的问题。

先跑检查：

```bash
./scripts/bootstrap-deps.sh
```

它会逐项报告 `[ok]` / `[缺]`，缺失项直接打印可复制的命令（apt / aqtinstall）。
脚本**只检查、不擅自改你的系统**。

## 3. 编译

```bash
# 如果 Qt 不在默认位置，先指过去（作者 SDK 默认在 ~/.local/share/orange-pi-terminal-sdk）
export CMAKE_PREFIX_PATH=/path/to/qt/6.5.3/gcc_64

cd pi_terminal
source scripts/env.sh              # 把 SDK 的 Qt 加进 PATH / CMAKE_PREFIX_PATH
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel 8
```

或者直接用作者脚本（等价）：

```bash
build_scripts/build_terminal.sh
```

产物：`pi_terminal/build/orange_pi_terminal`。

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
仓库里的 `third_party/vendor/deps` 没被找到。确认目录存在，并且是从
`pi_terminal/` 目录配置的（CMake 用 `${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vendor/deps`）。

**`SQLCipher not found`**
同上。项目刻意**不会**降级成普通 SQLite（T-10 要求加密），找不到就 FATAL_ERROR。

**`Qt6WebEngineQuick` 找不到**
Qt 安装时没勾 WebEngine 组件。用 aqtinstall 的话加 `-m qtwebengine`。

**运行时 `error while loading shared libraries: libsqlcipher.so.1`**
构建目录的 RPATH 通常已经指过去了；如果手动拷贝了二进制，记得
`export LD_LIBRARY_PATH=<repo>/third_party/vendor/deps/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH`。

**没有声音 / 中文播报没声**
需要 GStreamer 插件与 espeak-ng；语言页会显式报"语音引擎不可用"，不会静默失败。
