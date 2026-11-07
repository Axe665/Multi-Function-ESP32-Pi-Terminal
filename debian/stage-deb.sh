#!/bin/bash
# 把 cmake --install 的树拆成两个 deb 目录：运行时 + dev。
set -euo pipefail
ROOT=$1; TMP=$2; PREFIX=$3
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
PKG="$ROOT/debian/orange-pi-terminal"
DEV="$ROOT/debian/orange-pi-terminal-dev"
SDKROOT="$ROOT/toolchain/qt-6.5.3-aarch64"
QT_CACHE="$ROOT/debian/qt-runtime"

install -d "$PKG/usr/bin" "$PKG/usr/lib/systemd/system" "$PKG/usr/lib/systemd/user" \
          "$PKG/usr/share/polkit-1/actions" "$PKG/etc/polkit-1/rules.d" \
          "$PKG/usr/share/applications" "$DEV/usr/include" "$DEV/usr/lib/"

# 1) 运行时树
install -d "$PKG$PREFIX"
cp -a "$TMP$PREFIX/." "$PKG$PREFIX/"

# 2) dev 拆分：头文件 / CMake / 静态库
if [ -d "$PKG$PREFIX/include/orange-pi-terminal" ]; then
    install -d "$DEV/usr/include/orange-pi-terminal"
    mv "$PKG$PREFIX/include/orange-pi-terminal"/* "$DEV/usr/include/orange-pi-terminal/"
    rmdir "$PKG$PREFIX/include/orange-pi-terminal" "$PKG$PREFIX/include" 2>/dev/null || true
fi
if [ -d "$PKG$PREFIX/lib/cmake/OrangePiModuleSDK" ]; then
    install -d "$DEV/usr/lib/cmake"
    mv "$PKG$PREFIX/lib/cmake/OrangePiModuleSDK" "$DEV/usr/lib/cmake/"
    rmdir "$PKG$PREFIX/lib/cmake" 2>/dev/null || true
fi
for f in "$PKG$PREFIX"/lib/libpi_module_sdk*; do
    [ -e "$f" ] && mv "$f" "$DEV/usr/lib/$MULTIARCH/"
done

# 3) Qt 运行时：解包一次并缓存
if [ -n "${QT_BUNDLE_SRC:-}" ] && [ -d "$QT_BUNDLE_SRC" ]; then
    QT_SRC="$QT_BUNDLE_SRC"
else
    QT_SRC="$(find "$QT_CACHE" -maxdepth 3 -type d -path '*/opt/qt653-arm64' 2>/dev/null | head -1 || true)"
    if [ -z "$QT_SRC" ]; then
        install -d "$QT_CACHE"
        echo "解包 Qt 运行时（首次约 1 分钟）..."
        cat "$SDKROOT"/artifacts/orpi-qt653-pi3.tar.zst.part* | zstd -d | tar -x -C "$QT_CACHE"
        QT_SRC="$(find "$QT_CACHE" -maxdepth 3 -type d -path '*/opt/qt653-arm64' 2>/dev/null | head -1 || true)"
    fi
fi
[ -n "$QT_SRC" ] || { echo "Qt 运行时解包后找不到 opt/qt653-arm64" >&2; exit 1; }
cp -a "$QT_SRC" "$PKG$PREFIX/qt"
# 裁剪：源码/开发文件/工具链不进运行时包
rm -rf "$PKG$PREFIX/qt/include" "$PKG$PREFIX/qt/lib/cmake" "$PKG$PREFIX/qt/lib/pkgconfig" \
       "$PKG$PREFIX/qt/bin" "$PKG$PREFIX/qt/mkspecs" "$PKG$PREFIX/qt/lib/"*.a \
       "$PKG$PREFIX/qt/lib/"*.prl "$PKG$PREFIX/qt/doc"
# 完整安装前缀（amd64 用 /opt/Qt）里的构建工具一律不带，只留 WebEngine 子进程
if [ -d "$PKG$PREFIX/qt/libexec" ]; then
    find "$PKG$PREFIX/qt/libexec" -mindepth 1 -maxdepth 1 ! -name 'QtWebEngineProcess' -exec rm -rf {} + 2>/dev/null || true
fi
find "$PKG$PREFIX/qt" -name '*.debug' -delete 2>/dev/null || true

# 3.5) 完整 Qt 里带上但运行用不到、或依赖缺失的模块
rm -rf "$PKG$PREFIX/qt/qml/QtQuick3D" "$PKG$PREFIX/qt/qml/QtWayland" \
       "$PKG$PREFIX/qt/qml/Qt/test" "$PKG$PREFIX/qt/qml/QtTest" "$PKG$PREFIX/qt/plugins/designer"
