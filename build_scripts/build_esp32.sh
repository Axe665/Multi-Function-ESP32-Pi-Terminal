#!/usr/bin/env bash
set -euo pipefail

# 通用 ESP-IDF 构建入口：接受模块名、桥板工程名，或旧工程别名。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${1:?Usage: build_esp32.sh PROJECT [idf.py arguments ...]}"
shift

case "$PROJECT" in
  S3_PiBridge_LinkIt_Host|bridge)
    ESP_PROJECT="$ROOT/esp/bridge/S3_PiBridge_LinkIt_Host" ;;
  S3_Pi_Module|smart-planter)
    ESP_PROJECT="$ROOT/esp/modules/smart-planter" ;;
  *)
    ESP_PROJECT="$ROOT/esp/modules/$PROJECT"
    [[ -d "$ESP_PROJECT" ]] || { echo "Unknown ESP32 project: $PROJECT" >&2; exit 2; } ;;
esac

command -v idf.py >/dev/null || { echo "ESP-IDF is not exported; source export.sh first." >&2; exit 127; }
BUILD_DIR="${ESP_BUILD_DIR:-$HOME/esp32_workspace/builds/$PROJECT}"
if [[ -n "${ESP_SDKCONFIG:-}" ]]; then
  exec idf.py -C "$ESP_PROJECT" -B "$BUILD_DIR" -DSDKCONFIG="$ESP_SDKCONFIG" build "$@"
fi
exec idf.py -C "$ESP_PROJECT" -B "$BUILD_DIR" build "$@"
