import QtQuick
import QtQuick.Layouts

// 第 2 步：管理员显示名 + 6 位 PIN（两次输入）。
// PIN 复用 PinPad；两次不一致时留在本页，错误显示在键盘上方。
Item {
    id: step
    property var wizard
    property string primaryLabel: I18n.t("下一步")
    property bool primaryEnabled: step.pinConfirmed && nameField.text.trim().length >= 2
    property bool canGoBack: true

    property int phase: 0          // 0 = 设 PIN，1 = 再输一次
    property string pinFirst: ""
    property bool pinConfirmed: false

    signal primaryAction()
    onPrimaryAction: {
        if (!step.pinConfirmed) return
        const name = nameField.text.trim()
        if (name.length < 2 || name.length > 24) return
        wizard.displayName = name
        wizard.pin = step.pinFirst
        wizard.goTo(2)
    }

    RowLayout {
        width: parent.width
        spacing: Theme.gap * 1.5

        Column {
            Layout.fillWidth: true
            spacing: Theme.gap

            Text {
                width: parent.width
                text: I18n.t("设置管理员")
                color: Theme.foreground
                font.pointSize: Theme.title
                font.weight: Font.Medium
            }
            Text {
                width: parent.width
                text: I18n.t("管理员可以添加用户、修改联网权限。")
                color: Theme.secondary
                opacity: 0.78
                font.pointSize: Theme.body
                lineHeight: 1.4
                wrapMode: Text.WordWrap
            }

            CarField {
                id: nameField
                width: parent.width
                text: I18n.t("管理员")
                maximumLength: 24
                placeholderText: I18n.t("显示名")
                onActiveFocusChanged: if (activeFocus) wizard.showKeyboard(true, false)
            }

            Text {
                width: parent.width
                text: step.phase === 0 ? I18n.t("在右侧设置 6 位数字 PIN")
                                        : I18n.t("再输一次 PIN 确认")
                color: Theme.accent
                font.pointSize: Theme.body * 0.9
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                visible: nameField.text.trim().length < 2
                text: I18n.t("名字至少需要 2 个字符")
                color: Theme.danger
                font.pointSize: Theme.body * 0.85
                wrapMode: Text.WordWrap
            }
        }

        PinPad {
            id: pinPad
            // 跟上 0.75 的界面缩放：登录页会按窗口高度再收一次，这里给向导的
            // 触屏热区留出与字段同级的分量。
            Layout.preferredWidth: pinPad.keySize * 3 + Theme.gap
            Layout.alignment: Qt.AlignVCenter
            keySize: Math.max(Theme.hit, 68 * Theme.scaleFactor)
            showCancel: false
            placeholderText: step.phase === 0 ? I18n.t("输入 6 位数字") : I18n.t("再输一次")
            busyText: I18n.t("正在创建…")
            onSubmitted: function(pin) {
                if (step.phase === 0) {
                    step.pinFirst = pin
                    step.phase = 1
                    pinPad.message = ""
                    pinPad.messageIsError = false
                } else if (pin !== step.pinFirst) {
                    pinPad.message = I18n.t("两次输入不一致，请重新输入")
                    pinPad.messageIsError = true
                } else {
                    pinPad.message = ""
                    pinPad.messageIsError = false
                    step.pinConfirmed = true
                    step.primaryAction()
                }
            }
        }
    }
}
