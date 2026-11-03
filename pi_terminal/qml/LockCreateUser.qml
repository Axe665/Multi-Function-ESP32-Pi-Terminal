import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 锁屏 / 登录页上的「创建新用户」。
//
// 两步：先验当前管理员 PIN，再填新用户信息，最后给恢复码。
// 恢复码可以直接导出到 U 盘（与开机向导、「其他用户」共用 RecoveryExport）。
//
// 刻意不用 Popup：本页所在的 LoginPage / LockScreen 是由 Loader 动态加载的，
// 这类上下文里 Overlay.overlay 解析不到，Popup 会挂到错误的层上——表现为
// 「弹出来了但整屏发暗、点什么都没反应」。改成自己画的全屏覆盖层，层级完全可控。
Item {
    id: root
    objectName: "lockCreateUser"

    anchors.fill: parent
    z: 30000
    visible: root.stage !== ""

    // "" 关闭；"auth" 验 PIN；"form" 填资料；"code" 恢复码
    property string stage: ""
    property string createdCode: ""
    property string createdName: ""

    signal keyboardRequested()

    // 键盘在本覆盖层坐标系里的上沿；键盘没弹出时退化为整个高度。
    readonly property real keyboardTop: {
        const host = Window.window
        const kb = host ? host.virtualKeyboard : null
        if (!host || !kb || !kb.visible) return root.height
        return Math.min(root.height, kb.y)
    }

    // 登录页没有「当前用户」，所以必须指明用哪个管理员的 PIN 来验证。
    property string adminUserId: ""

    function adminUsers() {
        const out = []
        const users = (typeof sessionManager !== "undefined" && sessionManager) ? sessionManager.users : []
        for (let i = 0; i < users.length; ++i) {
            const user = users[i]
            if (user && user.admin && !user.disabled) out.push(user)
        }
        return out
    }

    function defaultAdminId() {
        const list = root.adminUsers()
        if (list.length === 0) return ""
        for (let i = 0; i < list.length; ++i)
            if (list[i].userId === sessionManager.activeUserId) return list[i].userId
        return list[0].userId
    }

    function openAuth() {
        root.adminUserId = root.defaultAdminId()
        adminPin.text = ""
        authError.text = ""
        root.stage = "auth"
    }

    function close() {
        root.stage = ""
    }

    function submitCreate() {
        const name = newName.text.trim()
        if (name.length < 2) { formError.text = I18n.t("名字至少需要 2 个字符"); return }
        const out = sessionManager.createUserAs(root.adminUserId, name, newPin.text, newAdmin.checked)
        if (!out || !out.userId) {
            formError.text = sessionManager.message || I18n.t("创建失败")
            return
        }
        root.createdCode = out.recoveryCode || ""
        root.createdName = name
        root.stage = "code"
    }

    function codeGroup(index) {
        const parts = root.createdCode.split("-")
        return index < parts.length ? parts[index] : ""
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent }
    }

    // ---- 第一步：验证管理员 PIN ----
    Rectangle {
        visible: root.stage === "auth"
        x: (root.width - width) / 2
        y: Math.max(8, Math.min((root.height - height) / 2, root.keyboardTop - height - 12))
        width: Math.min(420 * Theme.scaleFactor, Math.max(240, root.width - Theme.gap * 4))
        height: authColumn.implicitHeight + Theme.gap * 2
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outline
        border.width: 1

        ColumnLayout {
            id: authColumn
            x: Theme.gap
            y: Theme.gap
            width: Math.max(240, parent.width - Theme.gap * 2)
            spacing: Theme.gap / 2

            CarText {
                Layout.fillWidth: true
                text: I18n.t("创建新用户")
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("需要先验证当前管理员 PIN")
                subdued: true
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            Column {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: root.adminUsers()
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool picked: root.adminUserId === modelData.userId
                        width: parent.width
                        height: 44 * Theme.scaleFactor
                        radius: Theme.shapeMedium
                        color: picked ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                        border.width: 1
                        border.color: picked ? Theme.accent : Theme.outlineVariant
                        CarText {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gap / 2
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.displayName
                            fontPixelSize: Theme.body
                            color: Theme.foreground
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.adminUserId = modelData.userId
                        }
                    }
                }
            }
            CarField {
                id: adminPin
                objectName: "lockCreateUserAdminPin"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("管理员 PIN")
                onKeyboardRequested: root.keyboardRequested()
            }
            CarText {
                id: authError
                Layout.fillWidth: true
                color: Theme.danger
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    Layout.fillWidth: true
                    text: I18n.t("取消")
                    onClicked: root.close()
                }
                CarButton {
                    objectName: "lockCreateUserContinue"
                    Layout.fillWidth: true
                    text: I18n.t("继续")
                    accent: true
                    onClicked: {
                        if (!sessionManager.verifyAdminPinFor(root.adminUserId, adminPin.text)) {
                            authError.text = I18n.t("PIN 不正确")
                            return
                        }
                        authError.text = ""
                        adminPin.text = ""
                        root.stage = "form"
                    }
                }
            }
        }
    }

    // ---- 第二步：填新用户信息 ----
    Rectangle {
        visible: root.stage === "form"
        x: (root.width - width) / 2
        y: Math.max(8, Math.min((root.height - height) / 2, root.keyboardTop - height - 12))
        width: Math.min(460 * Theme.scaleFactor, Math.max(240, root.width - Theme.gap * 4))
        height: formColumn.implicitHeight + Theme.gap * 2
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outline
        border.width: 1

        ColumnLayout {
            id: formColumn
            x: Theme.gap
            y: Theme.gap
            width: Math.max(240, parent.width - Theme.gap * 2)
            spacing: Theme.gap / 2

            CarText {
                Layout.fillWidth: true
                text: I18n.t("新用户")
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
            CarField {
                id: newName
                objectName: "lockCreateUserName"
                Layout.fillWidth: true
                placeholderText: I18n.t("显示名")
                onKeyboardRequested: root.keyboardRequested()
            }
            CarField {
                id: newPin
                objectName: "lockCreateUserPin"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("初始 PIN（至少 6 位数字）")
                onKeyboardRequested: root.keyboardRequested()
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText { Layout.fillWidth: true; text: I18n.t("设为管理员"); color: Theme.foreground; fontPixelSize: Theme.body }
                Switch { id: newAdmin; objectName: "lockCreateUserAdmin"; implicitHeight: Theme.hit }
            }
            CarText {
                id: formError
                Layout.fillWidth: true
                color: Theme.danger
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    Layout.fillWidth: true
                    text: I18n.t("取消")
                    onClicked: root.close()
                }
                CarButton {
                    objectName: "lockCreateUserSubmit"
                    Layout.fillWidth: true
                    text: I18n.t("创建")
                    accent: true
                    onClicked: root.submitCreate()
                }
            }
        }
    }

    // ---- 第三步：一次性恢复码 ----
    Rectangle {
        visible: root.stage === "code"
        x: (root.width - width) / 2
        y: Math.max(8, Math.min((root.height - height) / 2, root.keyboardTop - height - 12))
        width: Math.min(560 * Theme.scaleFactor, Math.max(240, root.width - Theme.gap * 4))
        height: codeColumn.implicitHeight + Theme.gap * 2
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.warning
        border.width: 1

        ColumnLayout {
            id: codeColumn
            x: Theme.gap
            y: Theme.gap
            width: Math.max(240, parent.width - Theme.gap * 2)
            spacing: Theme.gap / 2

            CarText {
                Layout.fillWidth: true
                text: I18n.t("恢复码（只显示一次）")
                fontPixelSize: Theme.title
                color: Theme.warning
            }
            Grid {
                columns: 3
                rowSpacing: Theme.gap / 2
                columnSpacing: Theme.gap * 1.2
                Repeater {
                    model: 6
                    Text {
                        required property int index
                        text: root.codeGroup(index)
                        color: Theme.foreground
                        font.family: "monospace"
                        font.pointSize: 16 * Theme.scaleFactor
                        font.letterSpacing: 2
                    }
                }
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("交给新用户保管：忘记 PIN 时，这是唯一能找回数据的方式。")
                subdued: true
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            RecoveryExport {
                Layout.fillWidth: true
                recoveryCode: root.createdCode
                userName: root.createdName
            }
            CarButton {
                objectName: "lockCreateUserDone"
                Layout.fillWidth: true
                text: I18n.t("我已抄写")
                accent: true
                onClicked: recoveryAckConfirm.open()
            }
        }
    }

    // 「我已抄写」的 5 秒确认：同样用自绘覆盖层，不依赖 Overlay。
    Item {
        id: recoveryAckConfirm
        anchors.fill: parent
        z: 1

        property int cooldown: 5

        function open() { cooldown = 5; visible = true }
        function close() { visible = false }

        visible: false

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(460 * Theme.scaleFactor, Math.max(240, recoveryAckConfirm.width - Theme.gap * 4))
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

                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("确认已保存恢复码？")
                    fontPixelSize: Theme.title
                    color: Theme.foreground
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("关闭后恢复码不会再次显示。请确认已经抄写，或已经导出到 U 盘。")
                    color: Theme.warning
                    fontPixelSize: Theme.fontLabel
                    wrapMode: Text.WordWrap
                }
                CarText {
                    Layout.fillWidth: true
                    text: recoveryAckConfirm.cooldown > 0
                          ? I18n.t("冷静期") + " " + recoveryAckConfirm.cooldown + " " + I18n.t("秒")
                          : I18n.t("可以确认了")
                    color: recoveryAckConfirm.cooldown > 0 ? Theme.warning : Theme.outline
                    fontPixelSize: Theme.fontCaption
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    CarButton {
                        Layout.fillWidth: true
                        text: I18n.t("返回")
                        onClicked: recoveryAckConfirm.close()
                    }
                    CarButton {
                        objectName: "lockCreateUserAck"
                        Layout.fillWidth: true
                        text: I18n.t("确认已保存")
                        accent: true
                        enabled: recoveryAckConfirm.cooldown <= 0
                        onClicked: {
                            root.createdCode = ""
                            recoveryAckConfirm.close()
                            root.close()
                        }
                    }
                }
            }
        }

        Timer {
            interval: 1000
            repeat: true
            running: recoveryAckConfirm.visible && recoveryAckConfirm.cooldown > 0
            onTriggered: recoveryAckConfirm.cooldown--
        }
    }
}
