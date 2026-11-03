import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 「我已抄写」的统一确认：5 秒冷静期。
//
// 三处复用：其他用户的恢复码弹窗、锁屏建号、开机向导第 3 步。
// 去掉「填第 2/5 组」的核对后，用这 5 秒代替——不拦人，但强制停一下，
// 让人有机会回头确认恢复码真的抄下来了。
Popup {
    id: confirm
    objectName: "recoveryAckConfirmDialog"

    property int cooldown: 5
    property string titleText: I18n.t("确认已保存恢复码？")
    property string bodyText: I18n.t("关闭后恢复码不会再次显示。请确认已经抄写，或已经导出到 U 盘。")
    property string acceptText: I18n.t("确认已保存")

    signal accepted()

    parent: Overlay.overlay
    anchors.centerIn: Overlay.overlay
    modal: true
    dim: true
    closePolicy: Popup.NoAutoClose
    Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
    padding: Theme.gap
    width: Math.min(460 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
    background: Rectangle { radius: Theme.shapeLarge; color: Theme.surface; border.color: Theme.outline; border.width: 1 }

    contentItem: ColumnLayout {
        spacing: Theme.gap / 2
        CarText {
            Layout.fillWidth: true
            text: confirm.titleText
            fontPixelSize: Theme.title
            color: Theme.foreground
        }
        CarText {
            Layout.fillWidth: true
            text: confirm.bodyText
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }
        CarText {
            Layout.fillWidth: true
            text: confirm.cooldown > 0
                  ? I18n.t("冷静期") + " " + confirm.cooldown + " " + I18n.t("秒")
                  : I18n.t("可以确认了")
            color: confirm.cooldown > 0 ? Theme.warning : Theme.outline
            fontPixelSize: Theme.fontCaption
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap / 2
            CarButton {
                objectName: "recoveryAckBack"
                Layout.fillWidth: true
                text: I18n.t("返回")
                onClicked: confirm.close()
            }
            CarButton {
                objectName: "recoveryAckSure"
                Layout.fillWidth: true
                text: confirm.acceptText
                accent: true
                enabled: confirm.cooldown <= 0
                onClicked: {
                    confirm.close()
                    confirm.accepted()
                }
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: confirm.opened && confirm.cooldown > 0
        onTriggered: confirm.cooldown--
    }
    onOpened: cooldown = 5
}
