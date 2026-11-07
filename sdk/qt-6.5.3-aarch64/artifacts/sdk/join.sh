#!/bin/bash
# 把分片拼回完整 SDK 包，并按 SHA256SUMS 校验。
set -euo pipefail
cd "$(dirname "$0")"
for base in orpi-qt653-aarch64-dev.tar.zst orpi-host-qt-6.5.3-gcc_64.tar.zst pi-sysroot.tar.zst; do
  [ -f "$base" ] && continue
  cat "$base".part* > "$base"
  echo "已拼接: $base"
done
sha256sum -c SHA256SUMS
