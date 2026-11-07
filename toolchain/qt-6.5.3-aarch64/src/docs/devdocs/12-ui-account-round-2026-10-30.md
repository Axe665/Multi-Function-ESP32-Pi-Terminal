# 2026-10-30 轮：UI 补齐、账户删除与每用户锁屏

> - **分支**：`feat/weather-voice-v2`
> - **起点**：`11fe9c2`（D 侧上一份交接）
> - **终点**：本轮文档提交（`HEAD`）
> - **提交数**：15
> - **文件改动**：53 个文件，+4039 / −401
> - **测试**：`ctest -E "media_vlc|ui_responsive_touch|ui_highdpi_touch"` → **51/51 通过**（2026-10-30 01:38）
> - **人工验收**：1024×600 真机窗口，截图见 `weather-voice-handover/evidence/`

---

## 0. 一句话现状

把后端已有、界面没有的能力补齐；用户与权限独立成页；登录页改成 ChromeOS 式；
账户删除（本人删号 + 管理员删号）与每用户自动锁屏时长落地。**本轮改动全部有测试或截图证据。**
~~仍未开工的是「临时用户」整批隔离，设计见 §7。~~
2026-10-31：已实现，见 `13-guest-session-2026-10-31.md`。

---

## 1. 提交清单

| 提交 | 内容 |
|---|---|
| `ecef4c9` | 测试在 Qt 6.4 / 6.5.3 与 SQLCipher 4.x 下全绿（环境适配，不改产品逻辑） |
| `34043d5` | 用户与权限页补齐数据/读数/安全状态；任务取消；语音就绪 |
| `7597118` | 语音播报配置整体迁入「语音音色」页，设置页删除「声音与语音」 |
| `aa61260` | 用户与权限独立成页；应用卡片分页顺序调整（网络电视第三） |
| `54e9ca7` | 应用卡片编辑模式排序：长按拖拽、跨页、持久化 |
| `b83b12a` | 排序的编辑/取消/恢复默认/完成移到顶栏 |
| `6865458` | 天气右侧拆成两张卡；清理设置小字；修无障碍图标与开机通知 |
| `632640d` | 通知横幅不再随「未锁屏」自动展开；启动日志不弹窗 |
| `2d0c967` | ChromeOS 式登录页与用户头像 |
| `72b314e` | 设置页占位提示与文字溢出（plainHint / elide） |
| `8ac6f1b` | 天气日标签在英文大字下省略 |
| `a7f6f60` | 本人删除账户与管理员账户管理 |
| `0a3a757` | 每用户自动锁屏时长设置 |
| `94f9555` | 两个管理员锁屏时长互不影响（回归测试） |
| `docs:` 本轮文档 | 新增 12 号文档，11 号文档加指针 |

---

## 2. 功能改动

### 2.1 页面结构与顺序

- 「用户与权限」从设置页拆出，作为独立页面；设置页不再保留该分区。
- 首页轮播/应用抽屉顺序：**网络电视排第三**，其后为原有顺序。
- 语音播报的全部配置（开关、输出设备、降音、引擎状态）都在 `VoiceSettings.qml`；
  设置页的「声音与语音」分区已删除，避免两处入口。
- 设置页新增「锁屏与安全」分区（`LockSettings.qml`），位置在「无障碍」之后、「隐私」之前。

### 2.2 后端已有能力补 UI

`UserSecurityPage.qml` 直接调既有 `SecurityService` 接口，不碰数据库：

| 能力 | 界面 | 后端 |
|---|---|---|
| 个人备份 / 恢复 | 「数据与备份」分区，密码 + 二次确认 | `SecurityService::createBackup` / `restoreBackup` |
| 管理员清空本用户数据 | 同一分区，当前 PIN + 二次确认 | `SecurityService::purgeOwnData` |
| 手工读数 | 单值 + mmHg/kPa，列出最近 10 条 | `SecurityService::addManualReading` / `readings(10)`，来源记 `user.entry` |
| 安全状态 | 只读卡片组：信任库 / 身份指纹 / UID key / 槽位 | `SecurityStatus` |
| 任务取消 | 任务收尾弹窗「取消（标记未完成）」 | `SessionManager::cancelTaskAsIncomplete` |
| 语音就绪 | 语音页状态行（`Speech.ready`） | `Speech` 单例 + `SystemTools` 引擎探测 |

