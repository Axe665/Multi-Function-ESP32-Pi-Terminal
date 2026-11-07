# 本轮键盘相关修复与打包说明（2026-11-02）

## 1. 键盘层级（修「点输入框没反应」）

现象：登录页建号、开发者选项里的输入框点了没反应，键盘像是没弹。

实际弹了，只是被盖住：

| 层 | z |
| --- | --- |
| `screenKeyboard` | 原来 2000 |
| 开发者选项面板 | 15000 |
| 登入门禁 `SessionGate` | 20000 |
| 解锁遮罩 | 31000 |
| 建号覆盖层 | 30000 |

键盘 2000 压在所有这些下面。现在提到 **36000**，只低于首次开机向导（50000）和删账户等待层（45000）。

## 2. 开发者选项两个输入框（真没接键盘）

`DeveloperPanel.qml` 里 Bridge ID / Public key 两个 `CarField` 从来没有 `onKeyboardRequested`。
补上 `signal keyboardRequested()`，两个输入框接上，`Main.qml` 连到 `screenKeyboard.show()`。

## 3. 绑定卡 PIN 弹窗避让

弹窗不在 `pages` 里，吃不到主界面的 `keyboardShift` 位移，只能自己避让：

```qml
y: {
    const host = parent ? parent.Window.window : null   // Popup 不是 Item，Window.window 取不到
    const kb = host ? host.virtualKeyboard : null
    const centered = parent ? Math.max(0, (parent.height - height) / 2) : 0
    if (!host || !kb || !kb.visible) return centered
    return Math.max(0, Math.min(centered, host.height - kb.y - height - Theme.gap))
}
```

`Main.qml` 为此暴露了 `readonly property var virtualKeyboard: screenKeyboard`。

登录页建号的三张卡片（验 PIN / 填资料 / 恢复码）用同样思路，改成
`y: Math.max(8, Math.min(居中, keyboardTop - height - 12))`。

## 4. 布局抖动：1px 宽度

日志里出现过 `geometry=10.4,10.4 1x503.8` 这类 polish loop——容器被压到 1px 宽，
里面文字按 1px 换行、高度炸到几百，Qt 反复 polish，界面闪一下。

数据页与建号弹窗里共 10 处 `Math.max(1, parent.width - Theme.gap * 2)` 全部改成
`Math.max(240, ...)`。改完两项 UI 审计零告警。

## 5. 计算器历史

见 `48-calc-history-persist-2026-11-02.md`：持久化到 `calc/history`、面板常驻、逐条删除。

## 6. 收尾状态

- 全量测试：72 项 71 通过，只剩 `arkpets_sprite_packing`（环境相关）；
- 本轮所有改动都已构建进 `/tmp/oobe-build/orange_pi_terminal`。
