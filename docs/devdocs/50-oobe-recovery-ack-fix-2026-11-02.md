# OOBE 恢复码确认：卡死修复（2026-11-02）

## 问题

首次开机向导第 3 步（保存恢复码）点「已抄写」直接卡死：屏幕变暗、什么都不出现、点哪儿都没反应。

## 原因

这一步用的是共享的 `RecoveryAckConfirm`，它是个 `Popup`。

但 `OnboardingWizard` 是由 `Main` 的 `Loader` 动态加载的（`active: onboarding.active && startupComplete`）。
这种上下文里 `Overlay.overlay` 解析不到，Popup 的模态遮罩变成一层吃点击的暗色矩形，
内容却因为父级尺寸为 0 而不渲染——和之前登录页建号那次是同一个坑。

## 修复

`RecoveryStep.qml` 不再用 Popup，改成页内自绘覆盖层：

```qml
Item {
    id: ackOverlay
    anchors.fill: parent
    z: 10
    visible: false
    property int cooldown: 5
    function open() { cooldown = 5; visible = true }
    function close() { visible = false }
    Rectangle { /* 半透明底 + MouseArea 吃掉点击 */ }
    Rectangle {
        /* 卡片：标题 / 说明 / 倒计时 / 返回 + 确认已保存 */
    }
    Timer { /* 每秒减 cooldown */ }
}
```

主按钮改为 `onPrimaryAction: ackOverlay.open()`，确认后 `wizard.goTo(3)`。

顺带把主按钮文案从「已抄写，继续」改成 **「已抄写或已保存，继续」**——
导出到 U 盘的人不必假装自己抄过。

## 验证

真机 1024×600，空用户环境走到第 3 步：

1. 按钮显示「已抄写或已保存，继续」；
2. 点击 → 弹出确认卡片「确认已保存恢复码？」，带「冷静期 3 秒」倒计时，背景变暗但**不卡死**；
3. 等待倒计时结束后确认 → 正常进入第 4 步「网络连接」。

![确认层](orpi-study/orpi-terminal-complete-20261101/orpi-terminal-20261031/pi-terminal/docs/devdocs/account-shots/onboarding-ack-layer.png)

![确认后进入第 4 步](orpi-study/orpi-terminal-complete-20261101/orpi-terminal-20261031/pi-terminal/docs/devdocs/account-shots/onboarding-step4.png)
