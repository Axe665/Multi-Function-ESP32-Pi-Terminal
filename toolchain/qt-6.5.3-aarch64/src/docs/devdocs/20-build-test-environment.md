# 构建与测试环境清单（2026-11-01 本机实测）

> 目的：把本仓库**实际能构建、能跑测试**所需的依赖、版本、CMake 参数和已知失败条件写死，
> 避免“装完 Qt 就能编”“装完 libvlc 就能解码”这类误解。
>
> 本机不是树莓派实机：主机是 x86_64 Linux Mint 22.3（Ubuntu 24.04 基座），
> 目标 Pi 是 aarch64。
>
> **后续构建统一使用作者提供的 Qt SDK 6.5.3**，不再用系统 Qt 6.4.2 作为基准。
> 系统 Qt 6.4.2 的数据只保留为历史对照。SDK 路径：
> `$HOME/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64`。

## 1. 本机验证版本

| 组件 | 版本 / 说明 |
| :--- | :--- |
| 系统 | Linux Mint 22.3 (Zena)，x86_64 |
| 编译器 | GCC 13.3.0 |
| CMake | 3.28.3 |
| Ninja | 1.11.1 |
| Qt（后续标准） | **6.5.3，作者 SDK** `$HOME/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64` |
| Qt（历史对照） | 6.4.2（系统包；仅用于复现旧的 UI 崩溃，不再作为新构建基准） |
| SQLCipher | 4.5（本地解包；SQLite 3.44.2） |
| OpenSSL | 3.0.13 |
| mbedtls | 2.28.8（仅 `HostIdentity` 可选） |
| VLC | 3.0.20 + `vlc-plugin-base` |
| GStreamer | 1.24.2（系统运行库/插件；开发头来自 `third_party/gst/amd64`） |
| Python | 3.12.3（测试脚本） |
| Python 包 | `cryptography 41.0.7`、`Pillow 10.2.0` |
| Node.js / npm | 24.22.0 / 11.19.1 |
| Xvfb | 2:21.1.12-1ubuntu1.9 |

## 1.1 作者 Qt SDK（后续默认）

```sh
export OPI_SDK_HOME="$HOME/.local/share/orange-pi-terminal-sdk"
export OPI_QT_ROOT="$OPI_SDK_HOME/qt/6.5.3/gcc_64"
source pi_terminal/scripts/env.sh

"$OPI_QT_ROOT/bin/qmake" -query QT_VERSION   # 6.5.3
"$OPI_QT_ROOT/bin/qmake" -query QT_INSTALL_PREFIX
```

`pi_terminal/scripts/env.sh` 已把 `CMAKE_PREFIX_PATH`、`LD_LIBRARY_PATH`、`PATH`
指向这个 SDK；`build_terminal.sh` / `test_terminal.sh` 会自动 source 它。
如果 SDK 不在默认路径，设置 `OPI_QT_ROOT`，不要改脚本里的硬编码。
SDK 必须包含 WebEngine/WebEngineQuick、QuickControls2、Multimedia、TextToSpeech、
StateMachine、SerialPort、Bluetooth、ShaderTools；本机 SDK 已确认这些组件存在。

## 2. 必需的系统包

### 2.1 编译与 Qt

```sh
sudo apt install -y \
  build-essential cmake ninja-build pkg-config git \
  qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-webchannel-dev \
  qt6-webengine-dev qt6-connectivity-dev qt6-serialport-dev \
  qt6-multimedia-dev qt6-speech-dev
```

CMake 实际要求的 Qt 组件以 [`pi_terminal/CMakeLists.txt`](../../pi_terminal/CMakeLists.txt) 的
`find_package(Qt6 ... COMPONENTS ...)` 为准；只装 `qt6-base-dev` 不够。
`qt6-declarative-dev` 提供 Quick/QuickControls2/Qml；`qt6-quickcontrols2-dev` 不是本机包名。

### 2.2 加密

```sh
sudo apt install -y libssl-dev
```

