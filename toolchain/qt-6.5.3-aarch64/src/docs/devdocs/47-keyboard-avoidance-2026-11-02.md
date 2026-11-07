# 全局键盘避让（2026-11-02）

## 1. 现状

键盘是全局浮动的 `FloatingKeyboard`（Popup，`positionNearBottom()` 停在底部上方），
代码里有 **64 处 `keyboardRequested`、12 个文件** 在请求键盘，但**没有任何统一避让**：
各页面各管各的，多数页面键盘弹起来就盖住输入框。

## 2. 参考：宠物菜单的做法

`PetManager.qml` 里是这么算的：

```qml
property var virtualKeyboard: null
readonly property real usableHeight: Math.max(0, Math.min(availableBottom,
    virtualKeyboard && virtualKeyboard.visible ? virtualKeyboard.y - 8 : availableBottom))
```

即：**用键盘的 `y` 算出还剩多少可用高度**，弹窗按这个高度缩，再在可用区里居中。
对 Popup 很合适——它本来就可以自由定高。

## 3. 全屏页面的做法

设置页、用户页这类是全屏页面，不能缩高度，所以改成**整体上移**：

`Main.qml` 新增：

```qml
property real keyboardShift: 0

function updateKeyboardShift() {
    if (!screenKeyboard || !screenKeyboard.visible) { keyboardShift = 0; return }
    const focusItem = win.activeFocusItem
    if (!focusItem) { keyboardShift = 0; return }
    // 用「未偏移」的位置算，否则位移会自己把自己越推越远
    const rawBottom = focusItem.mapToItem(win.contentItem, 0, focusItem.height).y + keyboardShift
    const overlap = rawBottom + 12 * uiScale - screenKeyboard.y
    keyboardShift = Math.min(Math.max(0, overlap), screenKeyboard.height + 24 * uiScale)
}
```

应用到内容容器：

```qml
StackLayout {
    id: pages
    transform: Translate {
        y: -win.keyboardShift
        Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
}
```

重算时机：键盘显示/隐藏、键盘被拖动（`y`/`height` 变化）、焦点变化、缩放变化。

三个要点：

- **幂等**：计算时先把当前 `keyboardShift` 加回去，用未偏移的位置算，避免越推越远；
- **只动内容**：壁纸和任务栏不参与位移；
- **上限**：最多推「键盘高度 + 24」，防止极端情况下整页飞出屏幕。

## 4. 验证

真机 700×600，设置 → 关于本机 → 点铅笔进入编辑态 → 点输入框：

| | 输入框位置（截图坐标） | 键盘顶部 |
| --- | --- | --- |
| 聚焦前 | y ≈ 540–575 | 未弹出 |
| 聚焦后 | y ≈ 404–458 | ≈ 510 |

页面整体上移约 136px（物理），输入框和「保存 / 取消」都完整露在键盘上方。



## 5. 已知未做

**键盘遮挡页面下半部分**：想让可视区底部收到键盘上沿（宠物菜单那种），
但 `StackLayout` 上的 `anchors.bottomMargin` 实测不生效（用固定值 300 试过，
布局纹丝不动），需要换别的容器或改 `appShell` 的高度才能做。

目前的行为是：键盘会盖住页面下半部分，但**聚焦的输入框一定会被移到键盘上方**——
后者是用户实际输入时最要紧的。

另一个没覆盖的：`Popup` 里的输入框（恢复码、建号）不在 `pages` 里，
上移对它们无效；那些弹窗已经按可用区定位过。
