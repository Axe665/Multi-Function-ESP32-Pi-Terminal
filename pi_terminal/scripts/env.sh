#!/usr/bin/env bash
# Source this file before invoking cmake/ctest or a debugger.
#
# Qt 版本口径：
#   - 目标机（Pi / Debian 12）基线是 Qt 6.4.2，发行版系统包；
#   - 开发机优先用作者 SDK 的 6.5.3，两条路径都必须 >= 6.4.0。
# 解析顺序：OPI_QT_ROOT > 作者 SDK 6.5.3 > 系统 Qt（qmake6 的 QT_INSTALL_PREFIX）。
# 不允许静默回落到更低版本：低于 6.4.0 直接失败。
SDK_HOME="${OPI_SDK_HOME:-$HOME/.local/share/orange-pi-terminal-sdk}"
if [[ -d "$SDK_HOME/tools/bin" ]]; then
    export PATH="$SDK_HOME/tools/bin:$PATH"
fi

terminal_resolve_qt() {
    if [[ -n "${OPI_QT_ROOT:-}" ]]; then
        printf '%s' "$OPI_QT_ROOT"
        return 0
    fi
    if [[ -x "$SDK_HOME/qt/6.5.3/gcc_64/bin/qmake" ]]; then
        printf '%s' "$SDK_HOME/qt/6.5.3/gcc_64"
        return 0
    fi
    if command -v qmake6 >/dev/null 2>&1; then
        qmake6 -query QT_INSTALL_PREFIX 2>/dev/null
        return 0
    fi
    return 1
}

QT_ROOT="$(terminal_resolve_qt || true)"
unset -f terminal_resolve_qt

QMAKE=""
for candidate in "$QT_ROOT/bin/qmake" "$QT_ROOT/bin/qmake6"; do
    if [[ -x "$candidate" ]]; then
        QMAKE="$candidate"
        break
    fi
done
if [[ -z "$QMAKE" ]] && command -v qmake6 >/dev/null 2>&1; then
    QMAKE="$(command -v qmake6)"
fi

if [[ -z "$QT_ROOT" || -z "$QMAKE" ]]; then
    echo "Orange Pi Terminal: no usable Qt found." >&2
    echo "Set OPI_QT_ROOT to a Qt >= 6.4 installation (target baseline is 6.4.2)." >&2
    return 1
fi

QT_VERSION="$("$QMAKE" -query QT_VERSION 2>/dev/null)"
terminal_version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}
if ! terminal_version_ge "$QT_VERSION" "6.4.0"; then
    echo "Orange Pi Terminal: Qt $QT_VERSION at $QT_ROOT is too old (need >= 6.4.0)." >&2
    return 1
fi
unset -f terminal_version_ge

echo "Orange Pi Terminal: using Qt $QT_VERSION ($QT_ROOT)"
export CMAKE_PREFIX_PATH="$QT_ROOT${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
# 系统 Qt 的库已在 ldconfig 里，只有独立 SDK 需要显式 LD_LIBRARY_PATH。
if [[ "$QT_ROOT" != "/usr" ]]; then
    export LD_LIBRARY_PATH="$QT_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export PATH="$(dirname "$QMAKE"):${PATH}"