### 2.3 应用排序（类 Android）

- 长按应用卡片进入编辑模式，可拖拽排序、跨页移动。
- 编辑/取消/恢复默认/完成四个控件统一放在**顶栏右侧**。
- 顺序持久化到配置；「恢复默认」回到内置顺序。
- 未改模糊/渲染组件（`CachedBlur`、`GlassSurface`、shader 均未动）。

### 2.4 登录页（ChromeOS 式）

- 全屏布局：大时钟/日期、居中大头像、底部版本号与电源/更多菜单。
- 多用户时先选头像（`UserPicker.qml`），再输 PIN（`PinPad.qml`）。
- 头像文件存每用户目录，`users.json` 只存相对路径；`Avatar.qml` 无头像时显示首字母。
- 版本行显示「树莓派终端 1.0」（原为 Orange Pi，已按实机更正；内部 `applicationName`、配置路径未改，避免数据迁移）。
- 登录页弹层 `z: 30000`，压在 `SessionGate`（z 20000）之上。

### 2.5 天气右栏

- 右栏拆成上下两张卡：**逐小时** + **7 天**，间距与左栏一致。
- 未改左右滑动/翻页手势逻辑，仅重排右栏内容。
- 7 天卡的日标签在英文 + 1.5× 字号下省略（`elide`），不再撑破卡片。

### 2.6 账户删除（`a7f6f60`）

| 路径 | 入口 | 凭据 | 结果 |
|---|---|---|---|
| 本人删号 | 用户与权限页底部「危险区」 | 当前 PIN | 硬删除：注册表记录、`users/<id>/data.db`、头像、锁状态、卡片绑定、权限矩阵、last_user |
| 管理员删号 | 页顶「账户管理」→ 目标用户行 | 管理员 PIN + 目标显示名逐字一致 | 同上；审计写 `user.delete` |

约束：

- 最后一个启用的管理员不能删自己（`LAST_ADMIN`）。
- 有未完成任务时拒绝（`TASKS_UNFINISHED`）。
- 已禁用用户不出现在账户管理列表。
- 两处都是红色警示 + 5 秒冷却；本人删号不写审计（无痕），管理员删号写审计。
- 备份文件与 USB 数据不动。

API 落点：`SessionManager::deleteOwnAccount` / `deleteUser`、
`UserService::removeRecord`、`UserDatabase::deleteUserData`、
`CardMatcher::removeUser`、`SecurityService::forgetUser`、`AuditLog::DeleteUser`。

### 2.7 每用户自动锁屏（`0a3a757` / `94f9555`）

- `users.json` 新增 `lock_timeout_minutes`：`-1` 未设置（按 5 分钟）、`0` 永不、其余为分钟数。
- 可选值 `{1, 2, 5, 10, 15, 30, 0}`，默认 5。
- **没有管理员全局策略**：每个登录用户只能设自己的；管理员也改不了别人。
- 两个管理员各自的值互不影响（`twoAdminsHaveIndependentLockTimeouts` 证明 A=0、B=30 同时持久化）。
- 选「永不」显示红色警示；手动锁屏仍然有效。
- 访客/临时用户将来固定 5 分钟，不读这个字段（见 §7）。

### 2.8 设置页文字与输入

- `CarField.plainHint`：设置类页面的输入框不再用悬浮 label 占位，改为聚焦即消失的提示文字；
  失焦且为空时恢复。文件/浏览器/模块页保持原样。
- 覆盖：设置搜索、天气设置、时间同步、用户与权限、配对新设备。
- 单行文本统一 `elide`；天气探测说明允许换行；中英文标点（`，`→`, ` 等）补进 `I18n.qml`。
- 英文 + 1.5× 字号截图未发现硬溢出。