SQLCipher 有两种接法：

1. 系统包：`sudo apt install -y libsqlcipher-dev`，CMake 自动找到；
2. 本机方式：`apt download libsqlcipher-dev` + `dpkg-deb -x` 到仓库外前缀，
   然后传 `-DSQLCIPHER_ROOT=/path/to/sqlcipher/usr`。

本机使用本地解包，**不要把 SQLCipher 的头文件/库 vendored 进 `third_party/`**。

mbedtls 只影响 `HostIdentity`（ECDSA P-256 签名/验签），不是全项目必需：

```sh
sudo apt install -y libmbedtls-dev   # 或本地解包后传 -DMBEDTLS_INCLUDE_DIR/-DMBEDTLS_CRYPTO_LIBRARY
```

没有 mbedtls 时 CMake 会跳过 `HostIdentity.cpp`，`pbr_host_identity` 测试会消失；
CI 必须显式断言它存在，不能把“缺依赖静默跳过”当成通过。

### 2.3 VLC（实测最容易漏的一项）

```sh
sudo apt install -y libvlc-dev vlc-plugin-base
```

**只装 `libvlc-dev` 能编译，但解码帧数为 0。** `libvlc-dev` 提供头文件/链接库，
`vlc-plugin-base` 才提供 demux/codec/access 等运行插件。本机最初只装了前者，
`media_vlc_functional/performance/interface` 全部卡在 `decodedFrames() == 0`；
安装 `vlc-plugin-base` 后三项立即通过。

检查运行插件目录非空：

```sh
ls /usr/lib/x86_64-linux-gnu/vlc/plugins
```

VLC 测试夹具由 `tests/run_media_browser_tests.py --generate-only` 生成，
不依赖 ffmpeg 或网络。

### 2.4 GStreamer

```sh
sudo apt install -y \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-tools
```

`third_party/gst/amd64` 是**开发头/链接入口**，不是运行插件。缺头时执行：

```sh
tools/fetch_gst_headers.sh
```

电视页使用 `souphttpsrc`、HLS 等插件；只装 GStreamer 核心不足以播放。

### 2.5 测试工具与 Python

```sh
sudo apt install -y xvfb xauth python3-pil python3-cryptography
```

本机 Python 为系统 `/usr/bin/python3` 3.12.3；CMake 测试必须用这个解释器：

```sh
-DPython3_EXECUTABLE=/usr/bin/python3
```

`cryptography` 用于 `signed_package_integration.py`（签名包安装/篡改拒绝）；
`Pillow` 用于 `arkpets_sprite_packing`。若用 pyenv/uv 的 Python，请单独安装这两个包，
不要假设系统包可见。

`Java` 不是测试必需项。`tools/arkpets/ExportSprites.java` 只在重新导出桌宠素材时需要 JDK；
当前 `pack_sprites_test.py` 用 Pillow 完成打包。

### 2.6 Node.js 与在线音乐

```sh
node --version   # 24.x
npm --version
npm ci --prefix pi_terminal/music_api
```

`pi_terminal/music_api/node_modules/` 不随源码树保证存在；没有执行 `npm ci` 时，
在线音乐 API 无法启动，但不会影响其余 ctest（音乐测试用本地 fake Node / 线程夹具）。
`music_api` 的上游依赖和可用性见 [`docs/native-music.md`](../native-music.md)。

### 2.7 运行期可选命令

| 命令 | 用途 | 缺失时 |
| :--- | :--- | :--- |
| `pactl` | 系统音量 | 音量页/播报降音不可用 |
| `udisksctl` | USB 挂载 | 可移动存储入口不可用 |
| `pkexec` + Polkit agent | 保存 root 联网策略 | 管理员无法保存策略；默认仍是全拒绝 |
| `polkitd`/`pkaction` | 校验 `.policy` | 只影响 root 策略写入 |

## 3. 本机实际 CMake 配置

本机 SQLCipher/OpenSSL/mbedtls 使用 `/tmp/pt-deps` 本地解包（不是仓库内容）：

