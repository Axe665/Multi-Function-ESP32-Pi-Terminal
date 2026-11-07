# SDK 与设备固件（外部仓库，submodule 固定版本）

这两个目录是**外部仓库**，不是本仓库源码的一部分。用 submodule 固定 commit，
是为了让下一台开发机 `git clone --recurse-submodules` 后能直接拿到与发布一致的
Qt 交叉 SDK 和 ESP 固件，不必猜版本。

| 目录 | 仓库 | 固定 commit | 用途 |
|---|---|---|---|
| `qt-6.5.3-aarch64/` | [SomaRia-Meta/qt-6.5.3-aarch64](https://github.com/SomaRia-Meta/qt-6.5.3-aarch64) | `d8c0c52` | Pi 3B 的 Qt 6.5.3 aarch64 交叉 SDK：sysroot、Qt 运行库、host 工具、可复现构建脚本 |
| `esp-firmware/` | [gggitj/ESP-Modular-Terminal-Service](https://github.com/gggitj/ESP-Modular-Terminal-Service) | `16aebdd` | 桥板 / 模块 ESP-IDF 固件工程（`esp/S3_PiBridge_LinkIt_Host`、`esp/S3_Pi_Module`、`esp/shared`） |

## 获取

```sh
git clone --recurse-submodules https://github.com/Axe665/Multi-Function-ESP32-Pi-Terminal.git
# 已经 clone 过：
git submodule update --init --recursive
```

## 为什么不用普通目录

- Qt SDK 仓库包含约 1.1 GB 的构建产物（sysroot、Qt 库、host 工具），直接提交会
  超过 GitHub 单文件 100 MB / 仓库建议 1 GB 的限制；
- 固件仓库是独立发布节奏，不应该和终端主仓的历史绑死；
- submodule 能精确固定 commit，出问题时可复现到同一版本。

## 离线机器

在联网机器上打包，再拷到离线机：

```sh
git submodule foreach --recursive 'git bundle create ../$(basename $name).bundle --all'
# 离线机
git clone sdk/qt-6.5.3-aarch64.bundle sdk/qt-6.5.3-aarch64
git clone sdk/esp-firmware.bundle sdk/esp-firmware
```

（`sdk/` 下已提供 `fetch-sdk.sh` 做同样的封装。）
