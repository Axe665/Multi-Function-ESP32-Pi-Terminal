import QtQuick

// 顶部线性进度 + “第 n 步，共 m 步”。
// 位置固定，不随步骤内容高度跳动；这是五步里唯一的全局导航提示。
Item {
    id: header
    property int step: 0
    property int total: 5
    implicitHeight: 44

    Rectangle {
        id: track
        anchors.top: parent.top
        width: parent.width
        height: 4
        radius: 2
        color: Theme.surfaceContainerHigh
    }
    Rectangle {
        anchors.top: parent.top
        height: 4
        radius: 2
        color: Theme.accent
        width: parent.width * Math.min(1, (header.step + 1) / Math.max(1, header.total))
        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    }
    Text {
        anchors.top: parent.top
        anchors.topMargin: 12
        text: I18n.english
              ? "Step " + (header.step + 1) + " of " + header.total
              : "第 " + (header.step + 1) + " 步，共 " + header.total + " 步"
        color: Theme.secondary
        opacity: 0.66
        font.pointSize: 14 * Theme.scaleFactor
    }
}
