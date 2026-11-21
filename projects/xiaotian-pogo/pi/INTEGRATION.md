# 将 QML 接到你们的树莓派终端

此基线有两层可用入口：`qml/ModulePage.qml` 是可嵌入的页面；`IRController` + `worker.py` 是对真实红外模块的接收与控制适配器。`main.cpp` 只是独立启动器。不要把启动器演示模式当作实际模块接入。

## 先单独跑通

需要 Qt 6.4 或以上、QtQuick/Controls/Layouts、Python3。Windows 已用 Qt 6.10.1/MinGW 构建验证；树莓派本机需按自己的系统和 Qt 版本编译，不要把 Windows exe 拷到树莓派运行。

Debian/Raspberry Pi OS Bookworm 的依赖示例（先检查你们已有 Qt，避免替换现有环境）：

```bash
sudo apt install cmake ninja-build g++ qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
  qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
  fonts-noto-cjk python3-serial
cmake -S pi -B pi/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build pi/build
bash pi/run-pi.sh --demo
```

如果系统只有 Qt5，不要直接替换终端现有 Qt5，先独立部署此 Qt6 基线，或由软件同事把页面适配为 Qt5；本轮未验证 Qt5。

真机 USB：

```bash
bash pi/run-pi.sh --serial /dev/ttyUSB0
```

串口名称以设备枚举为准，需要该用户有串口权限。关闭串口助手。USB 方式用来先验证数据和界面，不等于 Wi-Fi 已联调。

Wi-Fi：先按根目录交接手册配置热点，导出模块自己的配对文件，再启动：

```bash
bash pi/run-pi.sh --device .private/device.json --host 实际模块IP
```

Windows 可在本机工作区运行 `pi/run-windows.ps1 -Demo` 或 `-Port COM23`。当前 Windows 程序默认在 `S:\esp\xiaotian-pogo-panel`；这是本机环境路径，换电脑先用 build-windows.ps1 配置自己的 Qt。

## 并入原终端

1. 将 `controller.cpp/.h` 加入终端 CMake，链接 Qt6 Core/Gui/Qml/Quick/QuickControls2，打开 AUTOMOC。
2. 在终端创建 `IRController(false)`，设置与模块配对的 JSON 路径，`start(python, worker.py, {"--device", path, "--host", ip})`。路径必须指向本基线 worker.py；它会相对定位 `../tools/node_client.py`，交付目录关系不要打散。
3. 用 `Loader` 加载本页，`onLoaded: item.backend = infraredController`。不要只塞 sessionModel 就以为按钮已有后台；sessionModel 入口仅用于数据展示，当前状态在线与操作需 backend。
4. 只读页面数据使用 backend.data；其中 `pogo.wired` 只决定触点标识，`online` 决定实时数据是否有效。超时灰色，不能继续展示绿色为当前安全状态。
5. 终端真实 NFC/账号认证成功后调用 `setAuthenticatedUser(opaqueUserId)`。退出时调用空字符串；换人必须先退出旧用户。UI 的“开始个人记录”在访客时禁用；独立真机启动器没有假登录按钮。
6. QML 的模拟登录/模拟遮挡按钮仅在显式 `--demo` 中出现，模拟过程不接硬件、不写个人事件文件。
7. 后台工作单线程拥有记录会话；不要从另一个进程同时对同一设备创建个人记录。事件回调在 Pi 按原用户写入独立 JSONL 文件。后续接你们云接口时改 `worker.Controller.command` 中的 consume，保持原用户绑定，不能用“上传时当前登录人”重标旧数据。

`IRController::setAuthenticatedUser` 是可信终端注入接口，**不是模块自行认人，也不是账号认证实现**。只允许可信本地宿主调用；pogo 识别和持有模块 token 都不能代替用户登录。

## pogo 和现有设备发现

- 红外板 UART 握手类型为 XIAOTIAN，LinkIt 产品帧 ID 0x51（十进制81）。
- 查到的旧桥板主程序把 PBR1 产品 ID 固定成环境模块配置值。仅加模块端握手不足以让旧终端区分产品。根目录 `bridge-adapter/` 提供针对 20261030 快照的候选与差异，**未刷桥板**。
- 应用候选后 attach 的 module_instance 为 `xiaotian-<模块MAC>`，module_id=81，module_config 加 `business_adapter=xiaotian_https_v2`、https_port=8443、package_available=false。
- 终端看到此 profile，应路由到本 HTTPS 接收器，**不要发起旧 SDK 的 TCP:4580 session_open/package_get**。legacy transport_mode/package_transport 字段只是让旧桥板接收配置帧的兼容外壳，不代表当前固件实现旧 SDK 数据协议或软件包下载。
- 收到 detach 只更新“触点分离”，不要销毁这个已登记的无线设备、停用采样、退出当前用户或停止网络服务。真正无线离线由 HTTPS 查询超时判断；用户停用由 disable 确认。
- 不要给所有模块统一忽略 detach。这个策略只适用于 module_id81 / xiaotian profile，其他模块保持原终端策略。
- 此基线不自动从 IP/MAC 找 DHCP 地址。用 DHCP 保留或终端登记 IP；不要把桥板固定的 pogo-device-test 字符串拿来作为所有设备实例 ID。

桥板候选仍需在你们当前源码上复核、编译、实板验证；可能与你们后续版本不同。保持电量、NFC、PBR1 安全和现有模块功能，不要整包回退成旧快照。候选中的 package_available=false 应由终端识别为“本机安装界面”，不能据此执行不受信任的未验签包。

## 当前界面能力和边界

栏杆可以拖动、旋转、改名与修改示意长度，设置通过 QSettings 按 device_id 分开保存。固定底图是实验室示意，不是测绘地图；箭头 N 是人工设定的示意北向，不来自磁力计。图上无人体轨迹，不识别人经过的方向或人数。

目前展示一组红外设备。多模块地图、真实场地图导入、Cesium 三维定位、自动软件包下载/签名，以及云端业务接口都留给后续版本，不把它们列为已完成。
