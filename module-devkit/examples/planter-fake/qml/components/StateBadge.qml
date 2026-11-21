import QtQuick

// 状态徽标：所有模块页面用同一套状态名，颜色和文案位置保持一致。
// kind: live / stale / offline / loading / error / empty
Rectangle {
    id: badge
    property var theme: ({})
    property string kind: "empty"
    property string text: ""

    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color tone: ({
        live: "#4ade80",
        stale: "#fbbf24",
        offline: "#94a3b8",
        loading: "#85deff",
        error: "#f87171",
        empty: "#94a3b8"
    })[kind] || "#94a3b8"

    implicitWidth: label.implicitWidth + 34 * uiScale
    implicitHeight: 32 * uiScale
    radius: height / 2
    color: Qt.rgba(tone.r, tone.g, tone.b, 0.16)
    border.width: 1
    border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.55)

    Row {
        anchors.centerIn: parent
        spacing: 8 * badge.uiScale
        Rectangle {
            width: 8 * badge.uiScale; height: width; radius: width / 2
            color: badge.tone
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: label
            text: badge.text
            color: badge.theme.foreground || "#ffffff"
            font.pixelSize: 14 * badge.uiScale
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
