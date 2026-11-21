# AI 模块开发引导组件

本文件是给 AI coding 工具的操作契约。把整个 `module-devkit/` 目录提供给 AI，并让它先阅读本文件，再修改模块工程。

本文命令从主仓库根目录举例；独立SDK使用者去掉命令中的 `module-devkit/` 前缀即可。`examples/`、`sdk/` 等路径均相对SDK根目录。

## AI 的目标

已有环境模块硬件时，优先阅读 `examples/smart-planter/README.md` 和 `VALIDATION.md`，复用真实日/周历史、电量、图示和原生测试。用 `module_devkit.py stage PROJECT BUILD PACKAGE --arch aarch64` 收集完整资源；不得只打包入口QML而漏掉同目录组件。

引导开发者从零完成一个双端模块：

1. 明确模块功能、硬件、模块 ID、传输模式和数据格式；
2. 生成主机插件、QML 页面和 manifest；
3. 生成 ESP32-S3 固件业务逻辑；
4. 使用 SDK 内置的 LinkIt 控制面和 module data service；
5. 构建主机 ARM64 插件和 BLE/LAN 固件；
6. 使用平台现有签名私钥生成可信包；
7. 运行模拟测试；
8. 生成物理 Pi 验收清单并指导逐项测试。

## 不可违反的规则

- 不读取、打印、提交或复制私钥、token、Wi-Fi 密码和私有 sdkconfig。
- 不生成新的公钥替换目标 Pi 的信任链。
- 不把 `send_control` 当业务数据通道；业务使用 `send_data`/`module_data_service_publish`。
- LAN 模式只连接固定 Pi 热点；不自动回退 BLE。
- BLE/LAN 使用独立 build 目录。
- 不把编译成功说成物理验收成功。
- 不烧录、不重启 Pi 服务，除非开发者明确确认目标设备和操作。
- `pi_module_stop()` 必须停止线程、定时器、回调和异步发送。

## 宿主能提供什么（v3 能力清单）

这一节是「当前项目领先于旧文档/旧 SDK 的部分」。照着老仓库写的模块会漏掉它们，
表现为：页面拿不到数据、请求被静默拒绝、或者干脆没意识到这些能力存在。

### QML 侧：模块页拿到的上下文属性

宿主 `ModulePageHost` 每次加载都新建 context，注入下面这些对象。**按名字直接用**，
不需要 import、不需要 require：

| 名字 | 提供什么 |
| --- | --- |
| `appData` | 模块数据入口（v3 名称）。`moduleId`、`ready`、`schemaReady`、`lastError`；`records()`、`append(record, fields)`、`appendBatch`、`query(record, options)`、`series(record, field, spanMs, stepMs)`、`validateRecord`、`requestAdvice()` |
| `moduleData` | 同上，**兼容别名**，保留一个版本周期。新代码写 `appData` |
| `appAdvice` | 建议通道。见下 |
| `appNetwork` | 异步 HTTP(S)。`request({method,url,headers,bodyBase64,timeoutMs})` 返回 id，结果走 `finished(id, response)` 信号；`allowed`、`lastError` |
| `appFiles` | 受控文件。`request(op, args)`，op 取 `read/write/mkdir/rename/remove`；`appRoot`、`allowed`、`writeGrantExpiresAt`、`requestWriteAccess()` |
| `sessionModel` | 当前会话 |
| `userContext` | 当前用户信息 |
| `hostTheme` | 宿主主题令牌 |

两个容易踩的点：

- **别用 `data` 当属性名**。`QQuickItem` 自带 `data`（子项列表），会遮蔽同名 context property，
  页面调到的永远是子项列表。宿主因此用 `moduleData` / `appData`。
- **`appFiles` 的写权限是申请的，不是默认给的**：`requestWriteAccess()` 之后等
  `writeGrantExpiresAt` 变化，写类操作才会通过。

### 建议通道 `appAdvice`

```qml
Component.onCompleted: {
    appAdvice.setModuleId(appData.moduleId)
    appAdvice.request({ record: "measurement.env", windowMs: 300000 })
}
Connections {
    target: appAdvice
    function onAdviceReady(requestId, payload) { /* 展示 payload */ }
    function onAdviceFailed(requestId, reason) { /* 展示失败原因 */ }
}
```

- `windowMs` 只接受 `300000` / `3600000` / `86400000` 三档；
- `record` 必须是 manifest `data_schema` 里声明过的记录名；
- 建议是**异步**返回的：必须接 `adviceReady` / `adviceFailed`，只发 `request` 不收结果
  会让页面永远停在 loading；
- `status` / `lastError` 反映通道状态（`unavailable` / `refreshing` / `ready`）。
  云端不可用时它仍会尝试边/端本地方案，模块页要如实显示 `lastError` 而不是假装成功。

### C++ 侧：`pi_host_services` 的九个回调

