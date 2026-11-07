# 交叉编译 SDK（分片）

`artifacts/` 顶层的运行时不包含编译所需文件。这里放的是编译 pi_terminal 缺的三件套，
按 95 MB 分片（GitHub 单文件上限 100 MB）：

| 拼回的文件 | 片数 | 体积 | 内容 |
|---|---:|---:|---|
| `orpi-qt653-aarch64-dev.tar.zst` | 1 | 79 MB | 目标机 Qt 开发树：`include/`、`lib/cmake/Qt6`、`mkspecs`、`.prl`、`metatypes` |
| `orpi-host-qt-6.5.3-gcc_64.tar.zst` | 3 | 252 MB | host Qt x86_64：`libexec/moc`、`rcc`、`qmlcachegen`、`lib/cmake` |
| `pi-sysroot.tar.zst` | 5 | 447 MB | Pi（Debian 12）根文件系统：glibc 2.36、libstdc++、OpenSSL、SQLCipher、VLC、GStreamer |

## 用法

```bash
cd artifacts/sdk && ./join.sh          # 拼接 + 校验 SHA256SUMS
mkdir -p ../../dist/sdk
tar -C ../../dist/sdk -xf orpi-qt653-aarch64-dev.tar.zst
tar -C ../../dist/sdk -xf orpi-host-qt-6.5.3-gcc_64.tar.zst
tar -C ../../dist/sdk -xf pi-sysroot.tar.zst
../../sdk/verify-sdk.sh                # 期望 11 项全 PASS
```

`verify-sdk.sh` 默认在 `dist/sdk/{qt653-arm64,host-qt,pi-sysroot}` 找这三样，
也可用 `ORPI_SDK_ROOT` 指到别的目录。

## 来源与边界

- 目标机 Qt：交叉编译自 Qt 6.5.3 源码（含 WebEngine/Multimedia/TextToSpeech），
  构建脚本见 `cross-build/build-qt653.sh`，源码改动见 `docs/QT-SOURCE-CHANGES.txt`；
- host Qt：Qt 官方 6.5.3 `linux_gcc_64`；
- sysroot：从 Pi 3B（Debian 12 bookworm aarch64）rsync，已清掉系统 Qt 6.4、
  相对化符号链接；**含目标机系统文档与许可证，不含 `/home`、`/etc/ssh`、日志**。

重新生成：`sdk/make-dev-sdk.sh`、`sdk/make-host-qt.sh`、`sdk/make-sysroot.sh`。
