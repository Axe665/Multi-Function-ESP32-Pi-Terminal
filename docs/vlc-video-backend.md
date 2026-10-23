# VLC 视频播放后端（VideoPlayer → libVLC）

## 目标

把视频播放器后端从 Qt Multimedia 换成 VLC（libVLC），解决树莓派/香橙派上
Qt Multimedia 的解码能力与格式覆盖问题（MKV/HEVC/TS/网络流等）。页面 UI 与交互
保持不变。

## 结构：后端是 `third_party` 独立库

```
third_party/vlc-qt-backend/
  CMakeLists.txt                       pkg-config 探测 libvlc；无 libvlc 时编译桩实现
  include/vlc-qt-backend/              公开头（VlcPlayer / VlcVideoOutput / VlcBackendInfo）
  src/                                 实现（真实 libVLC 路径 + 桩路径，按编译定义切换）
  tests/                               功能 / 性能测试
  README.md / NOTICE.md
```

- `VlcPlayer`：libVLC 播放控制 QML 类型。事件（Playing/Paused/Stopped/EndReached/
  Error/Buffering/Length）全部经排队调用转回 GUI 线程；音频留在 libVLC 内；
  播放中每 200 ms 轮询进度与可 seek 状态。
- `VlcVideoOutput`：`QQuickPaintedItem`，vmem RV32 帧 PreserveAspectFit 呈现，
  OpenGL/软件渲染均可用；本身不依赖 libVLC。
- **可移植性**：任何开发平台都能编译。CMake 先走 pkg-config，找不到 libvlc
  （Windows/macOS/无 vlc 的 Linux）时自动编译**桩实现**——QML 类型照常注册，
  设置媒体源立即上报“运行库不可用”，`vlcBackendAvailable()` 返回 false，
  `VideoPlayer.qml` 的 Loader 选择 Qt Multimedia 回退。支持
  `LIBVLC_INCLUDE_DIR`/`LIBVLC_LIBRARY` 手动覆盖（vcpkg/交叉 sysroot），
  详见 `third_party/vlc-qt-backend/README.md`。

```
VideoPlayer.qml
  └─ Loader (id: mediaBackend, 依据 vlcBackendAvailable 选择)
       ├─ VideoBackendVlc.qml         ← libvlc 可用时
       └─ VideoBackendMultimedia.qml  ← 回退，与原实现逐字等价
```

`VideoBackendVlc.qml` 保留名为 `videoAudioOutput` 的镜像对象，使
DiagnosticRunner 的播报恢复审计与旧后端表现一致。

## 构建

```sh
# 依赖（启用真实后端时需要；不装也能编译，自动退化为桩）
sudo apt install libvlc-dev vlc

source pi_terminal/scripts/env.sh
cmake -S pi_terminal -B /tmp/opencode/terminal-vlc-dev \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build /tmp/opencode/terminal-vlc-dev --parallel 4
```

## 测试（功能 / 界面 / 性能）

一键入口（构建 + 运行三层测试并输出汇总）：

```sh
pi_terminal/tests/run_vlc_tests.sh                 # 功能 + 性能 + 界面
pi_terminal/tests/run_vlc_tests.sh --benchmark     # 仅性能层，打印 VLC_BENCH_* 指标
VLC_TEST_MEDIA=/path/to/movie.mp4 \
  pi_terminal/tests/run_vlc_tests.sh               # 追加真实播放生命周期用例
```

| 层 | 测试 | 覆盖内容 |
|---|---|---|
| 功能 | `vlc_player_function` | 属性默认值、音量/静音/进度写读、stop 复位、缺失文件必报错（桩模式同步报错）、`VLC_TEST_MEDIA` 真实播放→暂停→继续→停止生命周期 |
| 性能 | `vlc_player_performance` | 720p RV32 帧拷贝吞吐（>80 MB/s 下限）、present() 延迟（<3 ms/帧）、事件分发（<0.5 ms/事件）、属性写入吞吐，输出 `VLC_BENCH_*` |
| 界面 | `vlc_video_ui` | 后端组件 QML 表面（视频输出 + audioOutput 镜像绑定传播）；VideoPlayer Loader 按 `vlcBackendAvailable` 正确选择 VLC / 多媒体后端；页面契约（hasMedia/mediaPosition/videoFileList）不变 |

## 实机验证清单（按仓库规则，交叉编译到设备后执行）

1. `sudo apt install libvlc-dev vlc`，确认 `ldconfig -p | grep libvlc`。
2. 跑 `pi_terminal/tests/run_vlc_tests.sh`，三层全绿；记录 `VLC_BENCH_*` 指标。
3. 依次播放并全屏：H.264 MP4、MKV、TS、HEVC 1080p；检查音画同步。
4. 拖动进度条 seek；暂停/继续/停止；播完一段后重新播放。
5. 播放中触发语音播报：音量降至 20% 并恢复（`duckMediaForSpeech` 审计项）。
6. 打开不存在的文件：显示 `playbackError`，不崩溃。
7. 长时播放（≥30 分钟）观察内存（vmem 拷帧路径每帧分配 QImage，若实机增长
   明显再改为复用缓冲）。

## 性能备注

RV32 vmem 路径由 libVLC 做 YUV→RGB 转换（CPU），1080p 高码率在低端板卡上
可能出现掉帧。QML 无原生窗口句柄，不能用 `set_hwnd` 类直连渲染；如卡顿，
优化方向是把 `VlcVideoOutput` 的绘制改为纹理上传路径，先以实机
`VLC_BENCH_*` 数据为准。
