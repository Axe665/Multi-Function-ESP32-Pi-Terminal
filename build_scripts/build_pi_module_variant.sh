#!/usr/bin/env bash
set -euo pipefail

# 兼容旧入口：等价于 build_module_variant.sh smart-planter BLE|LAN BUILD_DIR。
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/build_module_variant.sh" smart-planter "$@"
