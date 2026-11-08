#!/usr/bin/env bash
# 拉取 GStreamer **运行时插件**（解码器/输出/URI 源）到 third_party/gst/<arch>/plugins/。
#
# 与 fetch_gst_headers.sh 的分工：
#   fetch_gst_headers.sh  → 开发期头文件 + 链接期 .so（按宿主架构）
#   fetch_gst_plugins.sh  → 运行期插件 .so（可按目标架构交叉下载，不需要 root）
#
# 为什么需要：Qt Multimedia 的 gstreamer 后端只带 libgstmediaplugin，
# playbin / mp3 / hls 等 element 全在 gstreamer1.0-plugins-* 里。目标机
# 缺这些包时表现为 “no element playbin” 或音乐/电视无法解码。
#
# 用法：
#   ./tools/fetch_gst_plugins.sh                     # 宿主架构
#   ./tools/fetch_gst_plugins.sh --arch arm64        # 交叉下载（Debian/Ubuntu 均可）
#   ./tools/fetch_gst_plugins.sh --arch arm64 --bundle /tmp/gst-arm64.tar.zst
#
# 产物：
#   third_party/gst/<arch>/plugins/gstreamer-1.0/*.so   插件
#   third_party/gst/<arch>/plugins/lib/*.so*            插件的私有依赖
#   third_party/gst/<arch>/plugins/MANIFEST.json        包名/版本/文件清单
#
# 目标机使用：
#   GST_PLUGIN_PATH=<repo>/third_party/gst/<arch>/plugins/gstreamer-1.0 \
#   LD_LIBRARY_PATH=<repo>/third_party/gst/<arch>/plugins/lib \
#   gst-inspect-1.0 playbin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(dpkg --print-architecture)"
BUNDLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:?--arch 需要值}"; shift 2 ;;
        --bundle) BUNDLE="${2:?--bundle 需要路径}"; shift 2 ;;
        -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# Debian 架构名 → 软件包架构名
case "$ARCH" in
    x86_64) DEB_ARCH=amd64 ;;
    aarch64|arm64) DEB_ARCH=arm64 ;;
    armv7l) DEB_ARCH=armhf ;;
    *) DEB_ARCH="$ARCH" ;;
esac

# 只选运行期需要的包：容器/解码/协议/音频输出。
# libav 提供 avdec_* 兜底解码，ugly 提供 mp3(mpg123)，good 提供 id3demux/audioconvert。
PKGS=(
    gstreamer1.0-plugins-base
    gstreamer1.0-plugins-good
    gstreamer1.0-plugins-bad
    gstreamer1.0-plugins-ugly
    gstreamer1.0-libav
    gstreamer1.0-alsa
)

DEST="$ROOT/third_party/gst/$ARCH/plugins"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== 目标架构: $ARCH (deb: $DEB_ARCH) =="
if [[ "$DEB_ARCH" == "$(dpkg --print-architecture)" ]]; then
    echo "== 宿主架构：直接 apt-get download =="
    ( cd "$TMP" && apt-get download "${PKGS[@]}" )
else
    echo "== 交叉架构：用临时 APT 目录下载，不改动系统 dpkg =="
    mkdir -p "$TMP/apt/lists/partial" "$TMP/apt/cache/archives/partial"
    cat > "$TMP/apt/sources.list" <<EOF
deb [arch=$DEB_ARCH] http://deb.debian.org/debian bookworm main
deb [arch=$DEB_ARCH] http://deb.debian.org/debian bookworm-updates main
deb [arch=$DEB_ARCH] http://security.debian.org/debian-security bookworm-security main
EOF
    # 宿主可能是 Ubuntu：它只有 ubuntu-keyring，验不了 Debian 仓库。
    # 显式指向 debian-archive-keyring；没有就明确报错，不静默降级为 trusted=yes。
    DEB_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
    if [[ ! -f "$DEB_KEYRING" ]]; then
        echo "缺少 $DEB_KEYRING；先装 debian-archive-keyring（apt-get install debian-archive-keyring）" >&2
        exit 1
    fi
    APT_OPTS=(
        -o Dir::Etc::sourcelist="$TMP/apt/sources.list"
        -o Dir::Etc::sourceparts="-"
        -o Dir::Etc::trusted="$DEB_KEYRING"
        -o Dir::Etc::trustedparts="-"
        -o Dir::State::lists="$TMP/apt/lists"
        -o Dir::Cache="$TMP/apt/cache"
        -o APT::Architecture="$DEB_ARCH"
        -o APT::Architectures::="$DEB_ARCH"
        -o Acquire::Languages=none
    )
    apt-get "${APT_OPTS[@]}" update -qq
    ( cd "$TMP" && apt-get "${APT_OPTS[@]}" download "${PKGS[@]}" )
