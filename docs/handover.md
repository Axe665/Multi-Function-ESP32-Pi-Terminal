# 交接指南（另一台电脑从零接手）

目标：新机器 `git clone` 后，不改代码即可编译、运行、出 deb、连树莓派部署。
按顺序做，每步都有验收点。

## 1. 机器要求

| 项 | 要求 |
|---|---|
| 系统 | Linux x86_64（Ubuntu 24.04 / Debian 12 验证过） |
| 磁盘 | ≥ 8 GB 空闲（仓库 1.7 GB + 构建 2 GB + deb 1 GB） |
| 工具 | `git cmake ninja-build gcc g++ aarch64-linux-gnu-gcc-12 aarch64-linux-gnu-g++-12 patchelf zstd dpkg-deb debhelper lintian` |
| 可选 | ESP-IDF 5.5.4（只做固件时需要，见 `module-devkit/docs/ESP-TOOLCHAIN.md`） |

```sh
sudo apt install git cmake ninja-build build-essential \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu patchelf zstd \
  debhelper lintian pkg-config python3-pil python3-cryptography
```

## 2. 取代码

```sh
git clone --recursive https://github.com/Axe665/Multi-Function-ESP32-Pi-Terminal.git
cd Multi-Function-ESP32-Pi-Terminal
git checkout pr/sync-terminal-2026-11     # 当前交付分支
```

仓库自带两个完整外部仓库快照（不需要联网再拉）：

- `toolchain/qt-6.5.3-aarch64/` — Qt 交叉 SDK（含 artifacts 分片）
- `sdk/esp-firmware/` — ESP 固件工程

## 3. 跑起来（最快路径，x86 桌面 Qt 6.5.3）

```sh
cd pi_terminal
cmake --preset linux-qt653          # 需要 /opt/Qt/6.5.3/gcc_64 或改 CMAKE_PREFIX_PATH
cmake --build --preset linux-qt653 --parallel 8
./build-qt653/orange_pi_terminal --window-size 1024x600
```

> **不要只编主程序**：`terminal_kdf_worker` 与 `network_proxy` 缺失时，登录会回退主线程
> 同步 KDF（界面冻结），联网全失败。用上面的 preset 编全部目标即可。

## 4. 交叉编译到 Pi

```sh
# 解包 SDK（首次）
cd toolchain/qt-6.5.3-aarch64 && ./sdk/install.sh && cd -

export ORPI_SYSROOT=$PWD/toolchain/qt-6.5.3-aarch64/dist/sdk/pi-sysroot
export ORPI_QT_PREFIX=$PWD/toolchain/qt-6.5.3-aarch64/dist/sdk/qt653-arm64
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64

cd pi_terminal && cmake --preset aarch64-cross && cmake --build --preset aarch64-cross
```

验收：`aarch64-linux-gnu-readelf -d build-aarch64/orange_pi_terminal | grep RUNPATH`
应包含 `$ORIGIN/../lib/orange-pi-terminal`。

## 5. 部署到 Pi

```sh
./build_scripts/deploy_pi.sh            # 自己申请 root
```

验收（Pi 上）：

```sh
systemctl --user is-active pi-module-terminal      # active
journalctl --user -u pi-module-terminal -n 20 | grep -E 'STARTUP_READY|kdf-worker: ready'
```

## 6. 出 deb

```sh
./build_scripts/build_deb.sh            # 封装了 dpkg-buildpackage 的环境变量
```

产物在仓库上一级目录：`orange-pi-terminal_1.0.0_arm64.deb` 与
`orange-pi-terminal-dev_1.0.0_arm64.deb`。安装与布局见 `docs/deb-packaging.md`。

## 7. 测试

```sh
cd pi_terminal && cmake --preset linux-qt653 -DBUILD_TESTING=ON
cmake --build --preset linux-qt653 --parallel 8
ctest --test-dir build-qt653 --output-on-failure -j4
```

- 桌面环境缺图片/视频依赖时，`arkpets_sprite_packing`、`media_vlc_*` 会失败，
  属环境问题；先 `pip install -r pi_terminal/tools/requirements.txt`；
- 目标板测试超时按 ×4 放宽（`TERMINAL_TEST_TIMEOUT_SCALE`）。

## 8. 常见坑（都踩过）

| 现象 | 原因 | 处理 |
|---|---|---|
| `symbol lookup error ... Qt_6_PRIVATE_API` | 某个库 RUNPATH 指到构建机 | 全部交叉产物 `patchelf --set-rpath` |
| 输密码卡死 | 缺 `terminal_kdf_worker`，同步 KDF 阻塞主线程 | 编全部目标，见 §3 |
| `Could NOT find OpenSSL` | 没找到 `third_party/deps` | 从 `pi_terminal/` 配置，或装 `libssl-dev` |
| 联网全失败 | 缺 `network_proxy` 或未装 polkit/egress | `deploy_pi.sh` 或 deb |
| worker 起不来 | 未装 `50-orpi-worker.rules` | deb 自带；手动部署见 `DEPLOY.md` |
| 音乐/电视无解码 | 缺 GStreamer 插件 | `third_party/gst/<arch>/plugins` + `GST_PLUGIN_PATH` |

## 9. 交接检查清单

- [ ] `cmake --preset linux-qt653` 配置成功
- [ ] `ctest` 至少主程序/协议/安全用例通过
- [ ] `aarch64-cross` 构建成功且 RUNPATH 正确
- [ ] `build_scripts/deploy_pi.sh` 在 Pi 上跑通
- [ ] `dpkg-buildpackage` 出两个 deb，`lintian` 无 error
- [ ] 能说清 `docs/performance.md` 的构建优化与 `docs/README.md` 的文档地图
