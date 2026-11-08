# AGENTS.md — 给接手机器的 AI

你在一个 Linux 触屏终端项目里工作（C++17 / Qt 6 / QML + ESP32 固件）。
下面几条是**硬性要求**，不是建议。

## 一、部署必须真的做

```bash
./build_scripts/check_deps.sh                       # 1. 缺什么装什么
cd pi_terminal && source scripts/env.sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8                  # 2. 到退出码 0
cd .. && ./build_scripts/deploy_pi.sh                      # 3. 必须执行（脚本自己申请 root）
```

第 3 步**必须执行，没有替代路径**。脚本会自己 `exec sudo` 申请提权，终端弹出密码提示后输密码即可。
不要只编译不安装，不要跳过部署，权限申请失败就停下报告。

## 一·半、编译完成 ≠ 完成

部署之后**必须**跑验收，且必须全绿：

```bash
./build_scripts/verify_install.sh
```

它检查的不是"文件在不在"，而是能力是否真的可用：

- `orange-pi-worker@.service` 的沙箱属性：`DynamicUser=yes`、`PrivateNetwork=yes`、
  `ProtectHome=yes`、`ProtectSystem=strict`、`NoNewPrivileges=yes`；
- `orange-pi-net-proxy` 与 `orange-pi-file-daemon` 处于 active；
- polkit 策略存在（`net-policy-helper` 的授权前提）；
- net-proxy 的 runtime 目录存在。

**任何一项 `[FAIL]` 都意味着模块沙箱或网络策略不完整**，此时不允许说"编译好了"。

第 3 步跳过会出现：`net-policy-helper` 不存在、模块沙箱不生效（沙箱由
`orange-pi-worker@.service` 提供，不是应用代码）、网络策略不生效、helper 缺失。
应用照样能启动，所以很容易被误判成"程序有 bug"。

细节与症状对照表见 [`docs/DEPLOY.md`](docs/DEPLOY.md)。

## 二、验收必须看结果

```bash
./build_scripts/verify_install.sh        # 沙箱 + 网络策略 + 服务，必须全绿
systemctl status orange-pi-net-proxy --no-pager
systemctl status orange-pi-file-daemon --no-pager

# 空库启动必须进开机向导（第 1 步：开始使用）
XDG_CONFIG_HOME=$(mktemp -d) XDG_DATA_HOME=$(mktemp -d) \
  build/orange_pi_terminal --window-size 1024x600
```

日志里应当出现 `onboarding: no users, starting first-run setup`
或 `onboarding: no administrator left, …`。

## 三、提 PR 之前清数据残留

```bash
rm -rf ~/.config/ModularTerminal/OrangePiTerminal
rm -rf ~/.local/share/ModularTerminal/OrangePiTerminal
```

不清的话，别人拉到分支一跑会直接进锁屏而不是向导，看起来像 OOBE 坏了。

## 四、依赖边界

- **已内置**：OpenSSL / mbedTLS / SQLCipher 在 `third_party/deps`，不要另装；
- **必须外部**：Qt 6.4.2（目标机基线，发行版系统包）／6.5.3（开发可用，作者 SDK），最低 6.4、GStreamer、X11/OpenGL；
- **功能级**：`nft`、`python3`、`espeak-ng`；
- **不要**把构建产物塞进仓库：SDK 交叉包走 GitHub Release（tag `sdk-v1`），
  仓库只留 `tools/artifacts.manifest` + `tools/fetch_artifacts.sh`（按需下载并校验 SHA256）。
  **预编译 deb 不发布**，需要时用 `./build_scripts/build_deb.sh` 现打。
  CI 会拦下 PR 里新增的 >20 MB 文件（`.github/workflows/large-files.yml`，语音模型白名单除外）。

## 四·半、历史已重写：本地仓库必须重新 clone

2026-11 删掉了 `dist/` 下的预编译 deb、`toolchain/.../artifacts/` 分卷和 `toolchain/.../src/`（旧快照），
并把那 1.7 GB 分卷从**历史**里一并剔除。**所有提交号都变了，旧 clone 不能 `git pull`**：

```bash
git clone git@github.com:Axe665/Multi-Function-ESP32-Pi-Terminal.git   # 约 630 MB
cd Multi-Function-ESP32-Pi-Terminal && ./tools/fetch_artifacts.sh      # 需要交叉编译时
```

旧仓库里有未推送提交的，先 `git format-patch` 出来再打到新仓库上。
完整历史备份在 `~/repo-backups/mfet-backup-2026-11-08.git`（旧提交号，仅供追溯）。

## 五、改动风格

- 文案用中文；标识符、协议字段保持英文。
- 改 QML 后跑 `ui_responsive_touch` 与 `ui_highdpi_touch`，1024×600 下不允许有布局告警。
- 提交信息用 `type(scope): 中文描述`。
