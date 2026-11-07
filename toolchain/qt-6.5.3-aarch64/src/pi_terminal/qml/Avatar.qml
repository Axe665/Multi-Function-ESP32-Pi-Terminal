import QtQuick

// 圆形头像：服务端已经把选中的图片裁成圆形 PNG，这里只负责尺寸与回退。
// 没有头像（或文件损坏）时显示显示名首字母，保持列表布局稳定。
Item {
    id: root
    property string source: ""
    property string displayName: ""
    property real size: 64

    readonly property string initial: {
        const name = (root.displayName || "").trim()
        return name.length > 0 ? name.charAt(0).toUpperCase() : "?"
    }

    implicitWidth: size
    implicitHeight: size
    Accessible.ignored: true

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Theme.primaryContainer
        border.width: 1
        border.color: Theme.outlineVariant
    }

    CarText {
        anchors.centerIn: parent
        visible: image.status !== Image.Ready
        text: root.initial
        color: Theme.accent
        fontPixelSize: Math.max(Theme.fontLabel, root.size * 0.4)
        horizontalAlignment: Text.AlignHCenter
    }

    Image {
        id: image
        anchors.fill: parent
        source: root.source
        asynchronous: true
        autoTransform: true
        sourceSize: Qt.size(Math.ceil(root.size * 2), Math.ceil(root.size * 2))
        fillMode: Image.PreserveAspectCrop
        visible: status === Image.Ready
    }

    // 环形描边压在最上层，图片透明区域之外也能看出头像边界。
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: 1
        border.color: Theme.outlineVariant
    }
}
