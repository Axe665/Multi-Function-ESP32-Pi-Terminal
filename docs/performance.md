# 性能与优化总纲（Pi 3B / AArch64 / Qt 6.5.3）

本文把散落在构建脚本、提交记录和实机验证里的性能工作收敛到一处，作为后续优化的
基线。分四层：**目标硬件 → 构建级优化 → 运行时优化 → 测量与台账**。渲染/模糊的
细节算法另见 [blur-performance.md](blur-performance.md)，供电对性能的影响见
[POWER-DIAGNOSIS.md](POWER-DIAGNOSIS.md)（在交接文档里，未随主仓发布）。

## 1. 目标硬件与基线

| 项 | 值 |
|---|---|
| SoC | Broadcom BCM2837（Pi 3B），4×Cortex-A53，**顺序执行、无 SMT、1.2 GHz** |
| 缓存 | L1 32 KB I/D per core，L2 512 KB 共享 |
| GPU | VideoCore IV V3D 2.1（Mesa 24.x，OpenGL ES 2.0） |
| 内存 | 1 GB，无 swap 时更依赖页缓存 |
| 存储 | microSD，随机 IOPS 低，**写放大敏感** |
| 系统 | Debian 12 aarch64，glibc 2.36，Qt 6.5.3（`/opt/qt653-arm64`） |

顺序小核的关键含义：**没有乱序窗口帮你掩盖 cache miss 和长依赖**。优化优先级是
“少做无用功”（减少分配、拷贝、重复解码、日志 I/O）而不是“提高 ILP”。这也是本
项目绝大多数优化都在 I/O 与启动路径上的原因。

基线指标（Qt 6.5.3 / PGO 构建 / 实机）：

| 指标 | 基线 | 说明 |
|---|---|---|
| 启动到 `STARTUP_READY` | 约 55–65 s | 含 QML 场景、字体、语音词典加载 |
| 登录（PBKDF2 600k，同步） | 8.6 s | 主线程阻塞 |
| 登录（KDF 子进程，异步） | **6.75 s** | 界面全程可响应，见 §3.2 |
| 主程序体积 | 1.88 MB → LTO 1.57 MB → PGO 1.40 MB | aarch64 Release |
| 启动页首帧 | 黑屏 → 立即显示 | 由 QSplashScreen/BootConsole 消除 |

## 2. 构建级优化

### 2.1 目标 CPU

`pi_terminal/CMakeLists.txt` 对 aarch64 默认加：

```
-mcpu=cortex-a53 -fno-semantic-interposition
```

- `-mcpu=cortex-a53`：让 GCC 用 A53 的调度模型与 NEON 能力，不要用 `-march=native`
  （交叉编译时 native 指构建机，产物可能含 A53 不支持的指令）；
- `-fno-semantic-interposition`：允许共享库内部跨 TU 内联/去虚化，Qt/本项目这种
  “库内调用远多于库外覆盖”的场景收益明显；
- CPU 已参数化：`-DORPI_TARGET_CPU=cortex-a72`（Pi 4）/ `cortex-a76`（Pi 5）。

### 2.2 LTO

```sh
cmake --preset aarch64-lto        # 等价于 -DORPI_ENABLE_LTO=ON
```

注意交叉工具链要用 `aarch64-linux-gnu-gcc-ar` / `-gcc-ranlib`，否则 LTO 对象
无法归档：

```
-DCMAKE_AR=/usr/bin/aarch64-linux-gnu-gcc-ar
-DCMAKE_RANLIB=/usr/bin/aarch64-linux-gnu-gcc-ranlib
```

体积收益：1.88 MB → **1.57 MB**。LTO 也会让跨库内联生效，但**不要**和
`-fno-semantic-interposition` 冲突地再加 `-fPIC` 相关覆盖。

### 2.3 PGO（两阶段）

