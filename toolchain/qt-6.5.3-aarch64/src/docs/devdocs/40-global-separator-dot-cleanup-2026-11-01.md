# 全项目分隔点清理（2026-11-01）

## 1. 范围共识

按「只改 UI 界面上的文字、单空格替换、技术标识与宠物名不动」执行。

| 决定 | 结论 |
| --- | --- |
| 改哪里 | 运行时渲染出来的界面文字（`qml/` + 示例模块），不含注释、README、`hardware/`、`docs/`、`third_party/` |
| 换成什么 | 单空格（与天气页一致），英文译文同步 |
| 技术标识 | 不动（`eth0 · IP`、`deviceId · generation`、`bridgeId · 指纹`、`型号 · modelName`、`IP · MAC`） |
| 宠物名 | 不动（`阿米娅 · 默认服装`） |

## 2. 已改（18 处）

### 2.1 生产界面

| 文件 | 位置 | 原 → 现 |
| --- | --- | --- |
| `qml/I18n.qml` | 词条 | `当前无模块连接 · 未认证` → `当前无模块连接 未认证`（英文同步） |
| `qml/I18n.qml` | 词条 | `开发者 D · 致谢 T` → `开发者 D 致谢 T`（英文同步） |
| `qml/ModuleAuthPanel.qml` | 空态文案 | 跟随上条 key |
| `qml/ModuleAuthPanel.qml` | 模块行 | `模块名 · 状态` → `模块名 状态` |
| `qml/UserSecurityPage.qml` | 卡片统计 | `接受 5 · 拒绝 1 · <原因>` → 空格分隔（两处拼接） |
| `qml/SecurityStatusSection.qml` | 信任库行 | `信任库：正常 · 已配对 2` → `信任库：正常 已配对 2` |
| `qml/SecurityStatusSection.qml` | 卡片统计 | 同 `UserSecurityPage`，两处 |
| `qml/AboutDevicePage.qml` | 致谢入口 | `开发者 6 致谢 6` |

### 2.2 示例模块（两份副本同步改）

`modules/test_devices/` 与 `.desktop/*/plugin/qml/ExamplePage.qml` 是同一份示例的两个副本，
两边一起改，避免内置测试设备与插件模板不一致：

| 文件 | 原 → 现 |
| --- | --- |
| `camera.qml` / `ExamplePage.qml` | `相机 · 模拟测试画面` → `相机 模拟测试画面` |
| `camera.qml` / `ExamplePage.qml` | `预览中 · 帧序号 3` → `预览中 帧序号 3` |
| `environment.qml` / `ExamplePage.qml` | `环境监测 · 模拟数据` → `环境监测 模拟数据` |
| `counter.qml` / `ExamplePage.qml` | `计数器 · TCP 模拟设备` → `计数器 TCP 模拟设备` |

## 3. 保留（技术标识，18 处）

| 文件 | 内容 | 理由 |
| --- | --- | --- |
| `qml/UserSecurityPage.qml:907`、`qml/SecurityStatusSection.qml:126` | `deviceId · generation` | 两边都是机器标识 |
| `qml/SecurityStatusSection.qml:53` | `bridgeId · fingerprintHex` | 同上 |
| `qml/SecurityStatusSection.qml:66` | `本机身份：<指纹> · 状态` | 一边是指纹 hex |
| `qml/ModuleAuthPanel.qml:139` | `capability · 已授予` | `capability` 是权限标识串 |
| `qml/Main.qml:173` | `选择模块可写位置 · <packageId>` | 一边是包名 |
| `qml/AboutDevicePage.qml:78` | `\u00A0·\u00A0 CPU 架构` | 架构型号；且用不换行空格防折行，删点要连带改折行策略 |
| `qml/AboutDevicePage.qml:96/98` | `显卡名 · 驱动`、`驱动 · PCI` | 驱动名、PCI 地址 |
| `qml/AboutDevicePage.qml:110/111` | `IP · MAC` | 地址 |
| `qml/AboutDevicePage.qml:270` | `型号 · modelName` | 型号串 |
| `modules/test_devices/environment.qml:14`、`.desktop/.../ExamplePage.qml:14` | `采样序号：5 · <status>` | `<status>` 是模拟设备返回的状态值 |
| `modules/test_devices/counter.qml:10`、`.desktop/.../ExamplePage.qml:10` | `计数 5 · <operation>` | `<operation>` 是机器操作名 |
| `src/ui/PetLibrary.cpp:118/138` | `阿米娅 · 默认服装` | 宠物名，按共识不动 |
| `src/app/OnboardingController.cpp:94` | `eth0 · 192.168.1.5` | 网卡名 + 地址 |

未动：注释（`TimeSyncSettings.qml` 的「上午·下午」、`db_webengine_probe.cpp` 的「真·死锁」等）、
`README.md`、`hardware/enclosure/**`、`docs/**`、`third_party/**`、测试 fixture。

## 4. 验证

- `cmake --build /tmp/oobe-build -j8` 通过；
- `ctest` 全量：72 项，69 通过，失败仍是既有的
  `arkpets_sprite_packing`、`ui_responsive_touch`、`ui_highdpi_touch`；
- 真机截图确认：
  - 关于本机页「开发者 6 致谢 6」（点已去掉）；
  - 同一页保留项正常：`Intel(R) Core(TM) i5-14600KF × 20 · x86_64`、`Radeon RX 7700 XT / 7800 XT] · amdgpu`。
