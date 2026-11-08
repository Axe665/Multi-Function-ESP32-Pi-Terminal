#!/bin/sh
# GitHub 单文件上限 100MB，deb 被切成 90MB 分片；这里拼回并校验。
set -e
cd "$(dirname "$0")"
for base in orange-pi-terminal_1.0.0_arm64.deb orange-pi-terminal-dev_1.0.0_arm64.deb \
            orange-pi-terminal_1.0.0_amd64.deb orange-pi-terminal-dev_1.0.0_amd64.deb; do
    [ -e "$base.part00" ] || continue
    cat "$base".part* > "../$base"
    echo "生成 ../$base（$(du -h "../$base" | cut -f1)）"
done
cd .. && sha256sum -c dist/SHA256SUMS
