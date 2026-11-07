# 恢复码三处入口与导出到 U 盘（2026-11-02）

## 1. 共识

| 决定 | 结论 |
| --- | --- |
| 「开始菜单」 | 指 OOBE 首次开机向导第 3 步（恢复码页），不是应用抽屉 |
| 锁屏建号授权 | 先验当前管理员 PIN，再进创建流程（两步） |
| 导出交互 | 恢复码界面里一个按钮，点开才展开盘列表 |
| txt 内容 | 用户名 + 时间 + 恢复码 + 「离线保存」提醒；文件名带时间戳 |
| 三处组织 | 共用同一个「恢复码导出」组件 |
| 锁屏表单 | 与其他用户同一张表单（名字 / 初始 PIN / 设为管理员） |
| 入口位置 | 锁屏右上角，和「退出登录」并排 |

## 2. 新增

### 2.1 `qml/RecoveryExport.qml`

平时只有一个「导出到 U 盘」按钮，点开展开 `UsbDevicePicker`（只读盘不可选）。
选中盘后写文件：

```qml
systemTools.writeRemovableText("@usb/" + deviceId + "/recovery-" + <时间戳> + ".txt", text)
```

txt 内容：

```
模块化终端 恢复码
用户：验收员
时间：2026-11-02 00:12
恢复码：BXAZ-HHXC-KCGY-MPSQ-P2A5-NYYL

忘记 PIN 时，这是唯一能找回数据的方式。请离线保存，不要放在本机。
```

文件名用英文 `recovery-<yyyyMMdd-HHmm>.txt`，避免 U 盘文件系统编码问题。

### 2.2 `qml/LockCreateUser.qml`

锁屏上的建号流程，三个 Popup：

1. `lockCreateUserAuth`：管理员 PIN → `sessionManager.verifyPin`；
2. `lockCreateUserForm`：显示名 / 初始 PIN / 设为管理员 → `sessionManager.createUser`；
3. `lockCreateUserCode`：一次性恢复码（6 组等宽）+ `RecoveryExport` + 「完成」。

### 2.3 C++

`SystemTools::writeRemovableText(location, text)`：`resolve(location, creating=true)` 后
以 UTF-8 写入并 `flush()`，写成功才返回 true。

## 3. 三处接入

| 位置 | 改动 |
| --- | --- |
| `qml/onboarding/RecoveryStep.qml` | 核对第 2/5 组的输入框下面加 `RecoveryExport`（`objectName: "onboardingRecoveryExport"`） |
| `qml/UserSecurityPage.qml` recoveryDialog | 「我已抄写」行下面加 `RecoveryExport` |
| `qml/LockScreen.qml` | 右上角新增 `lockCreateUser` 图标按钮；实例化 `LockCreateUser`，键盘请求转发给 `SessionGate` |
| `qml/SessionGate.qml` | 接 `onKeyboardRequested`，锁屏里输入 PIN 也能调出软键盘 |

## 4. 测试

- `login_lock_user_pages` 一开始红了：它的独立 QML 模块只收了 `LockScreen.qml`，
  新引用的 `LockCreateUser` / `RecoveryExport` / `UsbDevicePicker` 不在模块里，
  报 `LockCreateUser is not a type`。已把三个文件加进 `login_test_qml`。
- 全量 72 项，71 通过，仍只剩 `arkpets_sprite_packing`。

## 5. 验证情况

已验证：

- 构建通过；
- `pairing_ui_page`、`login_lock_user_pages`、两项 UI 审计均通过；
- 真机上数据页的 U 盘列表（第 44 号文档那轮）渲染正常，`RecoveryExport` 复用的就是同一个组件。

**未做真机点击验证**：锁屏建号这三步（验 PIN → 填表 → 恢复码）只在代码与模块加载层面通过，
没有在真机上逐屏点过——验证时桌面被浏览器窗口遮挡且终端进程已退出，没有强行最小化用户窗口去操作。

建议你自己在锁屏上点一遍，重点看两处：

1. 输完管理员 PIN 后表单是否正常出现（键盘弹起时弹窗是否被顶出屏幕）；
2. 恢复码弹窗里「导出到 U 盘」展开后，盘列表是否在该弹窗内正常显示。
