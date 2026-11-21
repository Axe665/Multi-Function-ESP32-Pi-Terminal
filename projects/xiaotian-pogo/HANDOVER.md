# 啸天红外栏杆：pogo + QML 第一版联调基线

日期：2026-11-18。固件 **2.1.0**，界面基线 **0.1.0**。

## 先看结果与范围

**已烧录到用户确认的新红外板 COM23，MAC `d8:85:ac:d6:1d:c0`，device_id `xiaotian-d885acd61dc0`。**三段写入校验通过。源码、bin、Qt/QML 接收界面和工具均在本包中。

实际完成：USB 读取状态、反复启停、记录结束不停止监测、记录超时、pogo SDK 初始化；以及 **真实 ESP→USB→Python→Qt/QML 的状态和启停链路**。本轮最终保持待机，不记录个人数据。C 状态机、12项 Python 测试、QML 演示检查通过。

尚未验证：用户正在焊接的 pogo 与桥板真实握手/拔插、实际光束遮挡闭环、Wi-Fi 实网、树莓派本机 Qt 编译和页面运行。当前 GPIO4 读到高电平，不能仅凭这个读数证明探头光路正常。

**不是原终端即插即用成品。**界面可先单独启动；旧终端需接本包 HTTPS 适配器。桥板识别补丁提供候选但未烧录、未编译验证，见下文。没有改原桥板或盆栽模块，没有改远端仓库，也没有部署树莓派/云平台。

## 一、焊线只照这个表

两块板断电后接线；端子左右位置取决于你焊的连接器，不按外观看针序。用万用表确认对应 GPIO。

| 桥板 | 红外模块板 | 作用 |
|---|---|---|
| GPIO17 / TX | GPIO18 / RX | 桥→模块 |
| GPIO18 / RX | GPIO17 / TX | 模块→桥 |
| GPIO21 / DET | GPIO21 / DET | 接触检测 |
| GND | GND | 共地 |

**板间不接 5V 或 3.3V。**各自供电，pogo 仅信号。5针连接器若剩一个位置，本版留空。红外光耦 OUT 仍是 GPIO4，输出侧 3.3V/GND 沿用原接线，不接到新 pogo 上。12V 不进 GPIO。USB 与外部5V同时供电需先确认开发板的防倒灌设计。

## 二、现在确定的运行逻辑

```text
pogo 碰接 → UART 身份握手 → 桥板通知树莓派“触点接入”
                         （不携带个人登录凭据）
红外 GPIO4 → 模块 → Wi-Fi HTTPS → 树莓派 QML 场地图
                                     ↓
                           真实用户登录后才允许个人记录
```

- 上电联网，但待机、不采样。软件“连接/启用”才监测。
- **pogo 拔开不停止 Wi-Fi、不改变 enabled、不结束个人会话**；仅更新触点状态。这样模块能拿走摆放。
- 软件“停用”清掉记录并停止采样，网络保留，之后可再启用，不用重新碰 pogo。
- 退出用户只结束个人记录，已启用的监测继续。5秒未收到记录续租则结束并清空模块RAM事件。
- Wi-Fi 断线重连属于通信恢复，不等于用户主动停用。旧个人记录不自动续给下一用户。
- ESP 复位总回待机。当前接收程序存活期间，可按本进程的启用意愿在 ESP 重启后恢复监测；**整个树莓派程序重启后要由正式终端恢复设备设置**，本启动器不持久化 enabled 或用户登录。

## 三、在对方电脑/树莓派先这样跑

解压 ZIP 保持目录结构。在本包根目录执行。Windows 用实际 Python 程序替换 python3，端口以枚举为准。

### 最快先看演示界面（不接硬件）

本机 Windows 已构建，执行：

```powershell
.\pi\run-windows.ps1 -Demo
```

换电脑需自己的 Qt 环境；树莓派编译与依赖见 **`pi/INTEGRATION.md`**：

