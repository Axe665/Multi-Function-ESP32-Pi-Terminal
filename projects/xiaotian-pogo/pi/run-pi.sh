#!/usr/bin/env bash
set -euo pipefail
panel_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--demo" ]]; then
    exec "$panel_root/build/xiaotian-panel" --demo
fi
exec "$panel_root/build/xiaotian-panel" --python python3 --worker "$panel_root/worker.py" "$@"