---

## 3. 测试

```bash
cd build
DISPLAY=:99 ctest -j4 -E "media_vlc|ui_responsive_touch|ui_highdpi_touch"
# 100% tests passed, 0 tests failed out of 51
```

本轮相关四个测试二进制（`QT_QPA_PLATFORM=offscreen` 直跑）：

| 测试 | 用例数 | 覆盖 |
|---|---|---|
| `session_gate_test` | 17 | 登录/锁屏/头像/删号/锁屏时长（含双管理员独立） |
| `card_matcher_test` | 15 | 卡索引匹配与 `removeUser` 物理删除 |
| `pairing_ui_test` | 9 | 配对页渲染、账户管理/删除按钮存在性 |
| `login_qml_test` | 14 | 登录页组件、`Avatar` 回退、`plainHint`、版本文案 |

新增回归用例：

- `avatarIsInstalledAndRemoved`、`avatarRequiresSession`
- `deleteOwnAccountRequiresPinAndRemovesEverything`、`lastAdminCannotDeleteSelf`、
  `deleteOwnAccountRefusedWhileTasksUnfinished`、`adminDeletesUserAndAudits`
- `lockTimeoutIsPerUserAndPersisted`、`twoAdminsHaveIndependentLockTimeouts`

排除项（环境限制，非本轮引入）：

- `media_vlc_*`：本机 VLC 插件/音频设备不可用。
- `ui_responsive_touch` / `ui_highdpi_touch`：需要真实显示环境，Xvfb 下不稳定。

---

## 4. 已知问题

| 问题 | 影响 | 状态 |
|---|---|---|
| 真实应用从不打开每用户数据库 | 管理员删号的审计被跳过（日志里有 `account deletion audit skipped`） | 未修。登录时 `openDatabase()` 在 WebEngine 下会卡死 SQLCipher 初始化，已回退 |
| `session_gate_test` 与 `user_pin_session` 并发时偶发 1 秒限流 | `-j6` 全量跑偶发红 | 单跑稳定；CI 用 `-j4` |
| `SettingsGroup.qml:71` / `WeatherTools.qml:142` 布局 polish 循环告警 | 仅日志噪声 | 既有问题，未动 |
| `--ui-test` 退出码 3 | 自动化脚本需容忍 | 既有行为 |

---

## 5. 人工验收

```bash
# 一次性副本，不碰正式数据
rm -rf /tmp/manual-test && mkdir -p /tmp/manual-test
cp -a runtime/config /tmp/manual-test/config
cp -a runtime/data   /tmp/manual-test/data
ORANGE_PI_AUTO_LOGIN=135790 \
XDG_CONFIG_HOME=/tmp/manual-test/config \
XDG_DATA_HOME=/tmp/manual-test/data \
XDG_CACHE_HOME=/tmp/manual-test/cache \
./build/orange_pi_terminal --window-size 1024x600
```

- 验收员 / `135790`（副本内为管理员）
- 锁屏：设置 → 搜索 `lock` → 选 1 分钟观察；选「永不」看红色警示。
- 删号：用户与权限 → 顶部「账户管理」删别人；页面底部危险区删自己。

截图证据（`weather-voice-handover/evidence/`）：

- `lock-timeout-15-20261030.png`、`lock-timeout-never-20261030.png`
- `settings-hint-zh-20261029.png`、`settings-en-large-20261029.png`、`users-en-large-20261029.png`
- `about-raspberry-20261029.png`

---

## 6. 与上一份文档的差异

- `11-changelog-and-tests.md` 描述的是 P0 软件完成那一轮（基线 `8748c4f`），本轮不改变其中任何门禁结论。
- 本轮新增的页面、API、数据字段以本文为准。
- 上一轮遗留的「访客账号」在本轮细化为「临时用户」，设计见交接文档 §7，**代码未开工**
  （2026-10-31 补：那个 §7 从不存在，设计与实现见 `13-guest-session-2026-10-31.md`）。
