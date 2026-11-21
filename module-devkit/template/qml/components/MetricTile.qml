import QtQuick

// 指标卡：标签 + 读数 + 单位 + 一行说明。
// 颜色只从 hostTheme 派生，和模板页的 veil() 层次保持一致。
Rectangle {
    id: tile
    property var theme: ({})
    property string label: ""
    property string value: "--"
    property string unit: ""
    property string note: ""

    readonly property real u: (theme.scale > 0) ? theme.scale : 1
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.50)

    implicitWidth: 160 * u
    implicitHeight: 96 * u
    radius: 16 * u
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
    border.width: u
    border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)

    Column {
        x: 14 * tile.u
        y: 12 * tile.u
        width: parent.width - 28 * tile.u
        spacing: 4 * tile.u

        Text {
            text: tile.label
            color: tile.muted
            font.pixelSize: 12 * tile.u
            elide: Text.ElideRight
            width: parent.width
        }
        Row {
            spacing: 4 * tile.u
            Text {
                text: tile.value
                color: tile.foreground
                font.pixelSize: 24 * tile.u
                font.bold: true
            }
            Text {
                text: tile.unit
                color: Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b, 0.60)
                font.pixelSize: 12 * tile.u
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4 * tile.u
            }
        }
        Text {
            width: parent.width
            text: tile.note
            color: tile.muted
            font.pixelSize: 11 * tile.u
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }
}
