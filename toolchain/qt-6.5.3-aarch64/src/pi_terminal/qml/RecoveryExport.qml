import QtQuick
import QtQuick.Layouts

// 把恢复码导出到 U 盘。
//
// 平时只有一个按钮，点开才展开盘列表——恢复码本身很占版面，导出不该再挤一行。
// 三处复用：开机向导第 3 步、「其他用户」创建后的弹窗、锁屏创建用户后的弹窗。
ColumnLayout {
    id: exportPanel
    objectName: "recoveryExportPanel"

    property string recoveryCode: ""
    property string userName: ""
    property bool expanded: false
    property string resultText: ""

    signal exported()

    readonly property var devices: (typeof systemTools !== "undefined" && systemTools)
                                   ? systemTools.removableDevices : []

    spacing: Theme.gap / 2

    CarButton {
        objectName: "exportRecoveryButton"
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.hit
        text: exportPanel.expanded ? I18n.t("收起 U 盘列表") : I18n.t("导出到 U 盘")
        onClicked: {
            exportPanel.expanded = !exportPanel.expanded
            exportPanel.resultText = ""
        }
    }

    UsbDevicePicker {
        Layout.fillWidth: true
        visible: exportPanel.expanded
        devices: exportPanel.devices
        storage: (typeof systemTools !== "undefined" && systemTools) ? systemTools : null
        writableOnly: true
        caption: I18n.t("导出到")
        onPicked: function(id) { exportPanel.saveTo(id) }
    }

    CarText {
        Layout.fillWidth: true
        visible: exportPanel.resultText !== ""
        text: exportPanel.resultText
        color: exportPanel.resultText === I18n.t("已保存到 U 盘") ? Theme.accent : Theme.danger
        fontPixelSize: Theme.fontCaption
        wrapMode: Text.Wrap
    }

    function stamp() {
        const d = new Date()
        const p2 = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate())
             + "-" + p2(d.getHours()) + p2(d.getMinutes())
    }

    function readableTime() {
        const d = new Date()
        const p2 = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate())
             + " " + p2(d.getHours()) + ":" + p2(d.getMinutes())
    }

    function saveTo(deviceId) {
        if (typeof systemTools === "undefined" || !systemTools) return
        if (exportPanel.recoveryCode === "") return
        const who = exportPanel.userName !== "" ? exportPanel.userName : I18n.t("管理员")
        const fileName = "recovery-" + exportPanel.stamp() + ".txt"
        const text = I18n.t("模块化终端 恢复码") + "\n"
                   + I18n.t("用户：") + who + "\n"
                   + I18n.t("时间：") + exportPanel.readableTime() + "\n"
                   + I18n.t("恢复码：") + exportPanel.recoveryCode + "\n\n"
                   + I18n.t("忘记 PIN 时，这是唯一能找回数据的方式。请离线保存，不要放在本机。") + "\n"
        if (systemTools.writeRemovableText("@usb/" + deviceId + "/" + fileName, text)) {
            exportPanel.resultText = I18n.t("已保存到 U 盘")
            exportPanel.exported()
        } else {
            exportPanel.resultText = I18n.t("保存失败，请检查 U 盘")
        }
    }
}
