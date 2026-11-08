# PR #45 描述（2026-11-07 定稿）

> 分支 `pr/sync-terminal-2026-11` → `main`。GitHub 上的标题/正文需在网页或 API 更新，
> 本文件是唯一权威版本，复制即可。

## 标题

```
feat: 同步 2026-11-07 进度 + DEB 打包 + 仓库整理
```

## 正文

```markdown
## 概要

把 2026-10-30 ～ 11-07 的进度同步到 main，并完成仓库整理与 DEB 化。

- 登录改为 **KDF 子进程 + 异步**（8.6 s 阻塞 → 6.75 s 可响应）
- 启动页改为终端日志滚动（C++ BootConsole + QML），消除黑屏
- PBR 控制面修复 TTL 负偏差导致的 `EVENT_EXPIRED`
- 联网权限补齐 polkit / egress / drop-in 的部署缺口
- 新增 **DEB 打包**（`orange-pi-terminal` + `orange-pi-terminal-dev`）
- 交叉 SDK 独立为 `toolchain/`，`sdk/` 只留 ESP 固件
- 文档、技能、第三方依赖全部归位并补测试

基线：`main` @ 86152fc（2026-10-29）· 分支：`pr/sync-terminal-2026-11`
规模：10 commits，5789 files，+2,776,628 / −5,115

## 主要改动

### 登录与启动
- `terminal_kdf_worker` 子进程只做 PBKDF2；`KdfClient` 走 QProcess + 长度前缀协议，
  worker 不可用时自动回退同步路径。
- `SessionGate` 走 `loginWithWorker` / `unlockWithWorker`。
- 启动页换成终端日志（真实耗时、闪烁光标），保留原 objectName 与测试断言。

### PBR 与模块
- `EventTtl` 增加 `kMaxSkewMs=2000` 负偏差容差（握手单向时延约 34 ms，原实现 100% 判过期）。
- `boot_id` 变化触发重握手；拒绝时打印 ttl/sender/receiver/offset/age。
- `--demo` attach 补齐 `p0-control-v1` 字段；模块 API 升到 **v2**。
- 新增 `ORANGE_PI_WORKER_FORCE_DEGRADED` 测试钩子。

### 联网与安全
- egress 规则改绑 `app.slice` level 4（绑 unit 重启即失效）。
- 代理策略 drop-in 用八进制转义（`printf %s` 会被 systemd 展开成 `/bin/bash`）。
- 新增 `packaging/50-orpi-worker.rules`，允许本地会话用户启停 worker 单元。
- file-daemon 改回按需启动（开机自启必失败）。

### 构建与 DEB
- `CMakePresets.json` 增 `aarch64-cross` / `-lto` / `-pgo-generate` / `-pgo-use`；
  `-mcpu` 参数化（`ORPI_TARGET_CPU`），仓库内 `toolchain-aarch64.cmake`。
- 交叉链接固定到 sysroot（修复产物要求 `GLIBC_2.38`、Debian 12 起不来的问题）。
- 目标板测试超时 ×4（`TERMINAL_TEST_TIMEOUT_SCALE`）。
- **两个 deb**：运行时（自带 Qt 6.5.3 到 `/opt/orange-pi-terminal`）与 `-dev`
  （头文件 + `OrangePiModuleSDKConfig.cmake`）；debhelper 13，`lintian` 四个包 **0 error**。
- 预编译包在 `dist/`（arm64/amd64），因 GitHub 单文件 100 MB 限制切成 90 MB 分片，
  `dist/join.sh` 拼回并校验。

### 文档与技能
- 新增：`docs/README.md`（索引）、`docs/performance.md`（性能与优化总纲，含 ARM64
  顺序小核编译要求）、`docs/handover.md`（交接）、`docs/deb-packaging.md`、
  `docs/known-issues.md`（7 条问题记录）、`docs/changes-vs-main.md`。
- 归档：`docs/archive/`（04–11 轮 devdocs + 旧部署快照）。
- 技能：`skills/build-release`、`skills/deb-packaging`。

### 第三方与外部仓库
- `third_party/vendor/deps` → `third_party/deps`（CMake 早已按此查找）。
- `third_party/gst/{arm64,amd64}/plugins`（255 / 264 个），新增 `tools/fetch_gst_plugins.sh`。
- `toolchain/qt-6.5.3-aarch64`（从 `sdk/` 移出）与 `sdk/esp-firmware` 两个**完整仓库内容**。

## 验证

- **宿主构建**：`cmake --preset linux-qt653` + build → 0 error。
- **Pi 3B（deb 安装）**：
  - 启动：`STARTUP_READY`，`kdf-worker: ready`，代理 6 通道 ready；
  - 沙箱：worker uid 61689 ≠ 1000、`CapEff=0`、`NoNewPrivs=1`、`Seccomp=2`、
    netns 仅 `lo`、`AF_INET` 拒绝、`AF_UNIX` OK、模块目录只读；
  - 安全：`users.json 0600`、600000 迭代、DB 头非 SQLite、`libsqlcipher` 生效；
  - 联网：`34001→1.1.1.1 = 502`、`34002 = 403 channel-off`、私网/回环 403，
    nft `orpi_egress` 表存在。
- **x86_64（本机 deb 安装）**：`STARTUP_READY`、KDF/代理均从 `/opt` 启动。
- **测试**：68 项中 67 项通过（唯一失败 `music_http_seek_clock` 是目标机缺
  GStreamer 插件，属环境）。
- **固件**：ESP-IDF 5.5.4 编译 `smart-planter/firmware` 通过（bin 1.16 MB）；
  `sync_module_devkit.py --check` 通过。

## 评审提示

1. **仓库体积**：`toolchain/` 约 1.3 GB、`dist/` 约 515 MB，加上原有内容接近 2 GB。
   这是“下一台机器免下载”的代价；如果主线不接受，可拆成独立分支或走 Release 附件。
2. **大文件**：Qt artifacts 与 deb 分片均 < 100 MB，但超过 GitHub 建议的 50 MB，
   推送时会看到 `GH001` 警告，不影响合并。
3. **行为变更**：TTL 现在接受 −2000…+60000 ms（原 0…3000），测试已同步更新。
4. **代理冲突**：deb 安装后不要 enable `orange-pi-net-proxy`（system 代理用空策略，
   会全拒）；让应用自己拉代理。详见 `docs/known-issues.md` #4。

## Checklist

- [x] 宿主构建通过
- [x] Pi 实机沙箱/安全/联网三连证
- [x] 测试 67/68（1 项环境限制）
- [x] deb 四包 lintian 0 error，arm64 + amd64 均安装验证
- [x] 文档、技能、第三方、SDK 归位
- [x] 固件编译与 SDK 一致性检查
```
