# 设置页改版：分类卡片 + 滑入二级页（2026-11-01）

> 范围：`设置`（section 4）主页与它的分类页。控件与后端逻辑全部沿用，
> 只改信息架构与视觉外壳；两个彩蛋的触发方式一字未动。

## 1. 需求

1. 设置主页改成「用户与权限」那种两列分类卡片，点卡片从右侧滑入二级页；
2. 联网权限 + 网络与连接合并成「网络连接管理」；
3. 隐私与数据、无障碍的图标按 Google Material 风格重做；
4. 两个彩蛋的触发方式不变。

## 2. 结构

设置主页（10 张卡片，两列）：

| # | 分类 | 内容 |
| --- | --- | --- |
| 0 | 显示与个性化 | 壁纸、界面不透明度、界面比例；**标题连点 5 次 = 桌宠彩蛋** |
| 1 | 无障碍 | 大字号开关 |
| 2 | 锁屏与安全 | `LockSettings` |
| 3 | 隐私与数据 | 记录保留期限 |
| 4 | 语言 / Language | 中英文切换 |
| 5 | 语音音色 | 入口（独立页 section 13） |
| 6 | 时间与报时 | `TimeSyncSettings` |
| 7 | 网络连接管理 | 联网总闸 + 各功能联网入口 + 热点开关 |
| 8 | 开发者选项 | 仅管理员可见；入口（独立面板） |
| 9 | 关于本机 | 非访客可见；入口（二级页） |

> 讨论时按“9 张”估算，实际是 10 张：原主页是 11 个分组
> （显示、无障碍、锁屏、隐私、语言、语音、时间、联网权限、网络与连接、开发者、关于），
> 合并网络两项后是 10 张。没有为了凑数把不相关的设置绑在一起。

点卡片整页从右侧滑入（`RightSlidePage`，240ms OutCubic，与开发者选项/关于本机同一套）；
二级页顶部是「← 返回 + 分类名」，页内仍是原来的 `SettingsGroup`（图标、标题、副标题都保留），
所以控件、绑定、`objectName` 全部没动。

## 3. 网络连接管理

二级页里两块内容，都在同一页：

1. `NetworkPermissions`（联网总闸、状态说明、「管理各功能联网」入口）；
2. 「热点」`SettingsGroup`（开启/关闭热点与状态）。

「管理各功能联网」仍然进入原来的 `NetworkPermissionsPage`：那一页是草稿 + 保存 +
管理员 PIN 复验的编辑流程，不能压平成内联开关，否则会绕过保存前的权限校验。
层次变成：设置 → 网络连接管理 → 各功能联网（三级）。

## 4. 两个彩蛋

| 彩蛋 | 触发方式 | 改版后 |
| --- | --- | --- |
| 桌宠 | 设置 →「显示与个性化」标题连点 5 次 | 在二级页里的 `SettingsGroup` 标题上，逻辑与次数完全不变 |
| 测试音色 | 设置 →「语音播报」标题连点 5 次 | 语音播报是独立页（section 13），本次未改 |

彩蛋的实现仍是 `SettingsGroup.titleTapEnabled` + `onTitleTapped`（5 次 / 1.8 秒窗口），
没有换成卡片长按或别的手势。

## 5. 图标

真正的根因不是 SVG 缺失，而是 `MaterialIcon.qml` 有一份硬编码的 `available` 白名单：
`shield` 与 `accessibility_new` 都不在名单里，两个图标都 fallback 成 `extension`（拼图块）。

修复：

- 白名单加入 `shield`、`accessibility_new`；
- `accessibility_new.svg` 本来就是 Google Material Icons Round 的标准图标，直接可用；
- 新增 `icons/material/{light,dark}/shield.svg`：24dp 网格，盾形取自同目录
  `verified_user.svg` 去掉对勾（自绘，Apache-2.0 兼容几何），登记到 `SOURCES.json`。

## 6. 搜索

顶部搜索框保留，行为改成「输入关键词只显示匹配的分类卡片」。
每张卡片带一个 `match` 正则（原分组上的那套关键词），匹配标题与描述里的中英文词。
搜索框点击弹键盘走 `CarField.keyboardRequested`（点击触发，关掉不会自己弹回来）。

## 7. 实现位置

- `Main.qml`：
  - `win.settingsSection`（-1 = 主页）与 `win.settingsCards`（卡片模型）；
  - `settingsPageLoader` 的 `sourceComponent` 从「一个 Flickable」改成
    「Item { 主页 Flickable + RightSlidePage 二级页 }」；
  - 原 11 个分组原样搬进二级页的 `ColumnLayout`，各自 `visible: win.settingsSection === N`。
- `SettingsGroup.qml`、`NetworkPermissions.qml`、`LockSettings.qml`、`TimeSyncSettings.qml`：未改。

## 8. 截图

| 文件 | 内容 |
| --- | --- |
| `settings-home.png` | 主页卡片（显示与个性化 / 无障碍 / 锁屏 / 隐私） |
| `settings-personalization.png` | 显示与个性化二级页（壁纸、比例） |
| `settings-privacy.png` | 隐私与数据二级页（保留期限，盾形图标） |
| `settings-network.png` | 网络连接管理二级页（联网总闸） |
| `settings-easter-egg.png` | 连点标题 5 次后的桌宠菜单 |

## 9. 第二轮调整（同日）

1. **一步到内容**：语音音色、开发者选项、关于本机三张卡片不再先进一个只有
   「打开…」按钮的中间页——点卡片直接打开最后一层：
   - 语音音色：二级页里直接铺 `VoiceSettings`（自带滚动），不再是独立功能页；
   - 开发者选项 / 关于本机：卡片直接置 `win.developerPanelOpen` / `win.aboutDeviceOpen`，
     打开它们自己的右滑页。
2. **只留一个主标题**：二级页顶部固定一行「← 返回 + 分类名」，页内所有
   `SettingsGroup` 用新属性 `headerVisible:false` 收起分组标题/图标/副标题，
   不再重复分类名。
3. **彩蛋移到主标题**：两个彩蛋的触发点从分组标题改到二级页主标题，仍是连点 5 次
   （1.8 秒窗口）。`SettingsGroup` 的 `registerTitleTap` 与两个 `onTitleTapped`
   一行未改：主标题只是调用原分组实例的 `registerTitleTap()`
   （`personalizationGroup` / `VoiceSettings.registerTitleTap()`）。
4. `SettingsGroup.qml` 只新增 `headerVisible` 属性控制标题行可见性与高度，
   彩蛋逻辑未动。
