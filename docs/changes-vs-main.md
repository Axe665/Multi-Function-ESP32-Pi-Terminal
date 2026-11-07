# 相对 main 主线新增了什么（2026-11-07）

基线：`origin/main` @ `86152fc`（2026-10-29）。本分支把 10-30 ～ 11-07 的进度补齐，
并做了仓库整理。按“用户可感知 → 工程”排序。

## 1. 登录与启动

- 登录改为 **KDF 子进程 + 异步**（同步 8.6 s 阻塞 → 异步 6.75 s，界面可响应），
  worker 缺失时自动回退。
- 启动页改为 **终端日志滚动**（真实耗时、闪烁光标），消除黑屏。
- 新增 `ORANGE_PI_LOGIN_ASYNC=1` 自动登录钩子（延迟 3 s 到事件循环稳定）。

## 2. 协议与模块

- PBR 控制面：TTL 增加 `kMaxSkewMs=2000` 负偏差容差（修复握手单向时延导致的
  `EVENT_EXPIRED`）；`boot_id` 变化触发重握手；拒绝时打印 ttl/offset/age。
- `--demo` attach 补齐 `p0-control-v1` 字段；模块 API 升到 **v2**。
- 新增 `ORANGE_PI_WORKER_FORCE_DEGRADED` 测试钩子。

## 3. 联网与安全

- egress 规则改绑 `app.slice` level 4（原绑 unit，重启即失效）。
- 代理策略 drop-in 用八进制转义（`printf %s` 被 systemd 展开成 `/bin/bash` 的坑）。
- 新增 polkit 规则 `50-orpi-worker.rules`，允许本地会话用户启停 worker 单元。
- file-daemon 改回按需启动（开机自启必失败）。

## 4. 构建与打包

- 新增 aarch64 preset：`aarch64-cross` / `aarch64-lto` / `aarch64-pgo-generate` /
  `aarch64-pgo-use`；`-mcpu` 参数化（`ORPI_TARGET_CPU`）。
- 仓库内 `pi_terminal/cmake/toolchain-aarch64.cmake`（只读环境变量）。
- 交叉链接固定 sysroot（修复 GLIBC_2.38 依赖，见 `known-issues.md` #2）。
- **DEB 打包**：`orange-pi-terminal` + `orange-pi-terminal-dev`，debhelper 13，
  `/opt` 自带 Qt 6.5.3，systemd/polkit/desktop 齐备，`lintian` 0 error。

## 5. 文档、技能与第三方

- `docs/README.md` 索引、`docs/performance.md` 性能总纲、`docs/handover.md` 交接、
  `docs/deb-packaging.md`、`docs/known-issues.md`、本文件。
- `skills/build-release`、`skills/deb-packaging` 两个技能。
- `third_party/deps`（原 `vendor/deps`）、`third_party/gst/<arch>/plugins`（arm64/amd64）。
- `toolchain/qt-6.5.3-aarch64`（从 `sdk/` 移出）与 `sdk/esp-firmware` 两个完整仓库快照。
- 示例/模板固件默认开启 NimBLE（否则 `idf.py build` 报 `host/ble_gap.h` 缺失）。

## 6. 仍与 main 不同的取舍

- 仓库体积：`toolchain/` 1.3 GB + `sdk/` 36 MB 随仓分发（main 不跟踪 `esp/`）。
- `docs/archive/` 归档了 04–11 轮 devdocs 与旧部署快照。
- 未实现：fake-IP 白名单开关、外部代理策略推送。
