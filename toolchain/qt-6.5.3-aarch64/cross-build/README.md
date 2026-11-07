# 交叉编译链（Qt 6.5.3 aarch64 + pi_terminal）

> **快速路径**：如果只是要编 pi_terminal，先跑 `./sdk/verify-sdk.sh`。
> 三件套（目标机 Qt 开发树 / host Qt / sysroot）可用 `sdk/make-*.sh` 产出，
> 不必从 Qt 源码重编；本文第 3～4 节只在“连 Qt 开发树都没有”时才需要。

目标机：Raspberry Pi 3 Model B，Debian 12 bookworm aarch64（glibc **2.36**）。
宿主：Ubuntu 24.04 x86_64（glibc 2.39）。

## 1. 前置依赖（宿主）

```bash
sudo apt install -y g++-12-aarch64-linux-gnu gcc-12-aarch64-linux-gnu \
  ninja-build cmake gperf bison flex nodejs python3 python3-six python3-html5lib \
  python3-bs4 python3-lxml libclang-dev patchelf rsync zstd \
  libnss3-dev libnspr4-dev libwebp-dev libtiff-dev libjpeg-dev libpng-dev libicu-dev \
  libxml2-dev libxslt1-dev libevent-dev libopus-dev libre2-dev libsnappy-dev libsrtp2-dev \
  libvpx-dev libjsoncpp-dev libminizip-dev libprotobuf-dev protobuf-compiler liblcms2-dev \
  libdav1d-dev libavcodec-dev libavformat-dev libswscale-dev libavutil-dev libcups2-dev \
  libxcomposite-dev libxdamage-dev libxrandr-dev libxtst-dev libdrm-dev libgbm-dev \
  libasound2-dev libpulse-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libvulkan-dev libxkbcommon-dev libxkbcommon-x11-dev libxcb1-dev libx11-xcb-dev
```

Python 3.12 需要 `imp` 垫片（Chromium 脚本用）：把仓库 `tools/pyshim/imp.py` 放到
`PYTHONPATH` 里（`env.sh` 已处理）。

## 2. Pi sysroot

> 已有脚本：`./sdk/make-sysroot.sh user@pi-host` 会 rsync、清系统 Qt 6.4、相对化符号链接并打包。
> 下面是它做的事，手工操作时可参考。

从 Pi 上 rsync 一份根文件系统（剔除 `/proc /sys /dev /home /var` 等），或者复用项目移交的
`pi-sysroot`。必须清理其中**系统的 Qt 6.4**（否则 find_package 会找到 6.4）：

```bash
S=/path/to/pi-sysroot
rm -rf $S/usr/lib/aarch64-linux-gnu/cmake/Qt6* $S/usr/lib/aarch64-linux-gnu/libQt6* \
       $S/usr/include/aarch64-linux-gnu/qt6 $S/usr/lib/aarch64-linux-gnu/qt6
# 绝对符号链接改相对（Debian 的 .so 常指向 /lib/...，会让 CMake 选中 .a）
# 重点：libdbus-1.so -> libdbus-1.so.3.32.4（必须是共享库而不是 .a）
```

### 2.1 xcb 开发文件（否则 Qt 的 xcb 平台插件不会编译）

`sysroot` 里 xcb 扩展常常只有运行时 `.so.0`，缺 `.so` 开发链接、头文件与 `.pc`。
从 Debian 12 arm64 仓库解包补齐（不需要装到 Pi）：

```bash
for p in libxcb-composite0-dev libxcb-cursor-dev libxcb-damage0-dev libxcb-dpms0-dev \
         libxcb-record0-dev libxcb-render-util0-dev libxcb-res0-dev \
         libxcb-screensaver0-dev libxcb-xtest0-dev libxcb-xv0-dev libxcb-xvmc0-dev \
         libxkbcommon-x11-dev x11proto-dev libpthread-stubs0-dev; do
  fn=$(awk -v pkg="$p" '$1=="Package:"&&$2==pkg{f=1} f&&$1=="Filename"{print $2;exit}' Packages)
  curl -sO "https://deb.debian.org/debian/$fn"
  dpkg-deb -x "$(basename $fn)" "$S"
done
```
（`Packages` 是 Debian bookworm `binary-arm64/Packages` 索引。）

## 3. Qt 6.5.3 源码

```bash
curl -O https://download.qt.io/archive/qt/6.5/6.5.3/single/qt-everywhere-src-6.5.3.tar.xz
tar -xf qt-everywhere-src-6.5.3.tar.xz
```

然后应用 `docs/QT-SOURCE-CHANGES.txt` 里的 4 处修改（Python 3.12 的 `imp`、
vendored six 1.14、catapult 的 html5lib、路径保持 ASCII）。

## 4. 构建

```bash
export ORPI_SYSROOT=/path/to/pi-sysroot
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64        # Qt 官方 x86_64 SDK
export ORPI_QT_PREFIX=/path/to/qt653-arm64      # 安装前缀
export ORPI_CROSS_PREFIX=/usr/bin/aarch64-linux-gnu-   # 必须是 GCC 12（见 sdk/verify-sdk.sh）
export QT_SRC=/path/to/qt-everywhere-src-6.5.3
./cross-build/build-qt653.sh        # 配置 + 打补丁 + ninja + install
./cross-build/build-project.sh      # 项目交叉编译
./cross-build/make-deliverable.sh   # 出 Pi 交付包
```

`build-qt653.sh` 内部会调用 `patch-qt-build.py`，给 `rules.ninja` 和 GN 的
`toolchain.ninja` 注入 sysroot `-L` 与 `isoc23_compat.o`。**Qt 每次重新 configure 后都要重跑一次。**

## 5. 已知坑

| 现象 | 原因 | 处理 |
| :--- | :--- | :--- |
| `undefined reference to __isoc23_strtol` | 宿主 glibc 2.39 头文件排在 sysroot 前 | 注入 `isoc23_compat.o` |
| Pi 上 `version GLIBC_2.38 not found` | 链接时用了宿主 libc | 链接加 sysroot `-L`（本仓库已内置） |
| `PermissionError: .../gen/../../../../home` | Chromium 脚本用 `..` 穿越 + 工作路径是符号链接 | 用 **bind mount** 而不是 symlink 挂载 `qt653-{src,build}`、`pi-sysroot` |
| `FEATURE_xcb=OFF` / 找不到平台插件 | sysroot 缺 xcb 开发文件 | 见 2.1，另建 qtbase-only 构建补 `libqxcb.so` |
| xcb 插件 `undefined symbol: ...QX11Application` | 旧 `libQt6Gui` 在 xcb 关闭时构建 | 用启用 xcb 的构建替换 Gui（符号差集为 0） |
| `Cannot create platform OpenGL context` | 缺 `libqxcb-egl-integration.so` | 装到 `plugins/xcbglintegrations/` |
