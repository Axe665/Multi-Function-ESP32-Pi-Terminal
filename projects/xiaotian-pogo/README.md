# 啸天红外护栏 pogo 基线

> 产品：啸天红外护栏 pogo ｜ module_id 81 ｜ 形态：独立 HTTPS 设备（非模块包）

2026-11-18 的啸天红外栏杆联调基线：固件 2.1.0 + 独立 Pi 面板 0.1.0 + USB/HTTPS 工具。
它不是本仓库的模块包，也不走 `module_data_service` 的 TCP/BLE 业务面；模块通过
`xiaotian_https_v2` 暴露 `/v1/rpc`，终端要接它需要 `IRController` + HTTPS 适配器。

## 目录

| 路径 | 内容 |
| --- | --- |
| `firmware/` | ESP32-S3 固件源码、分区表、sdkconfig 默认值、构建脚本 |
| `firmware/artifacts/` | 可烧录 bootloader / 分区表 / 应用 bin、`sdkconfig.verified`、SHA256 |
| `firmware/verification/` | 2026-11-18 构建、烧录和联调记录 |
| `pi/` | 独立 Qt 面板（`IRController` + `worker.py` + QML），非模块页 |
| `tools/` | USB 配对、Wi-Fi 配置、状态查询、烧录和测试脚本 |
| `bridge-adapter/` | 旧桥板身份路由候选；已被 2026-11-21 通用桥板固件取代，仅追溯 |
| `HANDOVER.md` | 完整交接手册：焊线、运行逻辑、验收清单、回退 |
| `panel-preview.png` | 面板离屏预览（演示数据，不是真机光路证据） |

## 快速开始

```sh
# 只构建面板（需要 Qt 6.4+）
cmake -S pi -B pi/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build pi/build
bash pi/run-pi.sh --demo

# USB 真机
bash pi/run-pi.sh --serial /dev/ttyUSB0

# 固件构建（Windows 脚本为例）
firmware/build.ps1 -StageDirectory <esp-workdir>
```

烧录、配对、Wi-Fi 和逐项验收见 [`HANDOVER.md`](HANDOVER.md) 与
[`pi/INTEGRATION.md`](pi/INTEGRATION.md)。

## 边界

- 固件已烧录到用户确认的红外板（MAC `d8:85:ac:d6:1d:c0`），但 pogo 与桥板的真实
  握手/拔插、实际光束遮挡闭环、Wi-Fi 实网和树莓派本机 Qt 页面仍需按交接手册复验。
- 当前 GPIO4 读到高电平不能单独证明探头光路正常。
- `firmware/artifacts/` 只保留可烧录 bin、分区表和 sdkconfig 快照；10 MB 的调试 `.elf`
  未入库。`MANIFEST-SHA256.json` 按入库文件重新生成。
- `bridge-adapter/` 是历史候选，未编译、未烧录；通用桥板固件见
  `esp/bridge/S3_PiBridge_LinkIt_Host/` 的 2026-11-21 发布包。
