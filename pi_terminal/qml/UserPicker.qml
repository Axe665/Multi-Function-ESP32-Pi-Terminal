import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 低敏用户选择：只显示显示名与头像，不显示任何健康数据。
// 选人之后必须再输 PIN，刷卡也不能跳过 PIN。
Item {
    // true：行内容左对齐（登录页左下角那种排法）；false：保持居中的 ChromeOS 排法。
    property bool alignLeft: false
    id: picker
    // [{userId, displayName, admin, avatarSource}] —— 不含 salt/verifier/DB key
    property var users: []
    property string selectedUserId: ""
    property string message: ""

    signal userChosen(string userId)
    signal refreshRequested()

    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Theme.gap / 2

        CarText {
            Layout.fillWidth: true
            text: picker.message
            visible: picker.message.length > 0
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }

        Flickable {
            id: listFlick
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(listColumn.implicitHeight, 280 * Theme.scaleFactor)
            visible: picker.users.length > 0
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            Column {
                id: listColumn
                width: listFlick.width
                spacing: 2 * Theme.scaleFactor

                Repeater {
                    model: picker.users
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        width: listColumn.width
                        height: Math.max(Theme.hit, 56 * Theme.scaleFactor)
                        color: "transparent"
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.displayName
                        Accessible.onPressAction: picker.userChosen(modelData.userId)
                        Keys.onReturnPressed: picker.userChosen(modelData.userId)

                        // 头像 + 姓名作为一组居中，多用户时像 ChromeOS 账户选择。
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: picker.alignLeft ? parent.left : undefined
                            anchors.horizontalCenter: picker.alignLeft ? undefined : parent.horizontalCenter
                            width: rowContent.implicitWidth + Theme.gap * 1.5
                            height: row.height
                            radius: width / 2
                            color: rowMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                        }

                        RowLayout {
                            id: rowContent
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: picker.alignLeft ? parent.left : undefined
                            anchors.horizontalCenter: picker.alignLeft ? undefined : parent.horizontalCenter
                            x: picker.alignLeft ? Theme.gap / 2 : 0
                            spacing: Theme.gap / 2

                            Avatar {
                                Layout.preferredWidth: 56 * Theme.scaleFactor
                                Layout.preferredHeight: 56 * Theme.scaleFactor
                                size: 56 * Theme.scaleFactor
                                source: modelData.avatarSource || ""
                                displayName: modelData.displayName
                            }

                            CarText {
                                text: modelData.displayName
                                color: Theme.foreground
                                fontPixelSize: Theme.title
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.userChosen(row.modelData.userId)
                        }
                    }
                }
            }
        }

        CarText {
            Layout.fillWidth: true
            visible: picker.users.length === 0
            text: I18n.t("没有可选用户")
            color: Theme.outline
            fontPixelSize: Theme.fontLabel
            horizontalAlignment: Text.AlignHCenter
        }

        CarText {
            Layout.fillWidth: true
            visible: picker.users.length === 0
            text: I18n.t("没有用户，请先在终端执行 --init-admin 创建管理员")
            color: Theme.outline
            fontPixelSize: Theme.fontLabel
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        CarButton {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: Theme.hit
            visible: picker.users.length === 0
            text: I18n.t("刷新")
            onClicked: picker.refreshRequested()
        }
    }
}
