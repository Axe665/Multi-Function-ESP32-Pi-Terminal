#!/usr/bin/env bash
# 初始化/更新两个 SDK submodule；--bundle DIR 时导出离线 bundle。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--bundle" ]]; then
    OUT="${2:?--bundle 需要输出目录}"
    mkdir -p "$OUT"
    git submodule foreach --quiet 'git bundle create "'"$OUT"'/$(basename "$name").bundle" --all'
    ls -lh "$OUT"
    exit 0
fi

git submodule update --init --recursive
git submodule status
