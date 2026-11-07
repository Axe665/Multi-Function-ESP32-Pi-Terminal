# SDK 与设备固件（完整仓库内容，随主仓分发）

这两个目录是**完整的外部仓库内容**（不含各自的 `.git` 历史），直接随主仓提交，
目的是让下一台开发机 `git clone` 后**不需要再下载任何 SDK 或固件工程**。

| 目录 | 来源仓库 | 固定版本 | 内容 |
|---|---|---|---|
| `qt-6.5.3-aarch64/` | [SomaRia-Meta/qt-6.5.3-aarch64](https://github.com/SomaRia-Meta/qt-6.5.3-aarch64) | `d8c0c52` | Qt 6.5.3 aarch64 交叉 SDK：`src/`、`artifacts/`、`cross-build/`、`deploy/`、`sdk/` |
| `esp-firmware/` | [gggitj/ESP-Modular-Terminal-Service](https://github.com/gggitj/ESP-Modular-Terminal-Service) | `16aebdd` | 桥板 / 模块 ESP-IDF 工程：`esp/S3_PiBridge_LinkIt_Host/`、`esp/S3_Pi_Module/`、`esp/shared/`、`module-devkit/` |

## 使用

```sh
# Qt 交叉 SDK：解包 + 导出环境
./sdk/qt-6.5.3-aarch64/sdk/install.sh          # 或按该仓库 README 手动解包 artifacts/
export ORPI_SYSROOT=<...>/pi-sysroot
export ORPI_QT_PREFIX=<...>/qt653-arm64
cmake --preset aarch64-cross                    # 在 pi_terminal/ 下

# ESP 固件
. ~/esp/esp-idf/export.sh                      # ESP-IDF 5.5.4，见 module-devkit/docs/ESP-TOOLCHAIN.md
./build_scripts/build_esp32.sh S3_Pi_Module
```

## 体积与更新

- 合计约 **1.4 GB**（Qt 1.3 GB + 固件 36 MB），是“免下载”与“仓库体积”之间的取舍；
- 更新方式：在来源仓库拉新版本，用 `rsync -a --exclude=.git <repo>/ sdk/<dir>/` 覆盖，
  再更新本文件的固定版本号；
- 如果只是想让 PR 轻量，可在提交前临时把 `sdk/` 放到 `.git/info/exclude`，
  但**发布分支必须带上**，否则下一台机器又要联网。

## 为什么不用 submodule

submodule 仍然要求目标机器联网拉取，且版本漂移时只看到一个 SHA。这里按“完整内容
入库”处理，配合 `docs/build-from-scratch.md` 可以离线完成 Qt + 固件的编译。
