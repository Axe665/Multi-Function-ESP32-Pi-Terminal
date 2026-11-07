# 用户与权限：键盘关不掉、循环弹出（2026-11-01）

> 范围：`设置 → 用户与权限` 的 21 个输入框，以及公共输入组件 `CarField.qml`。
> 不改 `FloatingKeyboard.qml`（键盘组件保持原样）。

## 1. 症状

在用户与权限里点任意输入框，虚拟键盘弹出；点键盘上的关闭按钮后，键盘立刻
又弹出来，反复关不掉，表现为"键盘关不上、循环开启"。

## 2. 根因

`UserSecurityPage.qml` 里 21 个 `CarField` 都是这样请求键盘的：

```qml
CarField {
    onActiveFocusChanged: if (activeFocus) page.keyboardRequested()
}
```

`FloatingKeyboard` 是一个 `Popup`。Popup 关闭时 Qt 会把焦点还给关闭前的焦点项，
也就是这个 `TextField`——于是 `activeFocus` 从 false 变 true，`onActiveFocusChanged`
再次调用 `keyboardRequested()`，键盘重新 `show()`。关一次、开一次，形成循环。

`AboutDevicePage.qml` 早先遇到过同一个问题，注释里写着"不能用 onActiveFocusChanged：
关闭键盘会让输入框重新拿到焦点，又把键盘顶起来"，它用的是 `TapHandler`。

## 3. 修复

### 3.1 `CarField.qml`

新增一个信号和 passive 的点击处理器：

```qml
// 点击输入框才请求虚拟键盘。不能用 onActiveFocusChanged：键盘收起时
// Qt 会把焦点还给输入框，焦点变化又请求弹出，表现为"关不掉、循环开启"。
signal keyboardRequested()
TapHandler {
    // Handler 挂在 contentItem 上，边界是文字区；margin 扩到 padding 外沿。
    margin: field.padding
    onTapped: field.keyboardRequested()
}
```

`TapHandler` 是 passive 的，不抢 press、不影响光标定位与文本选择；只有真正
点下去才发信号。`margin` 让命中区从文字区扩到整个输入框（含左右留白）。

### 3.2 `UserSecurityPage.qml`

21 处统一改成：

```qml
onKeyboardRequested: page.keyboardRequested()
```

页面本身仍然只发 `keyboardRequested()`，由 `UserSecurityView` → `Main.qml`
决定 `screenKeyboard.show()`，键盘组件的接线没有变。

## 4. 行为变化

- 点输入框 → 弹键盘（与以前一致）；
- 点键盘关闭 → 键盘收起且保持收起，焦点回到输入框也不会再弹；
- 再点输入框 → 键盘重新弹出；
- 回车提交（`onAccepted`）不受影响。

## 5. 其他页面

- `AboutDevicePage.qml`：本来就是 `TapHandler`，无影响；
- `AdminPairingPage.qml`、OOBE 的 `AdminStep/RecoveryStep` 仍用
  `onActiveFocusChanged` 调键盘：本次未改（不在用户报告范围）。若在真机上
  复现同样的循环，按本文 3.1 的方式换成点击触发即可。

## 6. 测试

`pairing_ui_test::userPageFieldRequestsKeyboardOnTapOnly`：

1. 真实鼠标点击 `newUserName` 字段 → `keyboardRequested` 恰好发出 1 次；
2. 把焦点移到另一个字段、再强制还给 `newUserName`（模拟键盘收起后 Qt 归还焦点）
   → 计数仍是 1，不再请求键盘。

这条用例在旧实现下会得到 2，能挡住回归。