find "$PKG$PREFIX/qt/lib" -maxdepth 1 \( -name 'libQt6Quick3D*' -o -name 'libQt6Designer*' \
       -o -name 'libQt6Help*' -o -name 'libQt6LanguageServer*' -o -name 'libQt6UiTools*' \
       -o -name 'libQt6Test*' -o -name 'libQt6QuickTest*' \) -delete 2>/dev/null || true

# 3.6) 仓库内置的开发依赖（SQLCipher 不在 Debian 主源，必须随包自带）
if [ -d "$ROOT/third_party/deps/lib/x86_64-linux-gnu" ]; then
    for lib in "$ROOT"/third_party/deps/lib/x86_64-linux-gnu/libsqlcipher*.so* \
               "$ROOT"/third_party/deps/lib/x86_64-linux-gnu/libmbed*.so*; do
        [ -e "$lib" ] && cp -a "$lib" "$PKG$PREFIX/lib/orange-pi-terminal/"
    done
fi

# 4) RUNPATH 指向包内路径
elf_fix() { file -b "$1" 2>/dev/null | grep -q '^ELF' && patchelf --set-rpath "$2" "$1" || true; }
for f in "$PKG$PREFIX"/bin/*; do [ -f "$f" ] && elf_fix "$f" "\$ORIGIN/../lib/orange-pi-terminal:$PREFIX/lib/orange-pi-terminal:$PREFIX/qt/lib"; done
for f in "$PKG$PREFIX"/lib/*.so*; do [ -f "$f" ] && [ ! -L "$f" ] && elf_fix "$f" "\$ORIGIN:$PREFIX/qt/lib"; done
for f in "$PKG$PREFIX"/libexec/orange-pi-terminal/module_worker "$PKG$PREFIX"/libexec/orange-pi-terminal/net-policy-helper; do
    [ -f "$f" ] && elf_fix "$f" "\$ORIGIN/../../lib:$PREFIX/qt/lib"
done

# 5) FHS 文件：wrapper / systemd / polkit / desktop
install -m755 "$ROOT/pi_terminal/packaging/orange-pi-terminal.sh" "$PKG/usr/bin/orange-pi-terminal"
for u in orange-pi-worker@.service orange-pi-net-proxy.service orange-pi-file-daemon.service orpi-egress.service; do
    install -m644 "$ROOT/pi_terminal/packaging/$u" "$PKG/usr/lib/systemd/system/$u"
done
install -m644 "$ROOT/pi_terminal/packaging/pi-module-terminal.service" "$PKG/usr/lib/systemd/user/pi-module-terminal.service"
install -m644 "$ROOT/pi_terminal/packaging/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf" \
    "$PKG/usr/lib/systemd/system/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf" 2>/dev/null || {
        install -d "$PKG/usr/lib/systemd/system/orange-pi-net-proxy.service.d"
        install -m644 "$ROOT/pi_terminal/packaging/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf" \
            "$PKG/usr/lib/systemd/system/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf"
    }
install -m644 "$ROOT/pi_terminal/packaging/50-orpi-worker.rules" "$PKG/etc/polkit-1/rules.d/50-orpi-worker.rules"
install -m644 "$ROOT/pi_terminal/packaging/orange-pi-terminal.desktop" "$PKG/usr/share/applications/orange-pi-terminal.desktop"
# 策略模板由 CMake 生成到 PREFIX/share/polkit-1/actions
if [ -d "$PKG$PREFIX/share/polkit-1/actions" ]; then
    cp -a "$PKG$PREFIX/share/polkit-1/actions/." "$PKG/usr/share/polkit-1/actions/"
    rm -rf "$PKG$PREFIX/share/polkit-1"
fi

# 5.4) 安装进来的第三方源码只留运行时资产，去掉 CI/版本控制文件
find "$PKG$PREFIX/share/orange-pi-terminal/source" -name '.github' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PKG$PREFIX/share/orange-pi-terminal" \( -name '.gitignore' -o -name '.gitattributes' -o -name '.gitmodules' \) -delete 2>/dev/null || true

# 5.5) 示例/测试模块不进运行时包（129/130/131 是 test_devices）
if [ -d "$PKG$PREFIX/lib/orange-pi-terminal/modules" ]; then
    for m in 129 130 131; do rm -rf "$PKG$PREFIX/lib/orange-pi-terminal/modules/$m"; done
fi

# 5.6) lintian overrides 随包走（dh_lintian 在我们跳过 dh_install 后不会自动装）
install -d "$PKG/usr/share/lintian/overrides"
install -m644 "$ROOT/debian/orange-pi-terminal.lintian-overrides" "$PKG/usr/share/lintian/overrides/orange-pi-terminal"

# 6) 清掉空目录，避免 dh 报 uninstalled
find "$PKG$PREFIX" -type d -empty -delete 2>/dev/null || true
echo "stage 完成：$(du -sh "$PKG" | cut -f1) 运行时 / $(du -sh "$DEV" | cut -f1) dev"
