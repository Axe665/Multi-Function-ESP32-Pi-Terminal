# 桥板固件 s3_pogo_host（2026-11-21 构建）

> 本目录是官方发布包的归档：bin/flash.sh 可直接用于实机回滚。
> 对应源码已合入 `esp/bridge/S3_PiBridge_LinkIt_Host/main/main.c`，重新编译以源码为准。

ESP32-S3 桥板固件，用于 Pi ↔ LinkIt 模块之间的转发。

## 本版改动：桥板变成通用透传层

这一版把固件里残留的**产品专用分支全部删掉**，以后接新模块不需要再改桥板：

- 删除 `s_xiaotian_profile` 分支——原来它把 `business_adapter` 写死成 `xiaotian_https_v2`、
  端口写死 8443、`module_id` 兜底写死 81；
- 删除 `valid_xiaotian_instance()` 的 `xiaotian-` 前缀硬校验，换成通用的字符集校验
  （只防 JSON 注入，不限定产品命名）；
- `business_adapter` / `https_port` / `module_instance` / `package_available` 改为
  **原样透传**，只校验类型、长度、字符集，不校验取值；
- `module_id` 取模块在 LNK1 帧里自报的值，没自报才回退编译期配置；
- 补上 `package_transport: "http"`（Pi 侧认、桥板此前不认），并去掉桥板自加的
  业务 lane × 包通道组合限制——Pi 侧明确允许 2×3 六种组合全部合法。

验证：固件里 `xiaotian` 字符串出现 0 次（旧固件有）。

## 硬件与烧录参数

| 项 | 值 |
| --- | --- |
| 芯片 | ESP32-S3 |
| Flash | 16 MB |
| Flash 模式 | `dio` |
| Flash 频率 | 80 MHz |
| 分区表偏移 | `0x8000` |
| 应用偏移 | `0x10000` |
| 波特率 | 460800 |

## 烧录

### 方式一：一键脚本（推荐）

```sh
./flash.sh                 # 自动找端口，只写三块区域，保留 NVS
./flash.sh /dev/ttyACM0    # 指定端口
./flash.sh --erase         # 先整片擦除再烧（NVS 里的配对信息会丢）
```

需要 `esptool`：`pip install esptool`，或在 ESP-IDF 环境里跑。

### 方式二：单文件（只烧一个镜像）

```sh
esptool.py --chip esp32s3 -p <PORT> -b 460800 \
  --before default_reset --after hard_reset \
  write_flash --flash_mode dio --flash_size 16MB --flash_freq 80m \
  0x0 merged-flash.bin
```

`merged-flash.bin` 已把 bootloader(0x0)、分区表(0x8000)、应用(0x10000) 合成到 0x0 起始，
不会碰 NVS 区域。

### 方式三：分文件

```sh
esptool.py --chip esp32s3 -p <PORT> -b 460800 \
  --before default_reset --after hard_reset \
  write_flash --flash_mode dio --flash_size 16MB --flash_freq 80m \
  0x0 bootloader.bin 0x8000 partition-table.bin 0x10000 s3_pogo_host.bin
```

## 烧完怎么确认

串口日志（115200）里应看到：

```
I (xxx) POGO_HOST: module transport config accepted mode=... package=... pin=... adapter=... port=... instance=...
I (xxx) POGO_HOST: link event attach module=0x51 instance=xiaotian-xxxxxxxxxxxx len=... authenticated=...
```

- `adapter=` / `port=` / `instance=` 为 `(none)` 表示该模块没自报这几个字段，属正常
  （老模块如智能花盘不会报）；
- `module=` 应是模块自报的 ID（花盘 0x50、啸天 0x51），不再是写死的 81。

## 回滚

烧录前建议先整片备份：

```sh
esptool.py --chip esp32s3 -p <PORT> -b 460800 read_flash 0 0x1000000 bridge-backup.bin
```

需要回滚时把备份整片写回：

```sh
esptool.py --chip esp32s3 -p <PORT> -b 460800 write_flash 0x0 bridge-backup.bin
```

## 注意

- 本包**只含桥板固件**，不含模块固件、不含 Pi 端程序。
- 桥板通用化后，模块侧只要在 LNK1 帧自报 `module_id`、并用 `POGO_CMD_MODULE_CONFIG`(0x03)
  上报合法的 `module-transport-v1`，就不用再动桥板。字段约定见
  `esp/bridge/S3_PiBridge_LinkIt_Host/README.md` 的「模块身份与配置透传」。
- 构建环境：ESP-IDF v5.5（不是 5.4，5.4 缺 `wifi_tx_info_t` 会编译失败）。

## 文件校验

见 `SHA256SUMS`：

```sh
sha256sum -c SHA256SUMS
```
