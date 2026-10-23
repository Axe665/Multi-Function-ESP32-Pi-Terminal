# VLC 视频播放后端（VideoPlayer → libVLC）

## 目标

把视频播放器后端从 Qt Multimedia 换成 VLC（libVLC），解决树莓派/香橙派上
Qt Multimedia 的解码能力与格式覆盖问题（MKV/HEVC/TS/网络流等）。页面 UI 与交互
保持不变。

## 架构

```
VideoPlayer.qml
  └─ Loader (id: mediaBackend)
       ├─ VideoBackendVlc.qml         ← libvlc 可用时（默认）
       └─ VideoBackendMultimedia.qml  ← 回退，行为与原实现逐字等价
```

- `src/ui/VlcPlayer.{h,cpp}`：libVLC 播放控制 QObject（QML 类型 `VlcPlayer`）。
  属性面与旧 MediaPlayer 用法对齐：`source/position/duration/playing/buffering/
  loading/seekable/volume(0..1)/muted/errorString`，方法 `play/pause/stop`。
- `src/ui/VlcVideoOutput.{h,cpp}`：`QQuickPaintedItem`（QML 类型
  `VlcVideoOutput`），以 PreserveAspectFit 绘制最新一帧，OpenGL/software 渲染
  后端均可工作。
- 视频帧走 libVLC **vmem 回调**（chroma `RV32`，与 `QImage::Format_RGB32`
  内存布局一致），在 libVLC 视频线程里拷帧，再经排队调用投递到 GUI 线程。
- 音频留在 libVLC 内部（ALSA/PulseAudio），`setVolume/setMuted` 映射为
  `libvlc_audio_set_volume/set_mute`。播报压低音量的 `announcementGain` 绑定不变。
- libVLC 事件（Playing/Paused/Stopped/EndReached/EncounteredError/Buffering/
  LengthChanged）一律经排队调用转回 GUI 线程；播放中每 200 ms 轮询
  `get_time/is_seekable` 刷新进度条。
- `VideoBackendVlc.qml` 里保留名为 `videoAudioOutput` 的镜像对象，使
  DiagnosticRunner 的播报恢复审计与旧后端表现一致。

## 构建

```sh
# 依赖（构建机与目标机都装）
sudo apt install libvlc-dev vlc

source pi_terminal/scripts/env.sh
cmake -S pi_terminal -B /tmp/opencode/terminal-vlc-dev \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build /tmp/opencode/terminal-vlc-dev --parallel 4
ctest --test-dir /tmp/opencode/terminal-vlc-dev -R "vlc_player_smoke|browser_joystick_cursor"
```

- CMake 选项 `TERMINAL_VLC_BACKEND`（默认 ON）：pkg-config 找不到 libvlc 时
  自动回退 Qt Multimedia，并置 QML 上下文属性 `vlcBackendAvailable=false`，
  `VideoPlayer` 的 Loader 因此选择多媒体后端，无需改任何 QML。
- 新测试 `vlc_player_smoke`（offscreen）：属性默认值、缺失文件必须上报错误、
  QML 类型注册可用。libvlc 运行库缺失时优雅跳过。

## 实机验证清单（按仓库规则，交叉编译到设备后执行）

1. `apt install vlc` 确认目标机存在 libvlc（`ldconfig -p | grep libvlc`）。
2. 编译产物部署后运行：`vlcBackendAvailable` 应为 true（日志/`--demo` 验证）。
3. 依次播放并全屏：H.264 MP4、MKV、TS 流、HEVC 1080p；检查音画同步。
4. 拖动进度条 seek；暂停/继续/停止；上一段结束后重新播放。
5. 播放中触发语音播报：音量降至 20% 并恢复（`duckMediaForSpeech` 审计项）。
6. 打开不存在的文件：显示 `playbackError`，不崩溃。
7. 长时播放（≥30 分钟）确认无内存增长（拷帧路径每次分配 QImage，需在实机
   观察；若有必要可改为帧缓冲复用）。

## 性能备注

RV32 vmem 路径由 libVLC 做 YUV→RGB 转换（CPU），1080p 高码率在低端板卡上
可能出现掉帧。若实机验证发现卡顿，优先尝试：
`libvlc_media_player_set_hwnd` 之外的路由不可行（QML 无原生窗口句柄），因此
优化方向是（1）降低 vmem 输出帧率需求（libVLC 会按播放速率送帧，无需改）；
（2）把 `VlcVideoOutput` 的绘制改为纹理上传路径。先以实机数据为准。