```sh
# 阶段 1：采集
cmake --preset aarch64-pgo-generate     # -fprofile-generate=/tmp/orpi-pgo
cmake --build --preset aarch64-pgo-generate

# 设备上跑真实负载，然后 SIGTERM（不要 --quit-after，实测不落盘）
sudo mkdir -p /tmp/orpi-pgo && sudo chmod 777 /tmp/orpi-pgo
ORANGE_PI_... /usr/bin/orange_pi_terminal --config ... --demo
kill -TERM <pid>          # main.cpp 的 SIGTERM handler → quit → __gcov_dump()

# 阶段 2：使用（同一 build 目录，保证 gcda 路径匹配）
cmake --preset aarch64-pgo-use          # -fprofile-use=/tmp/orpi-pgo -fprofile-correction + LTO
cmake --build --preset aarch64-pgo-use
```

体积收益：1.57 MB → **1.40 MB**；启动路径的分支预测也更稳。

踩过的坑：

- `/tmp/orpi-pgo` 必须**先建好且可写**，否则 gcov 静默丢弃 profile；
- instrumented 版 `--quit-after` 不触发退出钩子，必须用 SIGTERM/SIGINT；
- 阶段 2 必须复用阶段 1 的 build 目录，否则 `.gcda` 路径对不上，GCC 会报
  `profile data may be out of date` 并退化为普通构建。

### 2.4 构建产物与 RUNPATH

交叉产物部署前必须改 RUNPATH，否则到 Pi 上会解析到系统 Qt 6.4：

```sh
patchelf --set-rpath '$ORIGIN/../lib/orange-pi-terminal:/opt/qt653-arm64/lib' orange_pi_terminal
patchelf --set-rpath '$ORIGIN:/opt/qt653-arm64/lib' lib/orange-pi-terminal/libterminal_*.so.1.0
patchelf --set-rpath '$ORIGIN/../../lib/orange-pi-terminal:/opt/qt653-arm64/lib' \
    /usr/libexec/orange-pi-terminal/module_worker
```

漏掉任一共享库都会出现 `symbol lookup error ... Qt_6_PRIVATE_API`（两套 Qt 混载）。

## 3. 运行时优化

原则：**不改渲染路径、不改动画时长**，只去掉启动与交互里的同步阻塞和重复工作。

### 3.1 启动路径

| 优化 | 做法 | 效果 |
|---|---|---|
| 启动遮罩 | 纯 C++ `BootConsole`（QML 加载前显示），按真实耗时刷日志行 | 消除黑屏；失败可见 |
| 音频枚举延后 | `QMediaDevices` 延迟 2.5 s 到首帧后 | 启动少一次 GStreamer 枚举阻塞 |
| 设置页异步 | `settingsPageLoader.asynchronous: true` | 打开设置不再卡主线程 |
| 语音词典 | 按需加载，不阻塞首帧 | 启动路径缩短 |

### 3.2 登录（KDF 子进程）

PBKDF2-HMAC-SHA256 600k 在 A53 上约 6–9 s。原实现同步跑在主线程，登录期间 UI 冻结。

改造后：

- `terminal_kdf_worker` 子进程只做 KDF，主进程通过 `KdfClient`（QProcess + 长度前缀
  协议）通信；
- `SessionGate` 走 `loginWithWorker` / `unlockWithWorker`，忙碌态由
  `loginFinished` / `unlockFinished` 统一清除；
- worker 不可用时**自动回退同步路径**，安全强度不变；
- 实测：同步 8.6 s（阻塞）→ 异步 **6.75 s**（界面可响应）。

注意：自动登录钩子若在初始化阶段发起，回调会被 WebEngine 初始化拖到 17 s 量级；
测试/无人值守场景要延迟到事件循环稳定后再发（`ORANGE_PI_LOGIN_ASYNC=1` 已内置 3 s 延迟）。

### 3.3 I/O 与存储