fi

echo "== 解包 =="
mkdir -p "$TMP/ext"
for deb in "$TMP"/*.deb; do
    [[ -e "$deb" ]] || { echo "没有下载到 .deb" >&2; exit 1; }
    dpkg-deb -x "$deb" "$TMP/ext"
done

rm -rf "$DEST"
mkdir -p "$DEST/gstreamer-1.0" "$DEST/lib"

# 1) 插件本体：只取 gstreamer-1.0 目录下的 .so
find "$TMP/ext/usr/lib" -path '*/gstreamer-1.0/*.so' -type f -exec cp -a {} "$DEST/gstreamer-1.0/" \;

# 2) 插件的私有依赖：从各包的 shlibs 里挑出非基础库，按 soname 复制实体文件。
#    基础库（glib/gobject/gstreamer 本体）交给系统，避免与系统版本打架。
BASE_RE='^(libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0|libgstreamer-1\.0|libgstbase-1\.0|libgstaudio-1\.0|libgstvideo-1\.0|libgsttag-1\.0|libgstpbutils-1\.0|libgstapp-1\.0|libgstallocators-1\.0|libgstriff-1\.0|libgstgl-1\.0|libgstnet-1\.0|libgstsdp-1\.0|libgstrtsp-1\.0|libgstrtp-1\.0|libgstfft-1\.0|libgstcontroller-1\.0|libgstcheck-1\.0|ld-linux.*)\.so'
while IFS= read -r lib; do
    base="$(basename "$lib")"
    [[ "$base" =~ $BASE_RE ]] && continue
    [[ -e "$DEST/lib/$base" ]] && continue
    cp -aL "$lib" "$DEST/lib/" 2>/dev/null || true
done < <(find "$TMP/ext/usr/lib" -maxdepth 2 \( -type f -o -type l \) -name 'lib*.so.*' | sort -u)

# 3) 清单：包名/版本 + 文件清单，便于下一台机器核对
python3 - "$TMP" "$DEST" "$DEB_ARCH" <<'PY'
import json, os, subprocess, sys
tmp, dest, arch = sys.argv[1:4]
packages = {}
for name in sorted(os.listdir(tmp)):
    if not name.endswith(".deb"):
        continue
    path = os.path.join(tmp, name)
    field = subprocess.run(["dpkg-deb", "-f", path, "Package", "Version"],
                           capture_output=True, text=True).stdout.split()
    if len(field) >= 4:
        packages[field[1]] = field[3]
plug = sorted(os.listdir(os.path.join(dest, "gstreamer-1.0")))
libs = sorted(os.listdir(os.path.join(dest, "lib")))
json.dump({"arch": arch, "packages": packages, "plugins": plug, "libs": libs},
          open(os.path.join(dest, "MANIFEST.json"), "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"插件 {len(plug)} 个，私有依赖 {len(libs)} 个")
PY

echo "完成: $DEST（$(du -sh "$DEST" | cut -f1)）"
echo "目标机自检："
echo "  GST_PLUGIN_PATH=$DEST/gstreamer-1.0 LD_LIBRARY_PATH=$DEST/lib gst-inspect-1.0 playbin"

if [[ -n "$BUNDLE" ]]; then
    echo "== 打离线包: $BUNDLE =="
    tar --zstd -cf "$BUNDLE" -C "$ROOT/third_party/gst/$ARCH" plugins
    ls -lh "$BUNDLE"
fi
