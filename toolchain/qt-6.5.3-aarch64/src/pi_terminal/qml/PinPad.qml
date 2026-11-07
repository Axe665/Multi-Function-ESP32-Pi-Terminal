import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 数字键盘：只接受 ASCII 数字。输满 6 位后**不再自动提交**，
// 需要用户点第 5 行的「确认」才开始校验——避免手滑输错也白等一次 KDF。
// 不显示已输入内容（只显示位数），避免旁人窥屏。
// ChromeOS 式外观：大号圆形按键 + 居中的位数圆点；布局与信号保持原样。
Item {
    id: pinPad
    property int digits: 6
    property string value: ""
    property bool busy: false
    property string message: ""
    property bool messageIsError: false
    // 登录页用左上角返回箭头离开，键盘左下角留空；锁屏页保留「取消」用于退出登录。
    property bool showCancel: true
    // 按键直径；登录页会按窗口高度再收一次，锁屏页用默认值。
    property real keySize: Math.max(Theme.hit, 60 * Theme.scaleFactor)
    // 未输入时的占位与校验中的状态文案。默认保持登录/解锁语义；
    // 首次开机向导（OOBE）复用它设置新 PIN 时改成“输入 6 位数字”“正在创建…”之类。
    property string placeholderText: I18n.t("输入 6 位密码")
    property string busyText: I18n.t("正在解锁…")

    signal submitted(string pin)
    signal cancelled()

    implicitHeight: column.implicitHeight

    function press(digit) {
        if (busy || value.length >= digits) return
        value += digit
    }
    // 确认：只有输满才允许提交，提交后清空避免重复。
    function confirm() {
        if (busy || value.length !== digits) return
        const pin = value
        value = ""
        submitted(pin)
    }
    function backspace() { if (!busy && value.length > 0) value = value.slice(0, -1) }
    function clear() { value = "" }

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Theme.gap / 2

        // 校验进行中：给出明确状态，避免用户以为点击丢失。
        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.gap / 3
            visible: pinPad.busy
            BusyIndicator { running: pinPad.busy; implicitWidth: Theme.icon; implicitHeight: Theme.icon }
            CarText {
                anchors.verticalCenter: parent.verticalCenter
                text: pinPad.busyText
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
            }
        }

        // 密码框 + 清空：Google 登录页那种一个输入框，右端一个 ×。
        // 只显示圆点，不显示数字（旁人窥屏拿不到）。
        RowLayout {
            // 与三列数字键同宽：密码框比键盘宽会显得页面散掉。
            // maximumWidth 必须给：ColumnLayout 会把子项拉到可用宽度，
            // 只写 preferredWidth 不起作用（实测框被拉到两倍宽）。
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: false
            Layout.preferredWidth: pinPad.keySize * 3
            Layout.maximumWidth: pinPad.keySize * 3 + Theme.gap / 2
            spacing: Theme.gap / 3

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: pinPad.keySize * 0.82
                radius: Theme.shapeSmall
                color: Theme.surfaceContainer
                border.width: 1
                border.color: pinPad.busy ? Theme.outlineVariant
                                          : (pinPad.value.length > 0 ? Theme.accent : Theme.outlineVariant)

                CarText {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.gap
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.gap
                    elide: Text.ElideRight
                    fontPixelSize: Theme.body
                    color: Theme.foreground
                    text: {
                        let dots = ""
                        for (let i = 0; i < pinPad.value.length; ++i) dots += "●"
                        return dots === "" ? pinPad.placeholderText : dots
                    }
                }
            }

            // 与左下角「确认」成对角的清空键。
            IconButton {
                objectName: "pinClear"
                Layout.preferredWidth: pinPad.keySize * 0.72
                Layout.preferredHeight: pinPad.keySize * 0.72
                visible: pinPad.value.length > 0 && !pinPad.busy
                iconName: "close"
                label: I18n.t("清空")
                onClicked: pinPad.clear()
            }
        }


        CarText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: pinPad.message
            visible: pinPad.message.length > 0
            color: pinPad.messageIsError ? Theme.warning : Theme.foreground
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        GridLayout {
            Layout.alignment: Qt.AlignHCenter
            columns: 3
            rowSpacing: Theme.gap / 3
            columnSpacing: Theme.gap / 2

            Repeater {
                model: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
                CarButton {
                    Layout.preferredWidth: pinPad.keySize
                    Layout.preferredHeight: pinPad.keySize
                    text: modelData
                    fontPixelSize: Theme.fontStrong
                    buttonColor: down ? Theme.pressed : Theme.surfaceContainerHigh
                    enabled: !pinPad.busy
                    onClicked: pinPad.press(modelData)
                    Accessible.name: I18n.t("数字 ") + modelData
                }
            }
            // 左下角固定占位：登录页隐藏「取消」后仍与 0/退格对齐。
            Item {
                Layout.preferredWidth: pinPad.keySize
                Layout.preferredHeight: pinPad.keySize
                CarButton {
                    anchors.fill: parent
                    visible: pinPad.showCancel
                    text: I18n.t("取消")
                    fontPixelSize: Theme.fontLabel
                    buttonColor: "transparent"
                    enabled: !pinPad.busy
                    onClicked: pinPad.cancelled()
                }
                // 确认：对号放在 0 的左侧，与密码框右端的 × 遥相呼应。
                // 未输满时存在但禁用（不给"点了没反应"的错觉）。
                IconButton {
                    objectName: "pinConfirm"
                    anchors.fill: parent
                    visible: !pinPad.showCancel
                    enabled: pinPad.value.length === pinPad.digits && !pinPad.busy
                    opacity: enabled ? 1.0 : 0.35
                    iconName: "check"
                    label: I18n.t("确认密码")
                    filled: pinPad.value.length === pinPad.digits
                    onClicked: pinPad.confirm()
                }
            }
            CarButton {
                Layout.preferredWidth: pinPad.keySize
                Layout.preferredHeight: pinPad.keySize
                text: "0"
                fontPixelSize: Theme.fontStrong
                buttonColor: down ? Theme.pressed : Theme.surfaceContainerHigh
                enabled: !pinPad.busy
                onClicked: pinPad.press("0")
                Accessible.name: I18n.t("数字 0")
            }
            CarButton {
                Layout.preferredWidth: pinPad.keySize
                Layout.preferredHeight: pinPad.keySize
                text: ""
                buttonColor: down ? Theme.pressed : Theme.surfaceContainerHigh
                enabled: !pinPad.busy
                onClicked: pinPad.backspace()
                Accessible.name: I18n.t("删除一位")
                contentItem: Item {
                    MaterialIcon {
                        anchors.centerIn: parent
                        width: Theme.icon
                        height: Theme.icon
                        name: "backspace"
                        light: true
                    }
                }
            }
        }

    }
}
