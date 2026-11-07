#!/usr/bin/env bash
# Source this file before invoking cmake/ctest or a debugger.
SDK_HOME="${OPI_SDK_HOME:-$HOME/.local/share/orange-pi-terminal-sdk}"
if [[ -d "$SDK_HOME/tools/bin" ]]; then
    export PATH="$SDK_HOME/tools/bin:$PATH"
fi
QT_ROOT="${OPI_QT_ROOT:-$SDK_HOME/qt/6.5.3/gcc_64}"
# 后续构建统一使用作者 SDK；缺 SDK 时明确失败，禁止静默回退到系统 Qt。
if [[ ! -x "$QT_ROOT/bin/qmake" ]]; then
    echo "Orange Pi Terminal: author Qt SDK not found at $QT_ROOT" >&2
    echo "Set OPI_QT_ROOT to the Qt 6.5.3 gcc_64 SDK." >&2
    return 1
fi
export CMAKE_PREFIX_PATH="$QT_ROOT${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$QT_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$QT_ROOT/bin:$PATH"