```sh
SDK="$HOME/.local/share/orange-pi-terminal-sdk/qt/6.5.3/gcc_64"
source pi_terminal/scripts/env.sh
cmake -S pi_terminal -B /tmp/pt-build -G Ninja \
  -DCMAKE_PREFIX_PATH="$SDK" \
  -DBUILD_TESTING=ON \
  -DCMAKE_BUILD_TYPE=Debug \
  -DSQLCIPHER_ROOT=/tmp/pt-deps/sdk-sql/usr \
  -DOPENSSL_INCLUDE_DIR=/tmp/pt-deps/sdk-ssl/usr/include \
  -DOPENSSL_CRYPTO_LIBRARY=/usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
  -DOPENSSL_SSL_LIBRARY=/usr/lib/x86_64-linux-gnu/libssl.so.3 \
  -DMBEDTLS_INCLUDE_DIR=/tmp/pt-deps/sdk-mbed/usr/include \
  -DMBEDTLS_CRYPTO_LIBRARY=/usr/lib/x86_64-linux-gnu/libmbedcrypto.so.7 \
  -DPython3_EXECUTABLE=/usr/bin/python3

cmake --build /tmp/pt-build -j8
```

如果系统包齐全，可以删掉 `SQLCIPHER_ROOT`/`OPENSSL_*`/`MBEDTLS_*`，让 CMake 走系统查找。
`/tmp/pt-deps` 是本机私有路径，**不能写进产品安装脚本**。

运行测试时把作者 SDK 与本地解包库放进运行环境。`source scripts/env.sh` 已设置
SDK 的 `LD_LIBRARY_PATH`；再补 SQLCipher/mbedtls：

```sh
source pi_terminal/scripts/env.sh
export LD_LIBRARY_PATH=/tmp/pt-deps/sdk-sql/usr/lib/x86_64-linux-gnu:\
/tmp/pt-deps/sdk-mbed/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ctest --test-dir /tmp/pt-build-qt653 --output-on-failure -j4
```

`shared_runtime_install` 会自己把 `SQLCIPHER_LIB` 所在目录加进安装树的 `ldd` 环境；
不设 `LD_LIBRARY_PATH` 时手工跑该测试仍可能报 `libsqlcipher.so.1 => not found`。

## 4. root 策略/Polkit 环境

Phase 1 的联网权限需要：

```sh
# 安装前缀必须是应用实际运行时的前缀；本机为 /usr/local
cmake --install /tmp/pt-build --component TerminalRuntime

# Polkit 扫描目录（按发行版/前缀选择）
sudo install -Dm644 \
  /tmp/pt-build/com.orangepi.terminal.network-policy.policy \
  /usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy

pkaction --action-id com.orangepi.terminal.network-policy --verbose
```

安装后应存在：

- `/usr/local/libexec/orange-pi-terminal/net-policy-helper`（或对应前缀），root:root 0755；
- `/etc/orange-pi-terminal/network-policy.json`，root:root 0644；
- 策略缺失/损坏时应用和代理**默认全拒绝**。

root helper 自测：

```sh
sudo /usr/local/libexec/orange-pi-terminal/net-policy-helper --check < policy.json
sudo /usr/local/libexec/orange-pi-terminal/net-policy-helper \
  --policy /etc/orange-pi-terminal/network-policy.json < policy.json
```

`--check` 只校验，`--policy` 写入。非法 host（如 `https://evil`）必须返回非 0 且不覆盖旧文件。
真实 `pkexec` 需要 Polkit authentication agent；没有桌面会话的 SSH 环境无法完成交互认证，
只能用 `ORANGE_PI_NET_POLICY_HELPER` 直连 helper 做测试。

## 5. 测试基线（本机 2026-11-01）

```sh
ctest --test-dir /tmp/pt-build-qt653 --output-on-failure
```

结果（作者 SDK Qt 6.5.3，2026-11-01）：**67 项，67 通过，0 失败**。
两个多尺寸触控审计各 61 个布局用例、0 个错误；全量耗时约 343 秒
（UI 用例串行运行，各约 47 秒）。

