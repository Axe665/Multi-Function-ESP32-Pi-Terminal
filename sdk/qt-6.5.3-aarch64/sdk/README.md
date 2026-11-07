# SDK 三件套：让仓库能真正编译 pi_terminal

`artifacts/` 里只有**运行时**包（给 Pi 解压即用），不含编译所需文件。
交叉编译还需要三样东西，本目录的脚本负责产出/校验它们：

| # | 件 | 缺了会怎样 | 产物 | 体积 |
|---|---|---|---|---|
| 1 | **目标机 Qt 开发树** | `find_package(Qt6)` 失败，configure 过不去 | `orpi-qt653-aarch64-dev.tar.zst` | ~430 MB |
| 2 | **host Qt 6.5.3 (x86_64)** | 报 `Cross-compiling with Qt requires QT_HOST_PATH`；moc/rcc 在 `libexec/` | `orpi-host-qt-6.5.3-gcc_64.tar.zst` | ~290 MB |
| 3 | **Pi sysroot** | 链接失败，或产物到 Pi 报 `GLIBC_2.38 not found` | `pi-sysroot.tar.zst` | ~470 MB |

## 快速用法

```bash
# 1) 解压三件套（或设置 ORPI_SDK_ROOT 指向已有目录）
mkdir -p dist/sdk && tar -C dist/sdk -xf orpi-qt653-aarch64-dev.tar.zst
tar -C dist/sdk -xf orpi-host-qt-6.5.3-gcc_64.tar.zst
tar -C dist/sdk -xf pi-sysroot.tar.zst
# 期望布局：dist/sdk/{qt653-arm64,host-qt,pi-sysroot}

# 2) 自检（缺哪项、怎么补，逐条打印）
./sdk/verify-sdk.sh

# 3) 构建
./cross-build/build-project.sh /path/to/pi_terminal_repo
```

## 自己产出三件套

```bash
./sdk/make-dev-sdk.sh  /path/to/qt653-arm64      # 从完整安装前缀打开发树
./sdk/make-host-qt.sh                            # aqtinstall 拉 6.5.3 gcc_64（或重打包已有）
./sdk/make-sysroot.sh  raspberrypi@<pi-ip>       # 从 Pi rsync 根文件系统并清掉系统 Qt 6.4
```

### 没有完整安装前缀怎么办

`cross-build/build-qt653.sh` 从源码构建（`docs/` 有 4 处源码改动说明），
产物就是这里的“完整安装前缀”。构建耗时数小时，建议构建一次后
用 `make-dev-sdk.sh` 打成 SDK 复用。

## 两个已知坑（脚本已处理）

- **GCC 版本**：目标机 Debian 12 的 libstdc++ 是 GCC 12；用宿主默认的 GCC 13 会引用
  `std::ios_base_library_init`，链接报 `undefined reference`。`env.sh` 会自动选
  `aarch64-linux-gnu-g++-12` 并生成包装器。
- **isoc23 符号**：宿主 glibc 2.39 的头文件会引入 `__isoc23_*`；`env.sh` 会用
  `cross-build/isoc23_compat.c` 编一个弱符号桩，并在链接时注入。

## 项目侧还需要一步（不属于本仓库）

pi_terminal 的 vendored flite 在交叉编译时会把 `CC="gcc --target=… --sysroot=…"`
作为带空格的字符串传给 configure，报 `C compiler cannot create executables`。
用 `./sdk/build-flite.sh <flite-src>` 预构建，然后：

```bash
export ORPI_FLITE_ROOT=$(pwd)/build/flite
./cross-build/build-project.sh ...
```
