import QtQuick

// 指标卡：颜色全部来自宿主 hostTheme；metric 仍由页面传入。
Rectangle {
    id: tile
    property var theme: ({})
    property var metric: ({})

    readonly property real u: (theme.scale > 0) ? theme.scale : 1
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)

    height: 155
    radius: 18
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
    border.width: 1
    border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)

    Column {
        x: 13; y: 12; width: parent.width - 26; spacing: 7
        Row {
            spacing: 8
            Canvas {
                width: 25; height: 26
                onPaint: {
                    const c = getContext("2d"); c.reset(); c.strokeStyle = tile.accent; c.fillStyle = tile.accent; c.lineWidth = 2
                    if (tile.metric.kind === "temperature") {
                        c.strokeRect(10, 2, 6, 15); c.beginPath(); c.arc(13, 19, 5, 0, Math.PI * 2); c.fill()
                    } else if (tile.metric.kind === "humidity") {
                        c.beginPath(); c.moveTo(13, 2); c.bezierCurveTo(2, 14, 2, 24, 13, 24); c.bezierCurveTo(24, 24, 24, 14, 13, 2); c.stroke()
                    } else if (tile.metric.kind === "light") {
                        c.beginPath(); c.arc(13, 13, 6, 0, Math.PI * 2); c.stroke()
                        for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4; c.beginPath(); c.moveTo(13 + Math.cos(a) * 9, 13 + Math.sin(a) * 9); c.lineTo(13 + Math.cos(a) * 12, 13 + Math.sin(a) * 12); c.stroke() }
                    } else {
                        c.beginPath(); c.arc(13, 14, 10, Math.PI, Math.PI * 2); c.stroke(); c.beginPath(); c.moveTo(13, 14); c.lineTo(19, 7); c.stroke(); c.fillRect(3, 20, 20, 2)
                    }
                }
            }
            Text { text: tile.metric.label || ""; font.pixelSize: 14; color: tile.muted; height: 26; verticalAlignment: Text.AlignVCenter }
        }
        Text { text: tile.metric.value || "--"; font.pixelSize: 28; font.bold: true; color: tile.foreground; width: parent.width; elide: Text.ElideRight }
        Text { text: tile.metric.unit || ""; color: tile.muted; font.pixelSize: 13 }
        Text { text: tile.metric.note || ""; width: parent.width; wrapMode: Text.Wrap; color: tile.muted; font.pixelSize: 12 }
    }
}
