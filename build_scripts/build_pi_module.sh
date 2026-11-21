#!/usr/bin/env bash
set -euo pipefail

# 兼容旧入口：等价于 build_module.sh smart-planter [BUILD_DIR]。
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -gt 0 && -n "$1" ]]; then export ESP_BUILD_DIR="$1"; shift; fi
exec "$DIR/build_module.sh" smart-planter "$@"
