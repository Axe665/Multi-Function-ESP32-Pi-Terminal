import QtQuick
import QtQuick.Layouts

// 目标 U 盘单选列表。
//
// 用户只看得到盘的名字、容量和只读标记：挂载点、文件名、后缀一律不展示。
// 插拔由调用方把 systemTools.removableDevices 绑到 devices 上，实时刷新；
// 选中未挂载的盘时先调 udisksctl 挂载，挂载结果回来再真正选中。
ColumnLayout {
    id: picker
    objectName: "usbDevicePicker"

    property var devices: []
    property var storage: null
    property string selectedId: ""
    // true：只读盘不可选（导出/备份）；false：只读盘也能选（恢复）。
    property bool writableOnly: false
    property string caption: I18n.t("目标 U 盘")

    signal picked(string id)

    property string pendingId: ""
    property string mountError: ""

    spacing: Theme.gap / 2

    function deviceById(id) {
        for (let i = 0; i < devices.length; ++i)
            if (devices[i].id === id) return devices[i]
        return null
    }

    function choose(device) {
        if (!device) return
        if (writableOnly && device.readOnly) return
        mountError = ""
        if (!device.mounted) {
            pendingId = device.id
            if (storage) storage.openRemovableDevice(device.id)
            return
        }
        picker.picked(device.id)
    }

    function deviceSubtitle(device) {
        const parts = []
        const bytes = device.sizeBytes || 0
        if (bytes >= 1024 * 1024 * 1024)
            parts.push(Math.round(bytes / (1024 * 1024 * 1024)) + " GB")
        else if (bytes > 0)
            parts.push(Math.round(bytes / (1024 * 1024)) + " MB")
        if (device.readOnly) parts.push(I18n.t("只读"))
        else if (!device.mounted) parts.push(I18n.t("未挂载"))
        return parts.join("  ")
    }

    onDevicesChanged: {
        if (pendingId === "") return
        const device = deviceById(pendingId)
        if (device && device.mounted) {
            const id = pendingId
            pendingId = ""
            picker.picked(id)
        }
    }

    Connections {
        target: picker.storage
        enabled: picker.storage !== null
        function onRemovableDeviceError(message) {
            if (picker.pendingId === "") return
            picker.pendingId = ""
            picker.mountError = message
        }
    }

    CarText {
        Layout.fillWidth: true
        text: picker.caption
        fontPixelSize: Theme.fontLabel
        color: Theme.outline
    }

    CarText {
        Layout.fillWidth: true
        visible: picker.devices.length === 0
        text: I18n.t("插上 U 盘后会自动出现在这里")
        subdued: true
        fontPixelSize: Theme.fontCaption
        wrapMode: Text.Wrap
    }

    Column {
        Layout.fillWidth: true
        spacing: Theme.gap / 2

        Repeater {
            model: picker.devices

            delegate: Rectangle {
                id: entry
                required property var modelData

                readonly property bool picked: picker.selectedId === modelData.id
                readonly property bool blocked: picker.writableOnly && modelData.readOnly

                width: parent.width
                height: 64 * Theme.scaleFactor
                radius: Theme.shapeMedium
                color: picked ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                border.width: 1
                border.color: picked ? Theme.accent : Theme.outlineVariant

                Row {
                    anchors.fill: parent
                    anchors.margins: Theme.gap / 2
                    anchors.leftMargin: Theme.gap
                    spacing: Theme.gap / 2

                    MaterialIcon {
                        width: 22 * Theme.scaleFactor
                        height: width
                        anchors.verticalCenter: parent.verticalCenter
                        name: "storage"
                        light: true
                        opacity: entry.blocked ? 0.4 : 1
                    }
                    Column {
                        width: Math.max(1, parent.width - 22 * Theme.scaleFactor - parent.spacing)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        CarText {
                            width: parent.width
                            text: entry.modelData.name
                            fontPixelSize: Theme.fontLabel
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            opacity: entry.blocked ? 0.5 : 1
                        }
                        CarText {
                            width: parent.width
                            text: picker.deviceSubtitle(entry.modelData)
                            subdued: true
                            fontPixelSize: Theme.fontCaption
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: picker.choose(entry.modelData)
                }
            }
        }
    }

    CarText {
        Layout.fillWidth: true
        visible: picker.mountError !== ""
        text: picker.mountError
        color: Theme.danger
        fontPixelSize: Theme.fontCaption
        wrapMode: Text.Wrap
    }
}
