---
name: Pi Terminal DEB 打包
description: 为 Multi-Function-ESP32-Pi-Terminal 出 Debian 包（orange-pi-terminal 与 -dev）、检查 /opt 布局、RUNPATH、systemd/polkit 安装、lintian 取舍时使用。适用于“打成 deb”“安装包升级”“包体积/依赖”这类任务。
---

# Pi Terminal DEB 打包

## 包结构

| 包 | 内容 |
|---|---|
| `orange-pi-terminal` | 运行时全量（含 Qt 6.5.3 到 `/opt/orange-pi-terminal/qt`）、systemd 单元、polkit、desktop |
| `orange-pi-terminal-dev` | `pi_module_api.h`、`IModulePlugin.h`、`OrangePiModuleSDKConfig.cmake`、`libpi_module_sdk` |

`debian/rules` 交叉编译（`-aarm64`），`debian/stage-deb.sh` 负责拆包、裁剪 Qt、改 RUNPATH。

## 构建

```sh
export ORPI_SYSROOT=.../pi-sysroot
export ORPI_QT_PREFIX=.../qt653-arm64     # dev 树，不是运行时
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64
export ORPI_FLITE_ROOT=.../flite-aarch64
dpkg-buildpackage -b -aarm64 -us -uc -d
```

## 必须检查

1. `dpkg-deb -c` 里没有 `.git`、`*.a`（dev 包除外）、`include/`（运行时包）；
2. 每个 ELF 的 RUNPATH 指向 `/opt/orange-pi-terminal/{lib,qt/lib}`；
3. `usr/bin/orange-pi-terminal` 是 wrapper，不是二进制本体；
4. `lintian` 无 error；`embedded-library`/`no-manual-page` 可 override；
5. 卸载不删 `~/.config/ModularTerminal` 与 `~/.local/share/ModularTerminal`。

## 坑

| 现象 | 原因 | 处理 |
|---|---|---|
| Pi 上 `GLIBC_2.38 not found` | 链接捡到宿主交叉包 glibc，不是 sysroot | toolchain 加 `-L<sysroot>/usr/lib/aarch64-linux-gnu` |
| system unit `203/EXEC` | deb 在 /opt，unit 写死 /usr | 装 drop-in 或建 `/usr/libexec/...` 兼容链接 |
| 系统代理全 403 channel-off | system unit 用空策略文件，应用另起代理 | `systemctl disable --now orange-pi-net-proxy` |

| 现象 | 原因 | 处理 |
|---|---|---|
| 安装后启动 `symbol lookup error` | 库 RUNPATH 仍是构建机路径 | stage 脚本对所有 ELF `patchelf` |
| 包 1 GB+ | Qt 未裁剪 | 去掉 `include/ lib/cmake bin/ mkspecs *.a`，保留 `libexec/`（WebEngineProcess） |
| 用户单元不生效 | 只装了文件没 enable | postinst `systemctl --global enable pi-module-terminal.service` |
| `dpkg-buildpackage` 报缺 Build-Depends | Qt 来自 SDK，不在系统 | 必须带 `-d` |
