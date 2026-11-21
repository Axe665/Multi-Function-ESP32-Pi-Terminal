# 床边守护 · bed.guardian

四只 50 kg 全桥称重传感器 + 四片 HX711 + ESP32-S3。输出床上重量、重心位置和离床/翻身/坐起事件，供 Pi 终端显示和联动夜灯。

## 能力边界（先读）

- 测的是**人 + 床的合重心**，不是身体轮廓或压力分布。能判断左右/头脚位置和姿态变化，不能判断手、脚、精确睡姿。
- 两只人同床时只有一个合重心，分不开两个人。
- 50 kg 是单只额定量程。老人坐床边时，同侧两只脚可能各承担约 (体重 + 床重) / 2；超过 50 kg 请每角并联两只或换 100 kg 传感器。
- 这不是医疗设备，不能单独承担跌倒防护。

## 硬件

| HX711 | DOUT | SCK | 安装位置 |
|---|---|---|---|
| 0 | GPIO4 | GPIO15 | 床头左 |
| 1 | GPIO5 | GPIO16 | 床头右 |
| 2 | GPIO6 | GPIO17 | 床尾左 |
| 3 | GPIO7 | GPIO18 | 床尾右 |

- 四只传感器都是**全桥四线**（E+/E-/S+/S-），每只单独接一片 HX711，不要并联；并联后只能得到总重，失去重心。
- HX711 的 `RATE` 引脚接高电平为 80 SPS，接低为 10 SPS。默认按 80 SPS 编译；如果接低，请把 `CONFIG_BED_SAMPLE_RATE_SPS` 改成 10。
- 床脚必须垂直压在传感器中心，加刚性垫板和定位销；床被抬高后不能晃，老人上下床的安全优先于精度。
- 地面要平、硬，不要直接放在软地毯上。

坐标原点在**床头左角**，x 向右（床宽），y 向床尾（床长），单位 cm。

## 标定

首次刷机时床必须为空，固件会自动做 2 秒去皮。之后按下面顺序操作：

1. **去皮 `tare`**：清空床面，在功能页点 `tare`。2 秒内不要碰床。
2. **四点标定 `calibrate`**：准备一个已知砝码（默认 20 kg，改 `CONFIG_BED_CAL_WEIGHT_KG`），点 `calibrate` 后按页面提示，依次放到 1→2→3→4 号角。每个角要满足：
   - 该角读数 ≥ 砝码的 50%；
   - 其他三个角 ≤ 砝码的 20%；
   - 稳定保持 1.5 秒。
   放错位置会停在当前步骤，重新放好即可。完成后固件把四个 `scale` 写进 NVS。
3. **复位 `reset`**：恢复标称灵敏度并重新去皮。只在换床/换传感器后使用。

标定和去皮都必须**空床**。床上有人时按 `tare`，人的重量会被当成皮重。

调试时也可以直接发 `{"command":"cal","ch":1,"kg":20}`，按当前读数给指定通道定标；正式使用建议走上面的向导。

## 数据格式

固件每 500 ms 发一帧，事件发生时立刻补发一帧：

```json
{
  "v": 1, "w": 62.3, "x": 41.2, "y": 73.5,
  "present": true, "state": "in", "mov": 0.18,
  "event": "turn", "evt": 7,
  "in_ms": 123456, "out_ms": 0,
  "cal": "idle", "fault": 0,
  "bw": 150, "bl": 200, "em": 20, "cw": 20,
  "ch": [15.2, 15.1, 16.0, 16.0], "t": 1234567
}
```

| 字段 | 含义 |
|---|---|
| `w` | 总重量 kg（已去皮） |
| `x` / `y` | 重心 cm；无人时为 -1 |
| `present` | 是否在床 |
| `state` | `out` / `in` / `edge` |
| `mov` | 最近窗口的重量 RMS 波动，kg |
| `event` | 本帧事件：`enter` `exit` `turn` `sit` `edge` `no_return` `none` |
| `evt` | 事件序号，只在事件时递增 |
| `in_ms` / `out_ms` | 本次在床 / 已离床时长 ms |
| `cal` | `idle` / `ch1`..`ch4` / `done` / `error` |
| `fault` | 1 表示有通道读数异常 |
| `bw` / `bl` | 床宽 / 床长 cm |
| `em` / `cw` | 边缘区宽度 / 标定砝码 kg |
| `ch` | 四角重量 kg，仅诊断 |
| `t` | 固件 uptime ms |

主机插件额外加 `received_at`（Pi 本地毫秒）和 `night`（22:00–06:00）。

## 事件逻辑

