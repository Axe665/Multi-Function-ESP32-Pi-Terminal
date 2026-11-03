import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 首次开机向导（OOBE）。只在“注册表里一个用户都没有”时由 Main.qml 加载，
// 挂在 Overlay.overlay 的 Loader 上（z=50000），盖住 SessionGate（z=20000）。
//
// 数据流：WelcomeStep → AdminStep（名字 + PIN×2）→ RecoveryStep（恢复码）
//        → NetworkStep（只读状态）→ DoneStep（最后一次点击才落盘）。
// 所有“是否需要向导 / 恢复码 / 创建结果 / 自动登录”都在 OnboardingController，
// 本文件只做步骤编排与视觉。
Item {
    id: wizard
    objectName: "onboardingWizard"

    property int step: 0
    property string displayName: ""
    property string pin: ""
    property var hostWindow: null

    readonly property real contentWidth: Math.min(720, width - Theme.margin * 2)
    readonly property var stepFiles: [
        "WelcomeStep.qml", "AdminStep.qml", "RecoveryStep.qml", "NetworkStep.qml", "DoneStep.qml"
    ]

    function goTo(index) {
        if (index < 0 || index >= stepFiles.length) return
        hideKeyboard()
        step = index
    }
    function showKeyboard(chinese, upper) {
        onboardKeyboard.chineseMode = chinese
        onboardKeyboard.uppercase = upper
        onboardKeyboard.show()
    }
    function hideKeyboard() { onboardKeyboard.hide() }

    // 底：纯色背景 + 吞掉点击，保证向导期间桌面收不到任何输入。
    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    ProgressHeader {
        id: header
        anchors.horizontalCenter: parent.horizontalCenter
        // 全屏向导按屏幕高度定位，不乘界面缩放：缩放只影响字号与热区，
        // 若纵向坐标也乘 0.75，底部按钮会被顶到软键盘（y≈256-524）里。
        y: 28
        width: wizard.contentWidth
        step: wizard.step
        total: wizard.stepFiles.length
    }

    Loader {
        id: stepLoader
        anchors.horizontalCenter: parent.horizontalCenter
        y: 88
        width: wizard.contentWidth
        height: Math.max(320, wizard.height - 88 - Theme.hit - Theme.margin * 2)
        source: wizard.stepFiles[wizard.step]
        onLoaded: {
            if (item) item.wizard = wizard
        }
    }

    RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        y: wizard.height - Theme.hit - Theme.margin
        width: wizard.contentWidth
        height: Theme.hit
        spacing: Theme.gap

        CarButton {
            text: I18n.t("返回")
            visible: stepLoader.item ? stepLoader.item.canGoBack : false
            onClicked: wizard.goTo(wizard.step - 1)
        }
        Item { Layout.fillWidth: true }
        CarButton {
            text: stepLoader.item ? stepLoader.item.primaryLabel : ""
            accent: true
            enabled: stepLoader.item ? stepLoader.item.primaryEnabled : false
            onClicked: {
                if (stepLoader.item) stepLoader.item.primaryAction()
            }
        }
    }

    // 电源入口：破坏性操作，二次确认；不打断当前步骤。
    IconButton {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.margin
        iconName: "power"
        label: I18n.t("电源")
        onClicked: powerDialog.open()
    }

    Dialog {
        id: powerDialog
        parent: Overlay.overlay
        z: 60000
        modal: true
        closePolicy: Popup.NoAutoClose
        width: Math.min(460 * Theme.scaleFactor, wizard.width - Theme.gap * 2)
        height: powerColumn.implicitHeight + topPadding + bottomPadding
        x: (wizard.width - width) / 2
        y: (wizard.height - height) / 2
        padding: Theme.shapeExtraLarge
        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeExtraLarge
            border.width: 2
            border.color: Theme.warning
        }
        contentItem: Column {
            id: powerColumn
            spacing: Theme.gap
            Text {
                width: parent.width
                text: I18n.t("电源")
                color: Theme.foreground
                font.pointSize: Theme.title
            }
            Text {
                width: parent.width
                text: I18n.t("设置尚未完成，现在关机不会创建管理员。")
                color: Theme.secondary
                opacity: 0.78
                font.pointSize: Theme.body * 0.9
                lineHeight: 1.35
                wrapMode: Text.WordWrap
            }
            Row {
                spacing: Theme.gap
                CarButton {
                    text: I18n.t("关机")
                    onClicked: {
                        powerDialog.close()
                        systemTools.requestPowerAction("poweroff")
                    }
                }
                CarButton {
                    text: I18n.t("重启")
                    onClicked: {
                        powerDialog.close()
                        systemTools.requestPowerAction("reboot")
                    }
                }
                CarButton {
                    text: I18n.t("取消")
                    accent: true
                    onClicked: powerDialog.close()
                }
            }
        }
    }

    // 恢复码确认层：放在向导根上天然全屏，不依赖步骤页（Loader 里的窄列）的定位。
    // 步骤页自己做遮罩会盖不满窗口：外围点不动、确认按钮又因倒计时不跑而灰着，
    // 两件事叠在一起就是"点已抄写卡死"。
    Item {
        id: recoveryAck
        objectName: "onboardingRecoveryAckLayer"
        anchors.fill: parent
        z: 20
        visible: false

        property int cooldown: 5
        property double startedAt: 0

        function open() {
            cooldown = 5
            startedAt = Date.now()
            visible = true
            ackTimer.start()
        }
        function close() {
            ackTimer.stop()
            visible = false
        }

        // 用时间戳算剩余，不用 Timer.running 绑定：旧写法在某些环境里
        // running 没被求值，cooldown 永远停在 5，确认按钮一直是灰的。
        Timer {
            id: ackTimer
            interval: 250
            repeat: true
            onTriggered: {
                const left = 5 - Math.floor((Date.now() - recoveryAck.startedAt) / 1000)
                recoveryAck.cooldown = Math.max(0, left)
                if (recoveryAck.cooldown <= 0) stop()
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(460 * Theme.scaleFactor, Math.max(240, parent.width - Theme.gap * 4))
            height: ackColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1

            ColumnLayout {
                id: ackColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                Text {
                    width: ackColumn.width
                    text: I18n.t("确认已保存恢复码？")
                    color: Theme.foreground
                    font.pointSize: Theme.title
                    font.weight: Font.Medium
                }
                Text {
                    width: ackColumn.width
                    text: I18n.t("关闭后恢复码不会再次显示。请确认已经抄写，或已经导出到 U 盘。")
                    color: Theme.warning
                    font.pointSize: Theme.body * 0.85
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: ackColumn.width
                    text: recoveryAck.cooldown > 0
                          ? I18n.t("冷静期") + " " + recoveryAck.cooldown + " " + I18n.t("秒")
                          : I18n.t("可以确认了")
                    color: recoveryAck.cooldown > 0 ? Theme.warning : Theme.secondary
                    font.pointSize: Theme.body * 0.78
                }
                RowLayout {
                    // 用显式宽度而不是 Layout.fillWidth：ColumnLayout 里那套在
                    // 带固定宽度的子项上会让按钮撑出卡片边框（真机截图可见）。
                    width: ackColumn.width
                    spacing: Theme.gap / 2
                    CarButton {
                        Layout.fillWidth: true
                        text: I18n.t("返回")
                        onClicked: recoveryAck.close()
                    }
                    CarButton {
                        objectName: "onboardingRecoveryAckConfirm"
                        Layout.fillWidth: true
                        text: I18n.t("确认已保存")
                        accent: true
                        enabled: recoveryAck.cooldown <= 0
                        onClicked: {
                            recoveryAck.close()
                            wizard.goTo(3)
                        }
                    }
                }
            }
        }
    }

    // 步骤页通过这个入口叫起确认层。
    function showRecoveryAck() { recoveryAck.open() }

    // 向导自己的键盘实例：parent 设为向导根，让 Popup 的 z 在本层内比较，
    // 从而压在向导内容之上。不碰 Main.qml 里那个全局 screenKeyboard（z=2000）。
    FloatingKeyboard {
        id: onboardKeyboard
        parent: wizard
        // Popup 的 z 与 Overlay 下的普通 item 同层比较（项目里门禁/弹窗都靠
        // 这个规则），所以要压在 OOBE Loader(z=50000) 之上必须显式给 51000。
        z: 51000
        hostWindow: wizard.hostWindow
        uiScale: Theme.scaleFactor
    }
}