| 测试 | 状态 | 说明 |
| :--- | :--- | :--- |
| `media_vlc_functional` / `performance` / `interface` | 通过 | 依赖 `vlc-plugin-base` |
| `shared_runtime_install` | 通过 | 依赖 SQLCipher `ldd` 路径；`--window-size` 延迟 resize |
| `pairing_ui_page` | 通过 | `UserSecurityPage` 已补 `SecurityStatusSection` |
| `signed_package_integration` | 通过 | 需要 Python `cryptography` |
| `arkpets_sprite_packing` | 通过 | 需要 Pillow；本机系统 Python 3.12 |
| `ui_responsive_touch` | 通过 | 61 个布局用例、0 错误 |
| `ui_highdpi_touch` | 通过 | `QT_SCALE_FACTOR=1.5`，同样 0 错误 |

系统 Qt 6.4.2 的历史结果是 67/65/2，两个 UI 测试会直接崩溃。
Qt 6.5.3 把崩溃变成可诊断的审计错误，修复过程从 281 个错误一路降到 0：

- `CarText`/`CarButton` 的显式 pixel 字号加 12px 下限，`AboutInfoRow` 改用
  `Theme.body`，消除小屏字号审计失败；
- UI 审计改用 `tests/run_ui_audit.py` 创建临时管理员并 `ORANGE_PI_AUTO_LOGIN`，
  不再停在登录页；浏览器地址栏保留 48dp 最小宽度，360dp 大字号下隐藏冗余“前往”按钮；
- 隐藏的 StackLayout 页面/弹窗只在真正可见或打开时构建：`UserSecurityView`、
  连接页、天气设置层用 Loader/尺寸下限，弹窗内容延迟到 `opened`，消除
  Qt 6.5 的 Popup `implicitHeight` 绑定循环和 ColumnLayout polish 循环；
- 修正 `activeBrowser`：不再依赖不可靠的 `StackLayout.currentItem`，按
  Repeater 的 `index` 找到当前标签；标签切换/增删时重建映射，触摸滚动和
  `target=_blank` 新标签因此落到正确的 WebEngineView；
- 触摸审计改为在浏览器打开后创建本地 `data:` 夹具，夹具加载期间临时启用
  浏览器通道（结束后恢复），并等待标签创建；任务栏动画改为轮询状态而不是
  固定 sleep，避免高 DPI/llvmpipe 下的时序抖动。

另外做了 1024×600 的人工图形走查，记录设置页/天气页隐藏布局、时间服务自绑定和电视台标请求等实际启动问题及修复：
[1024×600 人工走查](21-manual-test-2026-11-01.md)。

应用以 `--window-size 1024x600` / `1024x768` 单独启动可以作为冒烟证据，
但不能替代这两个多尺寸触控审计。没有删除测试、过滤警告或放宽
字号/触控热区断言来“变绿”。

作者 SDK 构建本身成功，`orange_pi_terminal`、全部测试二进制、`net-policy-helper`
和共享库均正常链接。

## 6. 硬件/固件边界

- 本机没有树莓派、桥板或 ESP32 模块；aarch64 交叉编译/实机未验证。
- `esp/` 不在本快照，桥板/模块固件行为未验证。
- BLE、LAN、PBR 的命令 AEAD/严格事件需要固件同步升级；不能用本机 ctest 证明实机通过。
- 没有 `pkexec` 交互会话时，root helper 只能通过 `sudo` 直接验证；策略页的真实保存需要
  桌面 Polkit agent。

## 7. 相关文档

- [Phase 1 记录](19-network-policy-phase1-2026-11-01.md)
- [联网与代理](../networking.md)
- [原生运行时依赖](../native-runtime-modules.md)
- [音乐 API](../native-music.md)
- [VLC 说明](../vlc-joystick.md)
- [电视内核说明](../tv-hls-player-notes.md)