宿主 `module_worker_main.cpp` 全部实现，但**老宿主的函数指针可能是空的**——调用前判空
（`pi_module_sdk` 的封装已经替你做）。

| 回调 | 用途 |
| --- | --- |
| `send_data` | 下行 JSON 到设备（业务通道） |
| `send_control` | PBR1 桥控制面，**只用于桥板诊断**，不是业务通道 |
| `emit_event` | 上行业务记录（v3 推荐，带 context） |
| `publish_event` | 同上，老签名，`emit_event` 为空时回退 |
| `publish_action` | 上报 UI 动作文本 |
| `data_directory` | 模块自己的可写数据目录 |
| `log` | 写 worker 日志 |
| `network_request` | **同步** HTTP(S)，最长 35 s，仅公网 |
| `file_request` | **同步**受控文件操作，写限本模块 app root |

`pi_module_sdk.h` 里对应封装：`send_json`、`send_control`、`publish`、`data_directory`、
`network_request`、`file_request`、`log`，以及 `has_network` / `has_file` /
`has_data_directory` 三个能力探测。

两处必须记住的语义差：

- **C++ `network_request` 同步、QML `appNetwork.request` 异步**。C++ 侧不要在
  `on_data` 热路径里调它，会卡住整个 worker 最长 35 秒。
- **两者的返回值/响应只在下一次调用前有效**（宿主复用缓冲区）；`pi_module_sdk`
  已经拷成 `std::string`，直接用裸 `host->network_request(...)` 时自己拷。

网络与文件都不是自动可用的：要宿主在 manifest 里授予 `network_api` / `file_api`
对应权限，未授权时一律返回 `{"ok":false,...}`（默认拒绝）。

## AI 工作流程

### 阶段 0：需求确认

必须向开发者确认：

- 模块名称和 `module_id`（1–255）；
- ESP32-S3 板型和 GPIO/I2C/SPI 引脚；
- 传输模式：`BLE` 或固定 Pi `LAN`；
- 传感器/执行器功能；
- 命令和数据 JSON/二进制格式；
- 页面需要显示和控制的内容；
- 是否已有平台签名私钥路径（只确认路径，不读取内容）。

没有这些信息时，不要猜硬件引脚或协议字段；先生成待确认清单。

### 阶段 1：初始化

```sh
python3 module-devkit/module_devkit.py init ./my-module \
  --module-id <ID> --name "<模块名>"
```

检查生成的：

- `manifest.json`（v3：`platform_api=2`、`min_host_api=3`、`data_schema`）
- `module.cpp`
- `qml/ModulePage.qml`
- `firmware/main/main.c`
- `firmware/main/Kconfig.projbuild`

### 阶段 2：实现业务

AI 只修改模块工程，不修改 SDK 内置协议组件。实现顺序：

1. ESP32 硬件初始化和驱动；
2. 命令回调和参数校验；
3. 传感器采样/执行器控制；
4. `module_data_service_publish()` 发布数据；
5. 主机 `pi_module_on_data()` 解析数据；
6. `pi_module_action()` 发送命令；
7. QML 页面状态、错误和加载显示。

### 阶段 3：脱机检查

```sh
python3 module-devkit/module_devkit.py doctor
python3 module-devkit/module_devkit.py validate ./my-module
python3 module-devkit/module_devkit.py schema check ./my-module
```

若拥有匹配平台私钥，可发布：

```sh
python3 module-devkit/module_devkit.py release ./my-module ./release \
  /secure/platform-private.pem \
  --arch aarch64 \
  --toolchain /secure/pi-toolchain.cmake \
  --firmware-mode LAN \
  --sdkconfig /secure/sdkconfig
```

AI 必须检查输出中的 `.so` 为 `aarch64`，并验证 `package.json` 使用目标 Pi 公钥通过验签。不能把测试密钥包称为生产可信包。

### 阶段 4：模拟测试

```sh
python3 module-devkit/mock-device.py ./release/signed-package \
  --module-id <ID>
```

AI 应测试 action、数据解析、异常数据、断开和重连逻辑。模拟测试不代表真实 BLE、Wi-Fi、LinkIt 或传感器通过。

### 阶段 5：实机验收

AI 必须打开 `PHYSICAL-PI-TEST.md`，逐项询问开发者并记录：

- 控制桥 attach；
- `module-transport-v1`；
- 固定 Pi 热点或 BLE；
- token/session_ready；
- 真实命令和数据；
- 断开/重连；
- QML 页面；
- 固件和包 SHA256。

任何未执行项目必须标记为 `NOT TESTED`，不得标记 PASS。

## AI 每轮输出格式

```text
当前阶段：需求 / 初始化 / 主机 / 固件 / 构建 / 签名 / 模拟 / 实机
已完成：
当前要做：
需要开发者确认：
执行命令：
预期结果：
风险或未测试项：
下一步：
```