- **enter / exit**：总重超过 8 kg 持续 800 ms 进床；低于 4 kg 持续 1500 ms 离床。迟滞防翻身误判。
- **turn**：重心相对上次稳定位置横向或纵向跳变 ≥ 6 cm，并保持 600 ms。
- **sit**：头脚方向重心移动 ≥ 15 cm、横向移动 < 6 cm，并保持 600 ms。这是启发式，需要按老人实际动作调 `CONFIG_BED_SIT_CM`。
- **edge**：重心进入任一边 20 cm 区域并保持 1 s。
- **no_return**：离床超过设定分钟数；默认 0（关闭），夜间告警建议由 Pi 页面结合 `night` 判断。

参数都在 `firmware/main/Kconfig.projbuild`。不要用一个人的标定参数套所有人。

## 精度预期

| 项目 | 预期 |
|---|---|
| 在床/离床 | 接近 100%，秒级 |
| 重量分辨率 | 理论克级，受传感器非线性/蠕变限制约 10–30 g |
| 重心 | 2–5 cm（取决于四角标定和床架刚性） |
| 翻身/坐起 | 事件级可用，需个人基线微调 |
| 呼吸 | 未实现；10/80 SPS 可以尝试，但本模块不承诺 |
| 心率 BCG | 不做，HX711 采样率和噪声不够 |

## 构建

主机插件（x86_64 本地验证）：

```sh
cd module-devkit
source ../pi_terminal/scripts/env.sh
cmake -S examples/bed-sensor -B /tmp/bed-host \
  -DMODULE_SDK_DIR="$PWD/sdk" -DMODULE_TESTING=ON
cmake --build /tmp/bed-host --parallel 4
ctest --test-dir /tmp/bed-host --output-on-failure
```

纯逻辑离线测试：

```sh
gcc -std=c11 -Wall -Wextra \
  -I examples/bed-sensor/firmware/components/bed_logic/include \
  examples/bed-sensor/tests/bed_logic_test.c \
  examples/bed-sensor/firmware/components/bed_logic/bed_logic.c \
  -lm -o /tmp/bed_logic_test && /tmp/bed_logic_test
```

固件（需要 ESP-IDF 5.5.x）：

```sh
cd module-devkit
export MODULE_SDK_DIR="$PWD/sdk"
source ~/esp-idf-5.5.4/export.sh
# 正常流程由 firmware-build.sh 提供已签名嵌入包：
export PI_MODULE_SDKCONFIG=/secure/sdkconfig
export PI_MODULE_PACKAGE_DIR=/path/to/embedded-package
./firmware-build.sh examples/bed-sensor BLE /tmp/bed-fw
```

只做编译检查、没有签名包时，可临时放两个空文件：

```sh
: > examples/bed-sensor/firmware/embedded_package.json
: > examples/bed-sensor/firmware/embedded_package.tar.zst
idf.py -C examples/bed-sensor/firmware -B /tmp/bed-fw build
```

这两个文件已被 `.gitignore` 忽略，正式包必须由平台私钥签名。

## 接入 Pi

- 模块 ID 是 **84**。Pi 的 profile 必须已 provision 这个 ID；现有实测智能盆栽是 80，不能直接共用。
- 默认 BLE。要出 LAN 包，把 `manifest.json` 的 `permissions` 改成 `transport.hotspot_lan`，再用 `firmware-build.sh ... LAN`。
- 改 ID 要同时改 `manifest.json`、`firmware/main/main.c` 的 `MODULE_ID`、`firmware/main/Kconfig.projbuild` 的实例名/BLE 名，并同步 Pi 配置。

## 已验证 / 未验证

已验证：

- `bed_logic` 的主机 assert 测试（进床、离床、翻身、坐起、边缘、未返回、无效数据）；
- 主机插件 x86_64 编译与 `bed_sample_forwarding` 测试；
- `module_devkit.py validate` 通过；
- ESP-IDF 5.5.4 固件编译通过（app 约 1.05 MB，2 MB 分区）。

未验证：

- 真实床架、四只传感器、HX711 的现场读数与标定；
- aarch64 插件（本机没有 aarch64 交叉编译器）；
- 与当前 Pi 的 `session_ready`：本仓库公开 SDK 的数据面是明文 TCP/无 HMAC，而 Pi 业务面要求 TLS 指纹 pin 或 BLE 挑战应答；按 `module-devkit/README.md` 的说明，本固件会停在 `session_ready` 之前，需平台补安全数据面；
- 老人个体动作阈值。

## 安全

- 床被抬高 5–10 cm，必须做刚性、防滑、防侧翻的底座。床晃是摔倒风险，不能为了走线牺牲稳定性。
- 单角可能超过 50 kg，先按实际体重和床重算一遍。
- 夜间告警只是提醒，不能替代护理和跌倒防护。
