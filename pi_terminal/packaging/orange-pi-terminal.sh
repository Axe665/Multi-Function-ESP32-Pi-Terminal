#!/bin/sh
# Wrapper：deb 把运行时放在 /opt，二进制不在系统库搜索路径里。
PREFIX=/opt/orange-pi-terminal
export LD_LIBRARY_PATH="$PREFIX/lib/orange-pi-terminal:$PREFIX/lib:$PREFIX/qt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$PREFIX/qt/plugins"
export QML2_IMPORT_PATH="$PREFIX/qt/qml"
export QT_QPA_PLATFORM_PLUGIN_PATH="$PREFIX/qt/plugins/platforms"
export QTWEBENGINEPROCESS_PATH="$PREFIX/qt/libexec/QtWebEngineProcess"
exec "$PREFIX/bin/orange_pi_terminal" "$@"
