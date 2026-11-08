# ESP 固件工具链（ESP-IDF 5.5.4 / ESP32-S3）

设备侧固件（桥板 + 模块）在 **独立仓库** 里构建，本仓不跟踪 `esp/` 目录。
完整工程内容随主仓放在 [`sdk/esp-firmware/`](../../sdk/esp-firmware/)，固定版本
`16aebdd`。

## 1. 版本要求（写死，不要用 latest）

| 组件 | 版本 | 说明 |
|---|---|---|
| ESP-IDF | **5.5.4** | 与 `sdk/esp-firmware/` 的 `sdkconfig.defaults` 对齐 |
| mbedTLS | **3.6.5** | 随 IDF 5.5.4 提供；PBR 协议向量按此版本生成 |
| 目标芯片 | ESP32-S3（Xtensa LX7） | 桥板 LinkIt Host 与模块都用 S3 |
| 工具链 | `xtensa-esp32s3-elf-gcc`（IDF 5.5.4 自带，GCC 14.2） | `install.sh esp32s3` 自动装 |
| Python | 3.9–3.12 | `idf.py` 依赖 |

> 版本不一致的典型症状：`mbedtls/ecdsa.h` 找不到 P-256 接口、PBR 向量跑不过、
> `undefined reference to mbedtls_*`。先核对 `idf.py --version` 再查代码。

## 2. 安装（一次性）

```sh
# 1) 取 IDF 5.5.4（递归子模块，约 2.5 GB）
git clone -b v5.5.4 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf
cd ~/esp/esp-idf

# 2) 只装 S3 需要的工具链
./install.sh esp32s3

# 3) 每个新 shell 都要 export
. ./export.sh
idf.py --version        # 应输出 ESP-IDF v5.5.4
```

离线机器：在联网机器上把 `~/.espressif` 整个目录和 `~/esp/esp-idf` 一起拷过去，
`export.sh` 不需要联网。

## 3. 构建

```sh
# 工程在 sdk/esp-firmware/esp/ 下（旧文档写 esp/，等价）
export PI_MODULE_SDKCONFIG=$PWD/sdkconfig.private     # 私有配置，不入库
./build_scripts/build_esp32.sh S3_Pi_Module
./build_scripts/build_esp32.sh S3_PiBridge_LinkIt_Host
```

示例/模板固件（`module-devkit/*/firmware/`）需要显式指向组件 SDK：

```sh
. ~/esp/esp-idf/export.sh
export MODULE_SDK_DIR=$PWD/module-devkit/sdk
cd module-devkit/examples/smart-planter/firmware
idf.py -B build set-target esp32s3 build
```

`sdkconfig.defaults` 已带 NimBLE（`CONFIG_BT_ENABLED` / `CONFIG_BT_NIMBLE_ENABLED`），
否则 bt 组件会报 `host/ble_gap.h` 缺失。实测（2026-11-07，ESP-IDF 5.5.4）：
`module_firmware.bin` 1.2 MB / `.elf` 12 MB，构建通过。

`build_esp32.sh` 只做两件事：检查 `idf.py` 已在 PATH、把 `ESP_BUILD_DIR` 指到
`~/esp32_workspace/builds/<project>`。它**不会**替你 source IDF。

模块工程还有一层封装：

```sh
./module-devkit/firmware-build.sh <module-project> BLE|LAN <build-dir>
```

该脚本要求 `PI_MODULE_SDKCONFIG` 和 `PI_MODULE_PACKAGE_DIR`（先跑
`module_devkit.py prepare-firmware`），因为它要把签名包嵌进固件。

## 4. 烧录与调试

```sh
idf.py -C sdk/esp-firmware/esp/S3_Pi_Module -p /dev/ttyACM0 flash monitor
```

- 桥板走 CH343（`/dev/ttyUSB0`），模块走原生 USB-Serial/JTAG（`/dev/ttyACM0`）；
- 串口被占用时先 `sudo fuser -k /dev/ttyACM0`；
- 欠压会导致烧录中途复位，先 `vcgencmd get_throttled` 确认 0x0。

## 5. 常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| `ESP-IDF is not exported; source export.sh first` | 新 shell 没 export | `. ~/esp/esp-idf/export.sh` |
| `Unknown ESP32 project` | 工程名不是 `S3_Pi_Module` / `S3_PiBridge_LinkIt_Host` | 用 `sdk/esp-firmware/esp/` 下的目录名 |
| `mbedtls/ecdsa.h: No such file` | IDF 版本不对（不是 5.5.4） | 重新 clone `-b v5.5.4` |
| `ninja: build stopped: subcommand failed` + 找不到 `xtensa-esp32s3-elf-gcc` | 只跑了 `install.sh` 没 export | export 后再 build |
| 固件能跑但 PBR 握手失败 | 私钥/公钥与终端信任库不匹配 | 见 `docs/pbr-secure-v1/` |

## 6. 与主仓的关系

- 主仓的 `module-devkit/sdk/esp32/` 是**设备侧组件 SDK**（LinkIt、board_pins、
  data/control service、diagnostics），随主仓构建；
- `sdk/esp-firmware/` 是**完整固件工程**，用于桥板和模块的最终产物；
- 两者版本要一起升：组件接口变了，固件工程的 `CMakeLists.txt` 里
  `EXTRA_COMPONENT_DIRS` 指向 `module-devkit/sdk/esp32/components`。
