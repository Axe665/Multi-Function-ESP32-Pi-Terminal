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
