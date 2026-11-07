import QtQuick
import QtQuick.Layouts

// 锁屏遮罩：隐藏敏感内容，必须重输 PIN 解锁（不得刷卡解锁）。
// 提示不含姓名、读数、精确位置（f-day1 §2）。
Rectangle {
    id: lockScreen
    color: Theme.background
    property string message: ""
    property bool messageIsError: false
    property bool busy: false

    signal pinSubmitted(string pin)
    signal logoutRequested()
    signal keyboardRequested()

    // 锁屏上的建号入口：先验管理员 PIN，再填新用户，最后给恢复码。
    LockCreateUser {
        id: createUserPanel
        onKeyboardRequested: lockScreen.keyboardRequested()
    }

    // 右上角两个按钮用 Row 排：不用 anchors 互相引用。
    // 本页由 Loader 动态加载，anchors 跨项引用会报 "lockLogout is not defined"，
    // 而且那个错误会让整块右上角不渲染。
    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.gap
        spacing: Theme.gap / 2

        IconButton {
            objectName: "lockCreateUser"
            iconName: "person_add"
            label: I18n.t("创建新用户")
            onClicked: createUserPanel.openAuth()
        }
        IconButton {
            objectName: "lockLogout"
            iconName: "logout"
            label: I18n.t("退出登录")
            accentColor: Theme.warning
            onClicked: lockScreen.logoutRequested()
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.margin * 2, 420 * Theme.scaleFactor)
        spacing: Theme.gap

        MaterialIcon {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Theme.hit
            Layout.preferredHeight: Theme.hit
            name: "backspace"
        }

        CarText {
            Layout.fillWidth: true
            text: I18n.t("已锁定")
            fontPixelSize: Theme.title
            color: Theme.foreground
            horizontalAlignment: Text.AlignHCenter
        }

        PinPad {
            Layout.fillWidth: true
            // 锁屏需要显式确认：满 6 位后点 ✓，不再把左下角留给「取消」。
            showCancel: false
            busy: lockScreen.busy
            message: lockScreen.message
            messageIsError: lockScreen.messageIsError
            onSubmitted: function(pin) { lockScreen.pinSubmitted(pin) }
            onCancelled: lockScreen.logoutRequested()
        }
    }
}
