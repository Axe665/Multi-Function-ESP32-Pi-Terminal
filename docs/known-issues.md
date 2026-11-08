# 已知问题与修复记录（2026-11-07）

按“现象 → 根因 → 修法 → 验证”记录本轮踩过的坑。全部有实机日志，不是推测。

## 1. 登录后界面冻结数秒

- **现象**：输入 PIN 后界面卡住，日志 `kdf-worker: unavailable, login will block on the main thread`。
- **根因**：只编译了主程序，`terminal_kdf_worker` 缺失；PBKDF2 600k 回退到主线程同步执行。
- **修法**：编全部目标（或 deb，deb 会带 worker）；`SessionManager` 保留异步路径与回退。
- **验证**：`kdf-worker: ready` + `auth: async login completed in 6753 ms`（同步 8616 ms）。

## 2. 交叉产物在 Pi 上 `GLIBC_2.38 not found`

- **现象**：`/opt/.../libterminal_ui.so.1: /lib/aarch64-linux-gnu/libm.so.6: version 'GLIBC_2.38' not found`。
- **根因**：链接器在宿主 `aarch64-linux-gnu` 交叉包里找到了 glibc 2.39 的 libm，而不是 sysroot（Debian 12 / 2.36）里的。
- **修法**：`pi_terminal/cmake/toolchain-aarch64.cmake` 给 EXE/SHARED/MODULE 链接追加
  `-L$ORPI_SYSROOT/usr/lib/aarch64-linux-gnu -L$ORPI_SYSROOT/lib/aarch64-linux-gnu`。
- **验证**：`readelf --version-info libterminal_ui.so.1.0` 最高只到 `GLIBC_2.34`，Pi 上正常启动。

## 3. worker 沙箱起不来（deb /opt 布局）

- **现象**：`status=203/EXEC`，或应用静默降级为普通 QProcess（无隔离）。
- **根因**：unit 固化了 `ExecStart=/usr/libexec/orange-pi-terminal/module_worker`，而 deb 把
  worker 装在 `/opt/orange-pi-terminal/libexec/`；另外 polkit 规则只匹配 `raspberrypi`。
- **修法**：deb 增加 `/usr/libexec/orange-pi-terminal/module_worker` 兼容链接；polkit 规则改为
  “单位名 + 动作”限制下放行 `subject.local && subject.active`。
- **验证**：普通用户 `systemctl start orange-pi-worker@proof` 成功，worker uid 61689、
  `CapEff=0`、`NoNewPrivs=1`、`Seccomp=2`、netns 仅 lo、`AF_INET` 拒绝。

## 4. 系统代理与应用自带代理冲突（升级遗留）

- **现象**：`/opt/.../network_proxy` 由 system unit 启动时，所有通道返回 `403 channel-off`。
- **根因**：两条路径用**不同的策略文件**：
  - system unit：`--policy /run/orpi-net-proxy/policy.json`（开机 drop-in 写入的空策略，默认拒绝）；
  - 应用自拉：`--policy /tmp/runtime-<user>/orange-pi-net-policy.json`（应用实时写入）。
  应用检测到端口已占用后不再写 system 那份策略，于是 system 代理一直“全关”。
- **修法（当前）**：deb 安装后**不要 enable** `orange-pi-net-proxy`，让应用自己拉代理；
  从旧部署升级时执行 `sudo systemctl disable --now orange-pi-net-proxy`。
- **待办**：若确实需要“代理先于应用启动”（无头场景），应让应用在检测到外部代理时把策略
  推给它（例如写文件 + `SIGHUP`），而不是另起一个。
- **验证**：禁用 system unit 后，`/opt` 代理带 `/tmp/runtime-...` 策略启动，
  `34001→1.1.1.1 = 502`（放行、上游不可达）、`34002 = 403`（通道关闭）、私网/回环 403。

## 5. 天气/时钟在 fake-IP 网络下 403

- **现象**：`deny ... why=target-not-public line=CONNECT api.met.no:443`。
- **根因**：代理软件 fake-IP 把域名解析到 `198.18.0.0/15`（RFC 2544 保留段），
  出站策略只允许公网 IP，遂拒绝。
- **修法**：关掉 fake-IP（改 redir-host）后恢复正常；若必须共存，可加
  `ORANGE_PI_TRUSTED_FAKE_IP=1` 白名单（尚未实现）。
- **验证**：关闭后 `getent hosts timeapi.io` 返回 `51.75.52.74`，`net-proxy: allow`。

## 6. 测试超时误判（Pi 3B）

- **现象**：`auth_service_test`/`session_gate_test`/桌宠用例在 CTest 里 Timeout。
- **根因**：超时按 x86 调的（30–300 s），A53 上 KDF 与 QML 场景慢数倍。
- **修法**：`TERMINAL_TEST_TIMEOUT_SCALE`（aarch64 默认 ×4）。
- **验证**：放宽后用 900 s 直跑，四项全部通过（10/10、14/14、31/31、20/20）。

## 7. 音乐解码失败（目标机环境）

- **现象**：`music_http_seek_clock` 失败，`no element playbin`。
- **根因**：目标机缺 GStreamer 运行期插件。
- **修法**：`third_party/gst/<arch>/plugins/`（已预置 arm64 255 个 / amd64 264 个），
  运行时设 `GST_PLUGIN_PATH`/`LD_LIBRARY_PATH`。
