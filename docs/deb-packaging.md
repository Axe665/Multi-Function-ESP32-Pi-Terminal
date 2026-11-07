# DEB 打包

仓库提供标准 `debian/`（debhelper 13），产两个包：

| 包 | 内容 | 谁装 |
|---|---|---|
| `orange-pi-terminal` | 运行时：主程序、`libterminal_*`、`network_proxy`、`kdf_worker`、file-daemon、flite、模块 worker/helper、语音与图标资源、**自带 Qt 6.5.3 运行时**、systemd 单元、polkit、desktop | 目标机 |
| `orange-pi-terminal-dev` | `pi_module_api.h`、`IModulePlugin.h`、`OrangePiModuleSDKConfig.cmake`、`libpi_module_sdk` | 模块开发者 |

## 安装布局

```text
/opt/orange-pi-terminal/
├── bin/            orange_pi_terminal 及配套可执行
├── lib/            libterminal_*.so、其余共享库
├── libexec/        module_worker、net-policy-helper、music-api、arkpets
├── qt/             Qt 6.5.3 运行时（裁剪：去掉 include/lib/cmake/bin/mkspecs）
└── share/          voices、tts、licenses、示例配置

/usr/bin/orange-pi-terminal               wrapper（设 LD_LIBRARY_PATH/QT_PLUGIN_PATH 后 exec）
/usr/lib/systemd/system/                  worker@、net-proxy、file-daemon、egress
/usr/lib/systemd/user/pi-module-terminal.service
/etc/polkit-1/rules.d/50-orpi-worker.rules
/usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy
/usr/share/applications/orange-pi-terminal.desktop
```

## 构建

```sh
# 三件套：sysroot、目标 Qt（dev 树）、host Qt
export ORPI_SYSROOT=/path/to/pi-sysroot
export ORPI_QT_PREFIX=/path/to/qt653-arm64
export ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64
export ORPI_FLITE_ROOT=/path/to/flite-aarch64

dpkg-buildpackage -b -aarm64 -us -uc -d
# 或封装好的：
./build_scripts/build_deb.sh
```

`-d` 跳过 Build-Depends 检查（debhelper 已装；Qt 由 SDK 提供，不进 Build-Depends）。
**注意**：本机交叉编译，必须在 arm64 上验证安装；x86 上只能做 `dpkg-deb -c` 与 `lintian`。

## 校验

```sh
dpkg-deb -c ../orange-pi-terminal_1.0.0_arm64.deb | head
lintian ../orange-pi-terminal_1.0.0_arm64.deb
```

常见 lintian 提示与取舍：

- `embedded-library`：Qt 自带库在 `/opt`，属预期，可 override；
- `no-manual-page`：kiosk 应用无 man page，可 override；
- `package-contains-vcs-control-file`：确认没有 `.git` 打进包（stage 已排除）。

## 升级与卸载

- 升级：直接装新包，`/opt/orange-pi-terminal` 覆盖；用户数据在
  `~/.config/ModularTerminal/` 与 `~/.local/share/ModularTerminal/`，不随包删除；
- 卸载：`apt remove orange-pi-terminal` 会停用用户单元，但保留用户数据；
  `purge` 也不删用户数据（避免误删加密库）。

## 已知限制

- Qt 裁剪按运行所需模块保留（Core/Gui/Quick/Controls2/Network/Sql/WebEngine/
  Multimedia/TextToSpeech/SerialPort/Bluetooth/Svg/Concurrent/DBus/Positioning/
  PrintSupport/OpenGL/Widgets/Qml/QuickWidgets + 常用插件），QML 模块全量保留；
- 实测包体积 **243 MB**，安装后约 600 MB；`lintian` 0 error；
- 尚未做 `multiarch`、`debug symbols` 包；后续可按需加 `-dbgsym`。
