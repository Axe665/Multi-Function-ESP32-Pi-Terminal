# toolchain：交叉编译 SDK（完整仓库内容）

这里放**交叉编译工具链**，不放设备固件。目标机是 Pi 3B（aarch64 / Cortex-A53），
主力 SDK 是 Qt 6.5.3 aarch64。

| 目录 | 来源仓库 | 固定版本 | 内容 |
|---|---|---|---|
| `qt-6.5.3-aarch64/` | [SomaRia-Meta/qt-6.5.3-aarch64](https://github.com/SomaRia-Meta/qt-6.5.3-aarch64) | `d8c0c52` | `src/`、`artifacts/`（sysroot + Qt 运行库 + host 工具）、`cross-build/`、`deploy/`、`sdk/` |

## 使用

```sh
# 1) 解包 SDK（只需一次）
./toolchain/qt-6.5.3-aarch64/sdk/install.sh
# 或者手动按 artifacts/README 解开分片

# 2) 导出环境
export ORPI_SYSROOT=<...>/pi-sysroot
export ORPI_QT_PREFIX=<...>/qt653-arm64
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64     # 仅 moc/qmlcachegen 用

# 3) 构建（在 pi_terminal/ 下）
cmake --preset aarch64-cross
cmake --build --preset aarch64-cross
```

## 体积与更新

- 约 **1.3 GB**（`artifacts/` 是预编译产物，分片存放）；
- 更新：在来源仓库拉新版本后 `rsync -a --exclude=.git <repo>/ toolchain/qt-6.5.3-aarch64/`，
  再更新本文件的固定版本号；
- deb 打包时**不**把这个目录放进包，deb 只带裁剪后的运行库（见 `debian/`）。
