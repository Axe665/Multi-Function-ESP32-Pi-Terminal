# 最后一名管理员可自删，删除后直接回到首次开机向导（2026-11-01）

> 范围：`设置 → 用户与权限 → 高级 → 删除我的账户` 与 `OnboardingController`。
> 不改登录页、不改 OOBE 的步骤编排，只把"删空注册表"从死路改成回到欢迎向导。

## 1. 需求

1. 终端上只剩一名管理员时，允许他删除自己（此前按钮置灰、后端返回 `LAST_ADMIN`）。
2. 删除完成后**直接**进入首次开机向导（欢迎界面），不用重启终端。

## 2. 后端

### 2.1 `SessionManager::deleteOwnAccount`

去掉唯一的 `LAST_ADMIN` 守卫：

```cpp
if (!authService_->verifyOwnPin(activeUserId_, pin))
    return QStringLiteral("AUTH_FAILED");
// 最后一个管理员也允许自删：删完注册表为空，宿主把向导重新拉起来。
if (!deleteAccountData(activeUserId_)) return QStringLiteral("STORAGE_UNAVAILABLE");
```

`deleteUser()`（管理员删别人）的最后管理员守卫保留：它防的是"管理员把唯一管理员删掉"
这条本就被"不能删自己"堵死、但留作纵深防御的路径。

### 2.2 `OnboardingController::rearm()`

新增 `Q_INVOKABLE void rearm()`，与启动时的 `setStartupRequirement(true)` 区别在于
**清掉上一轮状态**：

- `pendingName_` / `pendingPin_` 清零（明文 PIN 显式擦除）；
- `recoveryCode_` 清空并 `emit recoveryCodeChanged()`——旧码已经展示过，新一轮必须重新生成；
- `ready_ = false`、`setBusy(false)`、`clearError()`；
- 网络摘要复位为"未探测"；
- 最后 `active_ = true`。

向导 QML 由 `Main.qml` 的 `Loader { active: onboarding.active && win.startupComplete }`
驱动：`active` 从 false 变 true 时 Loader 重新加载 `OnboardingWizard.qml`，
`step` 自然回到 0（欢迎页），自动登录与创建管理员仍走原路径。

### 2.3 宿主接线

`TerminalApplication` 里复用已有的 `userDeleted` 信号：

```cpp
QObject::connect(&session_, &security::SessionManager::userDeleted,
                 &onboarding_, [this](const QString &) {
    if (!userService_.hasAnyUser()) onboarding_.rearm();
});
```

`userDeleted` 在 `deleteAccountData()` 末尾、注册表已落盘之后发出，所以这里读到的
`hasAnyUser()` 一定是删除后的状态。

## 3. QML

### 3.1 `UserSecurityPage.qml`

- `canDeleteOwnAccount` 改为 `sessionManager.loggedIn`，按钮不再置灰；
- 新增 `lastAdmin`（`isAdmin && adminCount <= 1`），只用来显示提示；
- 提示从"最后一个管理员不能删除自己"改为
  "你是最后一名管理员。删除后这台终端会回到首次开机向导，需要重新创建管理员并保存新的恢复码。"；
- 删除确认框在最后管理员时多一行警告；
- `confirmOwnDelete()` 成功后顺带收起键盘、清空 PIN 输入框。

### 3.2 `Main.qml`

`sessionManager.sessionInvalidated` 新增处理：`phase="home"`、`section=0`、
`modulePageHost.unload()`。否则向导结束后会停在已删账户的"用户与权限"页上。
登出（`logout()` 也会 emit 这个信号）同样回到首页，行为一致。

## 4. 测试

| 用例 | 断言 |
| --- | --- |
| `session_gate_test::lastAdminCanDeleteSelfAndLeavesRegistryEmpty` | 返回空、`!loggedIn()`、`!hasAnyUser()`、`lookup()` 失败 |
| `onboarding_test::rearmRestartsWizardFromScratch` | rearm 后 `active && !ready && !busy`、恢复码清空、新码与旧码不同、重复 rearm 是 no-op |
| `pairing_ui_test::userPageShowsUsersAndRecoveryCode` | 单管理员的"删除我的账户"按钮可用（原断言是置灰） |

## 5. 边界

- **恢复码随账户一起删除**：自删就是彻底删号，旧恢复码之后不能登录，也不能恢复数据；
- 向导创建管理员失败（如 KDF/库打不开）时保持 `active=true`，用户可重试，不会掉回登录页；
- 删除后直接关机：注册表仍为空，下次启动照样进向导，与"立即进入"是同一个状态；
- 访客（`isGuest`）没有账户，`deleteOwnAccount` 仍返回 `NOT_AUTHORIZED`。