| 优化 | 做法 | 效果 |
|---|---|---|
| 日志节流 | GstVideoItem 统计从每 8 ms 一条改为约 5 s 一条 | 播放时日志 I/O 降两个数量级 |
| QSettings 合并 | 拼音选词 300 ms 合并落盘 | 高频输入不再每选一次写 SD |
| systemctl 等待 | FileApiBroker 3 s→0.8 s、就绪轮询 20→8；NetworkPolicy helper 60 s→8 s | 打开文件管理器/切权限不再卡秒级 |

### 3.4 内存与拷贝

- `pinyinCandidates` 去掉每音节整表拷贝，直接引用 phrase/character 索引表（顺序核上
  减少分配与内存流量）；
- AppNetworkBroker 响应缓冲改 `QSharedPointer`，修 reply 提前销毁的潜在泄漏；
- 模块包走内容寻址缓存，同一模块重复安装不重复解包。

## 4. 渲染与模糊

`BlurItem` 仍是唯一模糊算法，`BlurCache.qml` 预渲染窗口/快捷面板背景到有界 GPU 槽，
`CachedBlur.qml` 用烘焙 shader 做局部裁切。关键收益（2026-10-18 实机，Qt 6.4.2）：

| 指标 | 优化前 | 预缓存后 |
|---|---|---|
| 最大化期间模糊 FBO 新建 | 每次 24–43 | 0 |
| 展开面板期间 FBO 新建 | 每次 49–134 | 0 |
| 普通模式展开首帧 | 1592–1757 ms | 362–383 ms |
| 展开动作采样 FPS | 0–0.9 | 9.1–11.7 |

这些是**受控交互窗口**的采样，不是整机长期 FPS；低帧率样本保留在
[blur-performance.md](blur-performance.md) 中，不宣称已稳定 60 FPS。

## 5. ARM64 顺序小核的编译要求（清单）

1. 用 `-mcpu=cortex-a53`（或目标核），**禁用** `-march=native`；
2. 交叉工具链的 GCC 版本必须与 sysroot 的 libstdc++ 匹配（本项目用 GCC 12；用 13
   会缺 `std::ios_base_library_init`）；
3. 共享库加 `-fno-semantic-interposition`，配合 LTO 才有跨库内联收益；
4. 不要用 `-ffast-math` 处理音频/加密路径；
5. NEON 由 `-mcpu` 自动开启，手写 intrinsics 前先看 `-fopt-info-vec`；
6. 结构体对齐到 8/16 字节，避免 A53 上的非对齐访问惩罚；
7. 热点循环优先减少分支与内存流量（顺序核没有乱序窗口掩盖延迟）；
8. 发布构建统一走 LTO/PGO preset，避免“我本地是 -O3”的偏差。

## 6. 测量方法

```sh
# 供电/降频（跑性能前先确认）
vcgencmd get_throttled          # 0x0 才可信
vcgencmd measure_clock arm

# 启动与登录耗时（程序自带）
grep -aE 'STARTUP_READY|login completed|async login' terminal-service.log

# CPU 热点
perf stat -e cycles,instructions,cache-misses,branch-misses ./orange_pi_terminal --demo
perf record -g ./orange_pi_terminal --demo && perf report --stdio | head -40

# 模糊/渲染回归（唯一截图入口）
python3 pi_terminal/tests/screenshot_regression.py BINARY OUT --only blur-performance
```

## 7. 已知限制

- **供电**是当前第一瓶颈：`throttled=0x50005` 时 A53 会降频，任何代码优化都会被
  抵消；测试/采集性能数据前先换 5 V/3 A 电源。
- GPU 是 VC4，模糊走预缓存而非实时；4K/高 DPI 场景不在目标范围。
- GStreamer 插件不全会让音乐/电视解码失败（`no element playbin`），这不是性能问题，
  按 [third_party/gst/README.md](../third_party/gst/README.md) 补齐。
- 顺序核上继续做微优化的边际收益已经很低，下一步应优先解决供电与插件完整性。
