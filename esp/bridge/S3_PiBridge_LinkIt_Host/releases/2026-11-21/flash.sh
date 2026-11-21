#!/bin/bash
# 烧录桥板固件（ESP32-S3 / 16MB flash）到 s3_pogo_host 桥板。
#
# 用法：
#   ./flash.sh                 自动找端口，写 bootloader+分区表+应用（保留 NVS）
#   ./flash.sh /dev/ttyACM0    指定端口
#   ./flash.sh --erase         先整片擦除再烧（NVS 里的配对信息会丢）
#
# 默认**不擦除**：桥板的 NVS 里可能有配对/校准数据，整片擦除会一并清掉。
set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ERASE=0
PORT=""
for arg in "$@"; do
    case "$arg" in
        --erase|-e) ERASE=1 ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "未知参数：$arg" >&2; exit 1 ;;
        *)  PORT="$arg" ;;
    esac
done

# 找 esptool：优先当前解释器的模块形式，其次命令行工具。
if python3 -m esptool version >/dev/null 2>&1; then
    ESTOOL=(python3 -m esptool)
elif python3 -m esptool --version >/dev/null 2>&1; then
    ESTOOL=(python3 -m esptool)
elif command -v esptool.py >/dev/null 2>&1; then
    ESTOOL=(esptool.py)
elif command -v esptool >/dev/null 2>&1; then
    ESTOOL=(esptool)
else
    echo "找不到 esptool。装一个：pip install esptool，或先 source ESP-IDF 的 export.sh" >&2
    exit 1
fi

# 没指定端口时自动探测：桥板是 CH343（1a86:55d3），优先按 by-id 命中。
if [ -z "$PORT" ]; then
    for candidate in /dev/serial/by-id/usb-1a86_* /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$candidate" ] && { PORT="$candidate"; break; }
    done
fi
if [ -z "$PORT" ]; then
    echo "找不到串口设备。接上桥板，或显式传端口：./flash.sh /dev/ttyACM0" >&2
    exit 1
fi

echo "端口 : $PORT"
echo "擦除 : $([ "$ERASE" = 1 ] && echo '是（含 NVS）' || echo '否（保留 NVS）')"
echo

if [ "$ERASE" = 1 ]; then
    echo ">> 整片擦除"
    "${ESTOOL[@]}" --chip esp32s3 -p "$PORT" -b 460800 erase_flash
fi

echo ">> 写入固件"
"${ESTOOL[@]}" --chip esp32s3 -p "$PORT" -b 460800 \
    --before default_reset --after hard_reset \
    write_flash --flash_mode dio --flash_size 16MB --flash_freq 80m \
    0x0 bootloader.bin \
    0x8000 partition-table.bin \
    0x10000 s3_pogo_host.bin

echo
echo "完成。用 115200 波特率看串口日志，应出现："
echo '  I (...) POGO_HOST: module transport config accepted mode=... package=... pin=...'
echo '  I (...) POGO_HOST: link event attach module=0x51 instance=... len=... authenticated=...'
