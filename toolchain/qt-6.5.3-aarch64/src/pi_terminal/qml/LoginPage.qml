import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 登录页：选人 → PIN。刷卡只能跳到这里，不能直接登录。
// 版式参考 ChromeOS 登录：居中头像/姓名，大号数字键盘，左下角电源、右下角更多菜单。
// 提示文案不含姓名以外的读数、精确位置（§2）。
Item {
    id: loginPage
    // 显式跟随 Loader 的尺寸。原先靠 Loader 的 anchors.fill 隐式设置，
    // 实测在子元素的计算上下文里读到的 height 是 0（按钮的 y 被算成 -150），
    // 而用 anchors.centerIn 的元素看起来又正常——两者矛盾，索性把尺寸写死。
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    property var users: []
    property string selectedUserId: ""
    property string selectedDisplayName: ""
    // 刷卡选中的用户：进入本页时直接预选，但仍必须输入 PIN。
    property string preSelectedUserId: ""
    property string preSelectedDisplayName: ""
    // 每次刷卡递增；即使 preSelectedUserId 没变，也重新进入该用户的 PIN 页。
    property int cardSelectSeq: 0
    onPreSelectedUserIdChanged: {
        if (preSelectedUserId === "") return
        loginPage.selectUser(preSelectedUserId)
        // 名单还没刷新到时也要能刷卡进入该用户的 PIN 页（仍必须输 PIN）。
        if (loginPage.selectedUserId === "") {
            loginPage.selectedUserId = preSelectedUserId
            loginPage.selectedDisplayName = preSelectedDisplayName
            loginPage.attempted = false
        }
    }
    onCardSelectSeqChanged: {
        if (cardSelectSeq <= 0 || preSelectedUserId === "") return
        loginPage.selectUser(preSelectedUserId)
        if (loginPage.selectedUserId === "") {
            loginPage.selectedUserId = preSelectedUserId
            loginPage.selectedDisplayName = preSelectedDisplayName
            loginPage.attempted = false
        }
    }
    property string message: ""
    property bool messageIsError: false
    property bool busy: false

    // 服务端返回的剩余等待时间（毫秒）；> 0 时禁用键盘并倒计时。
    property int retryAfterMs: 0

    // 只在本次选人后显示服务端提示，避免把上一个用户的错误带到下一个人。
    property bool attempted: false

    readonly property bool choosing: loginPage.selectedUserId === ""
    readonly property string selectedAvatar: {
        for (const user of loginPage.users)
            if (user.userId === loginPage.selectedUserId) return user.avatarSource || ""
        return ""
    }
    readonly property real avatarSize: Math.min(120 * Theme.scaleFactor, height * 0.2)
    readonly property real keySize: Math.max(Theme.hit, Math.min(64 * Theme.scaleFactor, height * 0.107))
    // 左右两栏等宽、间距固定：整组几何居中时分栏缝隙正好落在页面中心。
    // 之前左栏 260、右栏 360，整组虽然居中，但分栏缝偏左约 50px，看起来"左轻右重"。
    readonly property real columnWidth: 360 * Theme.scaleFactor
    readonly property real columnGap: Theme.gap * 3
    readonly property string versionText: I18n.t("树莓派终端")
        + (Qt.application.version.length > 0 ? " " + Qt.application.version : "")

    signal pinSubmitted(string userId, string pin)
    signal keyboardRequested()
    // 忘记 PIN：用恢复码登录（仍需服务端验证；成功后强制改 PIN）。
    signal recoveryRequested(string userId)
    // 访客登录：会话由 SessionGate 建立（那里才看得到 sessionManager）。
    signal guestRequested()
    signal cancelled()
    signal refreshRequested()
    signal powerRequested()

    function selectUser(userId) {
        for (const user of loginPage.users) {
            if (user.userId !== userId) continue
            loginPage.selectedUserId = user.userId
            loginPage.selectedDisplayName = user.displayName
            loginPage.attempted = false
            return
        }
    }

    function clearSelection() {
        loginPage.selectedUserId = ""
        loginPage.selectedDisplayName = ""
        loginPage.attempted = false
        if (pinPad) pinPad.clear()
    }

    onUsersChanged: {
        if (loginPage.selectedUserId.length > 0) {
            let found = false
            for (const user of loginPage.users)
                if (user.userId === loginPage.selectedUserId) found = true
            if (!found) loginPage.clearSelection()
        }
    }

    // 已选人时返回用户列表；ChromeOS 的返回箭头位置。
    IconButton {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: Theme.margin / 2
        anchors.leftMargin: Theme.margin / 2
        visible: !loginPage.choosing
        iconName: "arrow_back"
        label: I18n.t("返回选择用户")
        onClicked: loginPage.clearSelection()
    }

    // 登录页就是用户口中的「锁屏」：还没登录时也能建号，但要先验管理员 PIN。
    IconButton {
        objectName: "loginCreateUser"
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Theme.margin / 2
        anchors.rightMargin: Theme.margin / 2
        iconName: "person_add"
        label: I18n.t("创建新用户")
        onClicked: loginCreateUserPanel.openAuth()
    }

    LockCreateUser {
        id: loginCreateUserPanel
        onKeyboardRequested: loginPage.keyboardRequested()
    }

    // 选择用户阶段的大标题。左右分栏改造时它被连带隐藏过两次，
    // 现在独立锚在根级、只在 choosing 时出现，与左下角用户列表共存。
    CarText {
        id: loginTitle
        objectName: "loginTitle"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -60 * Theme.scaleFactor
        visible: choosing
        text: I18n.t("登录")
        fontPixelSize: Theme.hero
        color: Theme.foreground
    }

    // 选择用户：左下角对齐（Google 文档式的左侧栏），竖向排列。
    // 不复用中间的 content 栏——那一栏是给密码区用的，两者不同时出现。
    Item {
        id: userColumn
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.gap * 2
        anchors.bottomMargin: 88 * Theme.scaleFactor   // 给底部状态栏让位
        width: Math.min(parent.width - Theme.gap * 4, 320 * Theme.scaleFactor)
        height: choosing ? picker.implicitHeight : 0
        visible: choosing

        // 访客入口：与用户列表同一条左边线，排在列表下方。
        // 访客入口：MD 描边按钮（outlined），只有一圈 1dp 边和四个字，不带图标。
        Rectangle {
            id: guestFrame
            objectName: "guestLoginFrame"
            anchors.left: parent.left
            anchors.top: picker.bottom
            anchors.topMargin: Theme.gap
            width: Math.min(parent.width, 200 * Theme.scaleFactor)
            height: Theme.hit
            radius: height / 2
            color: guestMouse.pressed ? Theme.surfaceContainerHigh : "transparent"
            border.width: 1
            border.color: guestMouse.containsMouse ? Theme.accent : Theme.outline

            CarText {
                anchors.centerIn: parent
                text: I18n.t("访客登录")
                color: guestMouse.containsMouse ? Theme.accent : Theme.foreground
                fontPixelSize: Theme.body
            }
            MouseArea {
                id: guestMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: loginPage.guestRequested()
                Accessible.role: Accessible.Button
                Accessible.name: I18n.t("以访客身份登录")
            }
        }

        UserPicker {
            id: picker
            anchors.left: parent.left
            anchors.right: parent.right
            alignLeft: true
            users: loginPage.users
            message: loginPage.attempted ? loginPage.message : ""
            onUserChosen: function(userId) { loginPage.selectUser(userId) }
            onRefreshRequested: loginPage.refreshRequested()
        }
    }

    // 登录框：左侧身份、右侧整套密码面板，两栏等宽、整体严格居中。
    RowLayout {
        id: content
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -12 * Theme.scaleFactor
        // 显式给出总宽：等于两栏 preferredWidth 之和加间距，不依赖 implicitWidth
        // （implicitWidth 取子项内容宽度，会把剩余空间留在右侧，导致整组偏左）。
        width: loginPage.columnWidth * 2 + loginPage.columnGap
        spacing: loginPage.columnGap
        visible: !loginPage.choosing

        // ---- 左：身份 ----
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: loginPage.columnWidth
            spacing: Theme.gap

            Avatar {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: loginPage.avatarSize
                Layout.preferredHeight: loginPage.avatarSize
                size: loginPage.avatarSize
                source: loginPage.selectedAvatar
                displayName: loginPage.selectedDisplayName
            }

            CarText {
                Layout.fillWidth: true
                text: loginPage.selectedDisplayName
                fontPixelSize: Theme.hero
                color: Theme.foreground
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }

        // ---- 右：密码面板 ----
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: loginPage.columnWidth
            spacing: Theme.gap

        CarText {
            Layout.fillWidth: true
            visible: loginPage.choosing && loginPage.message.length > 0
            text: loginPage.message
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }


        ColumnLayout {
            Layout.fillWidth: true
            visible: !loginPage.choosing
            spacing: Theme.gap / 2

            PinPad {
                id: pinPad
                Layout.fillWidth: true
                keySize: loginPage.keySize
                showCancel: false
                busy: loginPage.busy || loginPage.retryAfterMs > 0
                message: loginPage.attempted ? loginPage.message : ""
                messageIsError: loginPage.messageIsError
                onSubmitted: function(pin) {
                    loginPage.attempted = true
                    loginPage.pinSubmitted(loginPage.selectedUserId, pin)
                }
                onCancelled: loginPage.clearSelection()
            }

            // 限速倒计时：只显示剩余秒数，不透露账号是否存在。
            CarText {
                Layout.fillWidth: true
                visible: loginPage.retryAfterMs > 0
                text: I18n.t("请等待") + " " + Math.ceil(loginPage.retryAfterMs / 1000) + " " + I18n.t("秒")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
            }

            // 恢复码入口：和 PIN 键盘同在右栏，弱化为文字链接。
            CarText {
                objectName: "recoveryCodeEntry"
                Layout.fillWidth: true
                text: I18n.t("使用恢复码")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
                TapHandler {
                    onTapped: loginPage.recoveryRequested(loginPage.selectedUserId)
                }
            }
        }
    }

    Popup {
        id: moreMenu
        // SessionGate 在 Overlay 里 z=20000；登录页自己的弹层必须更高才不会被门禁遮住。
        z: 30000
        width: 240 * Theme.scaleFactor
        height: menuColumn.implicitHeight + padding * 2
        padding: 8 * Theme.scaleFactor
        x: Math.max(Theme.margin, loginPage.width - width - Theme.margin)
        y: loginPage.height - height - Theme.margin / 2 - Theme.hit - Theme.gap / 2
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.surfaceContainer
            radius: Theme.shapeMedium
            border.width: 1
            border.color: Theme.outlineVariant
        }

        contentItem: ColumnLayout {
            id: menuColumn
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.hit
                radius: Theme.shapeSmall
                color: refreshMouse.containsMouse ? Theme.raised : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap
                    spacing: Theme.gap / 2
                    MaterialIcon {
                        Layout.preferredWidth: Theme.icon
                        Layout.preferredHeight: Theme.icon
                        name: "refresh"
                    }
                    CarText {
                        Layout.fillWidth: true
                        text: I18n.t("刷新用户")
                        color: Theme.foreground
                        fontPixelSize: Theme.body
                    }
                }
                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        moreMenu.close()
                        loginPage.refreshRequested()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.hit
                radius: Theme.shapeSmall
                color: aboutMouse.containsMouse ? Theme.raised : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap
                    spacing: Theme.gap / 2
                    MaterialIcon {
                        Layout.preferredWidth: Theme.icon
                        Layout.preferredHeight: Theme.icon
                        name: "description"
                    }
                    CarText {
                        Layout.fillWidth: true
                        text: I18n.t("关于")
                        color: Theme.foreground
                        fontPixelSize: Theme.body
                    }
                }
                MouseArea {
                    id: aboutMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        moreMenu.close()
                        aboutDialog.open()
                    }
                }
            }
        }
    }

    // 关机是破坏性操作：与系统其它电源入口一样二次确认。
    Dialog {
        id: powerConfirm
        z: 30000
        modal: true
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        width: Math.min(480 * Theme.scaleFactor, loginPage.width - Theme.gap * 2)
        x: (loginPage.width - width) / 2
        y: (loginPage.height - height) / 2
        padding: Theme.shapeExtraLarge
        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 2
            border.color: Theme.warning
        }
        contentItem: Loader {
            active: powerConfirm.opened
            sourceComponent: Component {
                ColumnLayout {
            spacing: Theme.gap
            CarText {
                Layout.fillWidth: true
                text: I18n.t("确认关机？")
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("这会立即中断当前工作。请确保可以重新接通电源。")
                color: Theme.foreground
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Item { Layout.fillWidth: true }
                CarButton {
                    text: I18n.t("取消")
                    onClicked: powerConfirm.close()
                }
                CarButton {
                    text: I18n.t("确认关机")
                    accent: true
                    onClicked: {
                        powerConfirm.close()
                        loginPage.powerRequested()
                    }
                }
            }
                }
            }
        }
    }

    Dialog {
        id: aboutDialog
        z: 30000
        modal: true
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        width: Math.min(480 * Theme.scaleFactor, loginPage.width - Theme.gap * 2)
        x: (loginPage.width - width) / 2
        y: (loginPage.height - height) / 2
        padding: Theme.shapeExtraLarge
        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 1
            border.color: Theme.outlineVariant
        }
        contentItem: Loader {
            active: aboutDialog.opened
            sourceComponent: Component {
                ColumnLayout {
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                text: I18n.t("关于")
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
            CarText {
                Layout.fillWidth: true
                text: loginPage.versionText
                color: Theme.foreground
                fontPixelSize: Theme.body
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("PIN 与读数只在本机验证，不上传。")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                CarButton {
                    text: I18n.t("关闭")
                    onClicked: aboutDialog.close()
                }
            }
                }
            }
        }
    }
        }
}
