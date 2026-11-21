import QtQuick

// 指标块：标签 + 读数 + 单位 + 备注。颜色全部来自宿主注入的 hostTheme。
// kind 只影响左侧小图标：temperature / humidity / light / counter。
Rectangle {
    id: tile
    property var theme: ({})
    property string kind: "counter"
    property string label: ""
    property string value: "--"
    property string unit: ""
    property string note: ""

    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)

    implicitHeight: 128 * uiScale
    implicitWidth: 200 * uiScale
    radius: 16 * uiScale
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
    border.width: 1
    border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

    Column {
        anchors.fill: parent
        anchors.margins: 16 * tile.uiScale
        spacing: 6 * tile.uiScale

        Row {
            spacing: 8 * tile.uiScale
            Canvas {
                width: 22 * tile.uiScale; height: 22 * tile.uiScale
                onPaint: {
                    const c = getContext("2d"); c.reset(); c.strokeStyle = tile.accent; c.fillStyle = tile.accent
                    c.lineWidth = 2 * tile.uiScale
                    if (tile.kind === "temperature") {
                        c.strokeRect(8, 2, 5, 12); c.beginPath(); c.arc(10, 17, 4, 0, Math.PI * 2); c.fill()
                    } else if (tile.kind === "humidity") {
                        c.beginPath(); c.moveTo(10, 2); c.bezierCurveTo(2, 12, 2, 19, 10, 19)
                        c.bezierCurveTo(18, 19, 18, 12, 10, 2); c.stroke()
                    } else if (tile.kind === "light") {
                        c.beginPath(); c.arc(10, 10, 5, 0, Math.PI * 2); c.stroke()
                        for (let i = 0; i < 8; i++) {
                            const a = i * Math.PI / 4
                            c.beginPath(); c.moveTo(10 + Math.cos(a) * 7, 10 + Math.sin(a) * 7)
                            c.lineTo(10 + Math.cos(a) * 10, 10 + Math.sin(a) * 10); c.stroke()
                        }
                    } else {
                        c.font = (12 * tile.uiScale) + "px sans-serif"; c.fillText("‹›", 2, 16)
                    }
                }
            }
            Text {
                text: tile.label
                color: tile.muted
                font.pixelSize: 14 * tile.uiScale
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Text {
            text: tile.value
            color: tile.foreground
            font.pixelSize: 28 * tile.uiScale
            font.bold: true
            width: parent.width
            elide: Text.ElideRight
        }

        Text {
            text: tile.unit + (tile.note ? "  " + tile.note : "")
            color: tile.muted
            font.pixelSize: 12 * tile.uiScale
            width: parent.width
            wrapMode: Text.Wrap
        }
    }
}
