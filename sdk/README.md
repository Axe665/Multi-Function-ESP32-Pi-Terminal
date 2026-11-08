# sdk：设备固件（完整仓库内容）

这里只放**设备侧固件**。交叉编译工具链已移到 [`../toolchain/`](../toolchain/)。

| 目录 | 来源仓库 | 固定版本 | 内容 |
|---|---|---|---|
| `esp-firmware/` | [gggitj/ESP-Modular-Terminal-Service](https://github.com/gggitj/ESP-Modular-Terminal-Service) | `16aebdd` | `esp/S3_PiBridge_LinkIt_Host/`、`esp/S3_Pi_Module/`、`esp/shared/`、`module-devkit/`、`archive/` |

## 与主仓 SDK 的关系

- `module-devkit/sdk/esp32/` 是**设备侧组件 SDK**（LinkIt、board_pins、data/control
  service、diagnostics），随主仓分发；
- `sdk/esp-firmware/module-devkit/sdk/esp32/` 是固件仓库里的同一套组件，**以固件仓库为准**；
- 同步与一致性检查：`python3 tools/sync_module_devkit.py --check`（`--write` 落盘）。

## 同步状态（2026-11-08）

| 项 | 状态 |
|---|---|
| `module-devkit/sdk/esp32` 组件 | 与主仓 0 差异 |
| `module-devkit/sdk/include/pi_module_api.h` | 已升到 **v2**（`network_request` / `file_request`） |
| 示例/模板 `module.cpp` | 已改为 `PI_MODULE_API_VERSION` 返回值与检查 |
| 示例/模板 `sdkconfig.defaults` | 已补 NimBLE（`CONFIG_BT_ENABLED` 等），否则 `host/ble_gap.h` 缺失 |
| 实测 | ESP-IDF 5.5.4 编译通过：`module_firmware.bin` 1.08 MB |

桥板 PBR 说明：本快照的 `S3_PiBridge_LinkIt_Host` 是 **PBR1 明文帧 + CRC**（`pbr_send_frame`），
不是终端侧 `pbr-secure-v1`（X25519/ChaCha20/ECDSA）。安全桥板固件不在公开仓库里，
终端侧的 TTL 负偏差、`boot_id` 重握手修复**没有对应的固件源码可同步**。

## 构建固件

```sh
. ~/esp/esp-idf/export.sh        # ESP-IDF 5.5.4
./build_scripts/build_esp32.sh S3_Pi_Module
```

工具链安装见 [module-devkit/docs/ESP-TOOLCHAIN.md](../module-devkit/docs/ESP-TOOLCHAIN.md)。
