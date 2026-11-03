import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 管理员配对 / 撤销 / 授权页面（D9b）。
//
// 后端是 C++ 的 securityService 门面：QML 只调 Q_INVOKABLE 方法，
// 由服务端复核管理员身份、用户归属并写审计。本页不持有任何密钥。
Item {
    id: adminPage
    property string message: ""
    // 连接设置里由外层 SettingsGroup 提供标题，避免重复。
    property bool showTitle: true
    // 选中的用户（授权对象）。管理员不得代成员授予健康数据访问，
    // 因此这里只显示用户列表，实际授予会在 C++ 侧再校验。
    property string targetUserId: ""
    // 复用宿主（Main.qml）的 FloatingKeyboard：本页只负责请求打开。
    signal keyboardRequested()

    implicitHeight: column.implicitHeight

    // 后端一变更就重读，避免页面显示过期数据。
    Connections {
        target: securityService
        function onChanged() {
            adminPage.reload()
            // cardBindingRemainingMs() 是 Q_INVOKABLE，不是带 NOTIFY 的属性；
            // 必须在 changed 里显式同步，否则弹窗/倒计时永远不会被触发。
            const active = securityService.cardBindingRemainingMs() > 0
            adminPage.bindWindowOpen = active
            if (active) {
                if (!bindWaitingDialog.opened) bindWaitingDialog.open()
            } else if (bindWaitingDialog.opened) {
                bindWaitingDialog.close()
            }
        }
    }

    function reload() {
        bridgeModel.clear()
        for (const entry of securityService.trustedBridges()) bridgeModel.append(entry)
        cardModel.clear()
        for (const entry of securityService.boundCards()) cardModel.append(entry)
        auditModel.clear()
        for (const entry of securityService.recentAudit(20)) auditModel.append(entry)
    }

    // 绑卡窗口倒计时：每秒推进一次，驱动文案刷新。
    property int bindingTick: 0
    property bool bindWindowOpen: false
    Timer {
        id: bindingTimer
        interval: 250; repeat: true
        running: adminPage.bindWindowOpen
        onTriggered: {
            adminPage.bindingTick += 1
            if (securityService.cardBindingRemainingMs() <= 0) {
                adminPage.bindWindowOpen = false
                if (bindWaitingDialog.opened) bindWaitingDialog.close()
            }
        }
    }

    Component.onCompleted: reload()

    ListModel { id: bridgeModel }
    ListModel { id: cardModel }
    ListModel { id: auditModel }

    ColumnLayout {
        id: column
        // 隐藏页初始化时父级可能是 0 宽；0 宽下换行文本的高度会与布局互相
        // 反馈，Qt 6.5 报 Layout polish loop。给一个可用的测量宽度。
        width: Math.max(240, parent.width * 1)
        spacing: Theme.gap

        CarText {
            Layout.fillWidth: true
            visible: adminPage.showTitle
            text: I18n.t("设备配对与撤销")
            fontPixelSize: Theme.title
            color: Theme.foreground
        }

        // 管理员才能进：普通用户看到明确的拒绝，不是空页面。
        CarText {
            Layout.fillWidth: true
            visible: !sessionManager.isAdmin
            text: I18n.t("需要管理员权限")
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
        }

        // 信任库损坏必须报警：它会拒掉所有桥板，但看起来像"还没配对过"。
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin && !securityService.healthy()
            text: I18n.t("信任库已损坏，所有桥板都会被拒绝")
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        CarText {
            Layout.fillWidth: true
            visible: adminPage.message.length > 0
            text: adminPage.message
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        // ---- 配对新设备 ----
        // 手动登记（Bridge ID + 公钥）已移到开发者选项；
        // 桥板自报身份尚未在协议中定义，自动获取按钮保持 disabled。
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin
            text: I18n.t("配对新设备")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap / 2
            visible: sessionManager.isAdmin
            CarButton {
                objectName: "pairBridgeAuto"
                text: I18n.t("从桥板获取")
                enabled: false
                onClicked: {}
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("手动登记已移到开发者选项；自动获取等待协议支持。")
                subdued: true
                wrapMode: Text.WordWrap
                fontPixelSize: Theme.fontCaption
            }
        }

        // ---- 已配对桥板 ----
        CarText {
            Layout.fillWidth: true
            text: I18n.t("已配对桥板")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
            visible: sessionManager.isAdmin
        }
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin && bridgeModel.count === 0
            text: I18n.t("还没有配对任何桥板")
            color: Theme.outline
            fontPixelSize: Theme.fontCaption
        }
        Repeater {
            model: bridgeModel
            delegate: RowLayout {
                // ListModel 只提供具名 role；写 `required var modelData` 会让
                // delegate 创建失败（"Required property modelData was not
                // initialized"），整行消失。
                required property string bridgeId
                required property string fingerprint
                Layout.fillWidth: true
                CarText {
                    Layout.fillWidth: true
                    text: bridgeId + I18n.t("，") + fingerprint
                    color: Theme.foreground
                    fontPixelSize: Theme.fontLabel
                    elide: Text.ElideMiddle
                    maximumLineCount: 1
                }
                CarButton {
                    text: I18n.t("撤销")
                    enabled: sessionManager.isAdmin
                    onClicked: {
                        if (securityService.revokeBridge(fingerprint))
                            adminPage.message = ""
                        else
                            adminPage.message = securityService.lastMessage
                    }
                }
            }
        }

        // ---- 卡绑定 ----
        CarText {
            Layout.fillWidth: true
            // 这是分区标题，不是"绑定成功"的状态；带上数量避免误解。
            text: cardModel.count > 0
                  ? I18n.t("已绑定卡片") + " (" + cardModel.count + ")"
                  : I18n.t("卡片绑定")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
            visible: sessionManager.isAdmin
        }
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin && cardModel.count === 0
            text: I18n.t("还没有绑定任何卡")
            color: Theme.outline
            fontPixelSize: Theme.fontCaption
            wrapMode: Text.WordWrap
        }
        Repeater {
            model: cardModel
            delegate: RowLayout {
                required property string label
                required property string rawUidHex
                Layout.fillWidth: true
                CarText {
                    Layout.fillWidth: true
                    text: label
                    color: Theme.foreground
                    fontPixelSize: Theme.fontLabel
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                CarButton {
                    text: I18n.t("挂失")
                    enabled: sessionManager.isAdmin
                    onClicked: {
                        securityService.revokeCard(rawUidHex)
                        adminPage.reload()
                    }
                }
            }
        }
        CarButton {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            text: I18n.t("全部挂失")
            visible: sessionManager.isAdmin && cardModel.count > 0
            onClicked: {
                securityService.revokeAllCards()
                adminPage.reload()
            }
        }

        // ---- 绑定卡片（D 写：重验 PIN + 30 秒单次窗口，M3 表单语义）----
        CarButton {
            objectName: "bindCardButton"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            text: I18n.t("绑定卡片")
            visible: sessionManager.isAdmin
            enabled: sessionManager.isAdmin && securityService.cardBindingRemainingMs() <= 0
            onClicked: { bindPinField.text = ""; bindPinError.text = ""; bindPinDialog.open() }
        }
        CarText {
            objectName: "bindCardCountdown"
            Layout.fillWidth: true
            visible: securityService.cardBindingRemainingMs() > 0
            text: I18n.t("请在 %1 秒内刷卡；绑定成功后窗口自动关闭")
                      .arg(Math.ceil(securityService.cardBindingRemainingMs() / 1000))
                      + " (" + adminPage.bindingTick + ")"
            color: Theme.accent
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        // ---- 审计 ----
        CarText {
            Layout.fillWidth: true
            text: I18n.t("最近操作")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
            visible: sessionManager.isAdmin && auditModel.count > 0
        }
        Repeater {
            model: auditModel
            delegate: CarText {
                required property string action
                required property string result
                Layout.fillWidth: true
                text: action + I18n.t("，") + result
                color: result === "ok" ? Theme.foreground : Theme.warning
                fontPixelSize: Theme.fontCaption
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    // 绑卡前重验 PIN：不消耗登录尝试次数（sessionManager.verifyPin）。
    Popup {
        id: bindPinDialog
        objectName: "bindPinDialog"
        parent: Overlay.overlay
        // 键盘可见时上移到键盘上方（弹窗不在 pages 里，吃不到主界面的位移）。
        x: parent ? (parent.width - width) / 2 : 0
        y: {
            // Popup 不是 Item，Window.window 在它上面拿不到；从 parent（overlay）取。
            const host = parent ? parent.Window.window : null
            const kb = host ? host.virtualKeyboard : null
            const centered = parent ? Math.max(0, (parent.height - height) / 2) : 0
            if (!host || !kb || !kb.visible) return centered
            return Math.max(0, Math.min(centered, host.height - kb.y - height - Theme.gap))
        }
        modal: true
        dim: true
        closePolicy: Popup.CloseOnEscape
        padding: Theme.gap
        width: Math.min(420 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                text: I18n.t("绑定卡片前请重新输入 PIN")
                fontPixelSize: Theme.fontLabel
                color: Theme.foreground
                wrapMode: Text.WordWrap
            }
            CarField { plainHint: true
                id: bindPinField
                objectName: "bindPinField"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("PIN")
                // 点输入框即唤起项目内置屏幕键盘（物理键盘缺席时也能绑卡）。
                onActiveFocusChanged: if (activeFocus) adminPage.keyboardRequested()
                onAccepted: bindPinConfirm.clicked()
            }
            CarText {
                id: bindPinError
                Layout.fillWidth: true
                color: Theme.warning
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                Item { Layout.fillWidth: true }
                CarButton { text: I18n.t("取消"); onClicked: bindPinDialog.close() }
                CarButton {
                    id: bindPinConfirm
                    objectName: "bindPinConfirm"
                    text: I18n.t("确认")
                    accent: true
                    onClicked: {
                        if (!sessionManager.verifyPin(bindPinField.text)) {
                            bindPinError.text = I18n.t("PIN 不正确")
                            return
                        }
                        if (securityService.openCardBindingWindow()) {
                            bindPinDialog.close()
                        } else {
                            bindPinError.text = securityService.lastMessage || I18n.t("操作失败")
                        }
                    }
                }
            }
        }
    }

    // 刷卡指引：PIN 确认后弹出，明确告诉用户"现在刷卡"、剩余时间，并可取消。
    // 之前只有一行小字倒计时，用户很容易以为没反应。
    Popup {
        id: bindWaitingDialog
        objectName: "bindWaitingDialog"
        parent: Overlay.overlay
        anchors.centerIn: Overlay.overlay
        modal: true
        dim: true
        closePolicy: Popup.NoAutoClose
        padding: Theme.gap
        width: Math.min(420 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.accent
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            MaterialIcon {
                name: "verified_user"
                Layout.preferredWidth: 40 * Theme.scaleFactor
                Layout.preferredHeight: 40 * Theme.scaleFactor
                Layout.alignment: Qt.AlignHCenter
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("请将 NFC 卡贴近读卡器")
                fontPixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("剩余 %1 秒，读到卡后自动绑定")
                          .arg(Math.ceil(securityService.cardBindingRemainingMs() / 1000))
                      + (adminPage.bindingTick >= 0 ? "" : "")
                color: Theme.outline
                fontPixelSize: Theme.fontCaption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            CarButton {
                Layout.fillWidth: true
                text: I18n.t("取消")
                onClicked: securityService.closeCardBindingWindow()
            }
        }
    }
}