```bash
cmake -S pi -B pi/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build pi/build
bash pi/run-pi.sh --demo
```

显式 demo 模式显示“演示·非真机”，模拟遮挡、拔触点、登录/退出按钮只在此模式出现，不接串口、不写个人事件。

### 真机先用 USB 看界面

本机 Windows：

```powershell
.\pi\run-windows.ps1 -Port COM23
```

树莓派：

```bash
bash pi/run-pi.sh --serial /dev/ttyUSB0
```

不要同时打开串口助手。先确认设备 ID，再在页面按“连接/启用”，遮挡/移开各保持半秒。通光绿、遮挡红、未启用黄、离线灰。按停用后页面仍可再次启用。灰色未知不能解释成“安全/无人”。

地图支持拖动栏杆、修改名称、角度和示意长度，按设备 ID 保存到树莓派/电脑的 QSettings。当前仅一组，底图是实验室示意。位置、朝向、北向都需人工设置，不是硬件定位或测距。

### 再接 Wi-Fi

旧项目默认热点名 PI_MODULE_NET，密码留空，没有可直接恢复的真实密码。模块目前使用 WPA2 测试 AP，**尚未接你们树莓派热点**。

用 USB 在接收机器重新导出本板配对信息（不需要向他人公开原电脑密钥）：

```bash
python3 tools/node_client.py --serial /dev/ttyUSB0 provision
```

产生 `.private/device.json`，含 token、证书指纹及测试 AP 密码，禁止提交 Git 或公开传送。本包不带它；新板不能复用旧板配对文件。

在私有 `.private/network.json` 填实际 2.4GHz WPA2 热点 SSID 和密码：

```json
{"ssid":"PI_MODULE_NET","password":"实际热点密码，至少8字节"}
```

```bash
python3 tools/node_client.py --serial /dev/ttyUSB0 wifi --config .private/network.json
python3 tools/node_client.py --serial /dev/ttyUSB0 status
python3 tools/node_client.py --serial /dev/ttyUSB0 provision
bash pi/run-pi.sh --device .private/device.json --host 实际模块IP
```

wifi 命令保存并重启；等待获得 IP 再读 status/provision。通过 USB 配对的证书指纹必须先校验，再发 token。连接失败不允许删掉指纹校验图省事。建议树莓派 DHCP 保留地址，本版不自动发现 IP。

## 四、pogo 身份与桥板适配

模块端复用已有 LinkIt SDK，UART1 GPIO17/18、DET21；低速115200握手，运行态2Mbps，产品ID **0x51=81**，握手类型 **XIAOTIAN**。ESP-NOW关闭，SDK不操作Wi-Fi初始化/信道，不抢已有业务无线。pogo任务与采样状态互不调用；桥板移开后模块只等待下一次握手。

USB status 增加：

```json
{"pogo":{"module_id":81,"ready":true,"wired":false,"state":"waiting","rx_frames":0},"business_transport":"xiaotian_https_v2"}
```

ready=true 只说明初始化完成；**wired=true 才表示当时处于握手后的有线态**。本轮实测 wired=false、rx_frames=0，尚未接上桥板验证。断开后状态可能等待协议超时才刷新，不是精确触点测量仪。

旧桥板 `main.c` 将接入的产品编号固定成配置值（原环境模块80），且丢弃扩展元数据。为避免误称已能自动发现，本包附：

- `bridge-adapter/xiaotian-profile.patch`：仅身份路由变更差异；
- `bridge-adapter/main.c.candidate`：基于本地20261030快照的完整候选主文件；
- `bridge-adapter/SOURCE.json`：源文件哈希与来源。

**候选没有编译、没有烧进桥板。**由桥板负责人先对照自己当前版本合并，保留其电量、NFC、安全链路等更新，不能直接拿旧快照替换最新版。接入后红外 attach 应为 module_id81、实例 `xiaotian-<模块MAC>`，含 business_adapter=xiaotian_https_v2、https_port8443、package_available=false。

