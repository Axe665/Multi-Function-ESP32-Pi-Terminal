#!/usr/bin/env bash
# 补齐仓库不再跟踪的构建产物分卷（放在 GitHub Release 上）。
# 只下载缺失的文件，下完把分卷拼起来跟各目录的 SHA256SUMS 比对，不落盘。
set -euo pipefail

TAG="${ORPI_ARTIFACTS_TAG:-sdk-v1}"
SLUG="${ORPI_ARTIFACTS_REPO:-Axe665/Multi-Function-ESP32-Pi-Terminal}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="https://github.com/$SLUG/releases/download/$TAG"

while read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    [ -f "$ROOT/$f" ] && continue
    mkdir -p "$ROOT/$(dirname "$f")"
    echo "下载 $f"
    curl -fSL --retry 3 -o "$ROOT/$f" "$BASE/$(basename "$f")"
done < "$ROOT/tools/artifacts.manifest"

status=0
for dir in dist toolchain/qt-6.5.3-aarch64/artifacts toolchain/qt-6.5.3-aarch64/artifacts/sdk; do
    [ -f "$ROOT/$dir/SHA256SUMS" ] || continue
    while read -r sum name; do
        set -- "$ROOT/$dir/$name".part*
        [ -e "$1" ] || continue
        got="$(cat "$@" | sha256sum | cut -d' ' -f1)"
        if [ "$got" = "$sum" ]; then
            echo "OK   $dir/$name"
        else
            echo "FAIL $dir/$name（期望 $sum，实得 $got）" >&2
            status=1
        fi
    done < "$ROOT/$dir/SHA256SUMS"
done
exit "$status"
