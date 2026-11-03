# 设置页：创建用户后的恢复码界面 + 用恢复码重置 PIN（2026-11-01）

> 范围：`设置 → 用户与权限`（section 15）。只改设置页与 `SessionManager` 门面，
> 不碰首次开机向导与登录页的既有路径。
> 截图见 `user-recovery-shots/`。

## 1. 两个需求

1. 在设置里创建管理员/普通用户后，把恢复码从“一行文本 + 我已保存”升级为
   与 OOBE 一致的界面：6 组等宽大字 + 核对第 2、5 组才能关闭。
2. 登录后忘记旧 PIN 时，能在设置里用恢复码重设 PIN，不需要旧 PIN。

## 2. 创建用户后的恢复码界面

- 服务端 `SessionManager::createUser()` 早已生成并返回 `{userId, recoveryCode}`，
  只回传一次；本次只改展示与关闭条件。
- `UserSecurityPage.qml`：
  - 新增 `recoveryGroups`（规范化后按 4 字符拆 6 组）；
  - 弹窗内 6 组等宽大字 + 说明 + 第 2/5 组输入框；
  - “我已抄写”仅在 `recoveryAckOk`（两组逐字符相等）时启用；
  - `closePolicy: NoAutoClose`，点外部不能关；关闭时清空 `recoveryCode` 与两个输入框。
- 普通用户与管理员走同一个弹窗（`createUser` 的 `admin` 开关决定角色）。

## 3. 用恢复码重置 PIN

### 3.1 服务端

新增 `SessionManager::changeOwnPinWithRecoveryCode(code, newPin)`：

1. 必须已登录、非访客；
2. `PinPolicy::validPin(newPin)`；
3. `AuthService::verifyRecoveryCode(activeUserId_, code)`——复用登录路径的
   终端限速（1 次/秒）与按账号的恢复码锁定（5 次失败锁 60 秒）；
4. 验证返回的 `dbKey` 必须与当前会话的 `dbKey_` 逐字节一致（防跨用户/换库路径）；
5. `AuthService::resetPinWithDbKey(userId, dbKey, newPin)` 重新封装 DB key
   （新 salt + 新 KEK，不重加密整库，失败保留旧封装）；
6. 清 `mustChangePin_`，`emit changed()`。

**恢复码不轮换**：它封装的是同一个 DB key，改 PIN 不影响它，用户手里那份继续有效。

### 3.2 界面

- 入口：`修改我的 PIN` 下方新增一行透明按钮“忘记 PIN？用恢复码重置”。
- 弹窗：恢复码（`maximumLength: 29`，自动转大写）、新 PIN、再输一次、内联错误。
- 客户端只做两次输入一致与长度校验；恢复码正确性与锁定全在服务端。
- 错误统一为“恢复码或 PIN 不正确，请重试”，不区分原因，避免探测。
- 成功后清空字段、关闭、页面 `message = PIN 已更新`。

## 4. 验证（x86_64 + Xvfb + 作者 Qt 6.5.3）

- `auth_service_test`：**31/31 通过**（30.99 s）。在
  `recoveryCodeHasItsOwnLockoutAndResetsPin` 末尾补了两条断言：
  - 重置后**旧 PIN 立即失败**；
  - 重置后**恢复码仍然有效**（可再次自救）。
- 端到端（现有 XDG，管理员 PIN 123456、恢复码 `TBDG UWQT 2CRN P5JM H4BD VQH4`）：
  1. `--preview-page 15` + `ORANGE_PI_AUTO_LOGIN=123456` 打开用户与权限；
  2. 创建普通用户 `TestUser` / PIN `111222` → 弹出恢复码
     `JLDN DF55 EMAW PV3A 5TSE UMR5`（截图 01）；
  3. 输入第 2 组 `DF55`、第 5 组 `5TSE` → “我已抄写”变为可用（截图 02）；
  4. 滚动到“修改我的 PIN” → 点“忘记 PIN？用恢复码重置”（截图 03）；
  5. 用管理员恢复码 + 新 PIN `654321` 提交，弹窗关闭（截图 04）；
  6. 重启验证：`ORANGE_PI_AUTO_LOGIN=654321` → `auto-login: ok`；
     `ORANGE_PI_AUTO_LOGIN=123456` → `auto-login: AUTH_FAILED`。

## 5. 键盘接线（只接作者的，不改键盘）

两个弹窗里的新字段（第 2/5 组、恢复码、新 PIN ×2）在获得焦点时弹出作者已有的
`screenKeyboard`，弹窗关闭时收回。实现完全照抄 `WeatherTools` 的既有模式：

1. `UserSecurityPage` 声明 `keyboardRequested()` / `keyboardDismissed()`；
   新字段 `onActiveFocusChanged: if (activeFocus) page.keyboardRequested()`；
   两个弹窗 `onClosed: page.keyboardDismissed()`。
2. `UserSecurityView` 原样转发两个信号。
3. `Main.qml` 的 `UserSecurityView` 实例：
   `onKeyboardRequested: if(!screenKeyboard.visible) screenKeyboard.show()`、
   `onKeyboardDismissed: screenKeyboard.hide()`。

**`FloatingKeyboard.qml`、`SystemTools` 的 IME 与既有字段一行未改。**

布局约束：作者的键盘从 y≈256 弹出，两个弹窗因此改为顶部对齐（`y: 0/6`）、
收窄内边距，保证三个输入框与提交按钮全部在键盘上方（截图 05）。
关闭弹窗后键盘收回（截图 06）。

## 6. 已知边界

1. 设置页**其余既有字段**（显示名、当前 PIN 等）仍是作者原样，未接软键盘——
   本轮只覆盖这次新增的恢复码/新 PIN 字段，没有顺手改存量代码。
2. 恢复码重置只作用于**当前登录用户自己**；管理员重置他人 PIN 走
   `deleteUser`/重建账户，不在本轮范围。
3. 恢复码输入上限 29 字符（含 5 个连字符）；更多分隔方式由
   `RecoveryCode::normalize` 在服务端处理。