终端收到此 profile 应走本包 HTTPS 接收器，detach 只更新触点图标，不销毁无线页。仅对该红外 profile 做这个策略，其他模块保持原策略。

**本版没有旧 module_data_service TCP:4580，也没有自动传软件包。**pogo配置中的 fixed_hotspot_lan/package_transport=data 是旧桥板接受的兼容外壳，不代表旧SDK客户端能直接收数据；终端必须按 business_adapter 选择 HTTPS。没有适配桥板时，可先手工登记本设备IP、用独立QML启动器联调。

## 五、登录与软件接入

`pi/INTEGRATION.md` 给出将 `IRController` 和 QML 并入现有 Qt 终端的方式。真实 NFC/账号认证成功后，由可信终端调用 `setAuthenticatedUser(opaqueId)`；退出时传空字符串。模块端只信任配对终端的记录请求，不自行验证人的身份。

独立真机界面默认访客，不提供假登录入口。访客按钮不允许开始个人记录。终端完成认证并注入登录态后，才能开始记录；事件写在 Pi 的每用户 JSONL。它是本地记录基线，**未接真实云上传接口**。云端同事接 worker.py 的 consume 回调，保留用户绑定与权限校验，不能把旧上传队列改成新用户名。

接口仍是 v2 的 HTTPS POST /v1/rpc：status、enable/disable（boot_id+if_revision）、record_start/keepalive/stop、events。记录每秒续租，5秒到期；模块64条RAM环形缓存，不写采集历史到Flash。应用密钥和Wi-Fi配置会留NVS。完整命令定义与 v2 相同，页面适配器已直接调用本包 node_client.py。

本版未做云端鉴权、自动签名软件包、Secure Boot/Flash Encryption、OTA、Cesium三维或多模块地图。图上遮挡也不等于人员入侵判定：单路无法区分断电、断线、未对准、遮挡，不能判方向或人数。

## 六、接收方验收清单

1. 查询 v2.1.0 和本板 ID，页面USB正常。明确 demo 与真机模式。
2. 焊接后的 pogo 碰接：桥板日志看到 XIAOTIAN/模块帧0x51；模块status wired=true。
3. 先启用，拔开 pogo，再通过Wi-Fi遮挡/恢复，监测不中断；重新接触可再次握手。
4. 停用后 stable=-1、recording=false，网络仍可达；不碰 pogo也可再启用。
5. 无人登录不保存个人事件；登录记录、退出继续监测；换人无上一会话缓存。
6. 网络中断、恢复；灰色离线与重新可达正确，旧个人记录不自动恢复。
7. 地图拖动、角度、命名，重开后保持该设备设置。数据离线不能显示绿灯为当前状态。
8. 最后接原终端登录/插件入口/云端，并留串口、HTTPS和页面证据。

## 七、构建与回退

固件：`firmware/build.ps1 -StageDirectory S:\esp\xiaotian-pogo-v21-1118`；产物在 `firmware/artifacts`。只烧确认过的板：

```powershell
& 'S:\esp\.espressif\python_env\idf5.5_py3.10_env\Scripts\python.exe' .\tools\flash_node.py --port COM23 --expected-mac d8:85:ac:d6:1d:c0
```

写入偏移0x0/0x8000/0x10000，16MB DIO40MHz，不整片擦除、不改eFuse。新板MAC是本轮用户明确确认的，脚本不会自动扫描并刷其他板。

旧无pogo v2目录 `../xiaotian` 及其20261113 ZIP保留，可回退；本版在独立 `xiaotian-pogo` 目录，未覆盖旧交付。新板自行生成密钥，不能因为固件一样而认为它与旧板密钥相同。

推荐后续AI用 esp32-orange-pi-bridge 技能核对协议，但以本次用户决定为准：**红外现在恢复pogo身份识别，拔开后继续独立无线工作**。验证结果见 `firmware/verification/RESULTS.md`。包有SHA256清单，未包含 `.private` 或任何设备token/私钥。
