# vlc-qt-backend

QML 面向的 libVLC 播放后端，供终端项目（pi_terminal）作为第三方库使用。

## 可移植性约定

- **任何平台都能编译**。CMake 先尝试 pkg-config 查找 `libvlc`；找不到时（
  Windows、macOS、无 libvlc 的 Linux）自动编译**桩实现**：QML 类型
  `VlcPlayer`/`VlcVideoOutput` 仍然注册，播放调用安全空转，设置媒体源时立即
  上报“运行库不可用”错误。宿主应用据此回退 Qt Multimedia。
- 构建期能力标记见 `include/vlc-qt-backend/VlcBackendInfo.h` 的
  `vlcBackendAvailable()`（编译定义为 `VLC_BACKEND_HAVE_LIBVLC` 时为 true）。

## 各平台安装 libvlc（启用真实后端时需要）

| 平台 | 安装方式 |
|---|---|
| Debian / Ubuntu / 树莓派 / 香橙派 | `sudo apt install libvlc-dev vlc` |
| Fedora / RHEL | `sudo dnf install libvlc-devel vlc` |
| Arch | `sudo pacman -S vlc` |
| macOS | `brew install vlc`（或指定 `LIBVLC_INCLUDE_DIR/LIBVLC_LIBRARY`） |
| Windows (MSVC/MinGW) | vcpkg `vcpkg install libvlc:x64-windows`，再传 `-DLIBVLC_INCLUDE_DIR=... -DLIBVLC_LIBRARY=...` |

手动覆盖（无需 pkg-config，适合交叉编译 sysroot）：

```sh
cmake -DLIBVLC_INCLUDE_DIR=/opt/sdk/include \
      -DLIBVLC_LIBRARY=/opt/sdk/lib/libvlc.so ...
```

## 目标与测试

- CMake 目标：`vlc-qt-backend::vlc-qt-backend`（STATIC）。
- 选项：`VLC_BACKEND_ENABLED`（默认 ON，关闭则强制桩实现）。
- 测试（`BUILD_TESTING=ON` 时注册到父工程 ctest）：
  - `vlc_player_function`：功能测试。设 `VLC_TEST_MEDIA=<本地媒体文件>` 可追加
    真实播放生命周期用例（需 libvlc 运行库）。
  - `vlc_player_performance`：性能测试，输出 `VLC_BENCH_*` 指标（720p 帧拷贝
    吞吐、present 延迟、事件分发、属性写入）。
- 页面级界面测试 `vlc_video_ui` 位于 pi_terminal/tests（依赖 QML 模块资源）。

## 结构

```text
include/vlc-qt-backend/  公开头文件（VlcPlayer / VlcVideoOutput / VlcBackendInfo）
src/                     实现（真实 libVLC 路径 + 桩路径，按编译定义切换）
tests/                   功能 / 性能测试
```

本目录代码为本项目原创，不含第三方源码；许可与项目主体一致。
