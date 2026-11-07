import QtQuick
import QtQuick.Controls

// 只读长文本浏览器：保持不可编辑、不可选中；按住拖动或滚轮平移。
// 开发者选项与测试输出共用。等宽字体单独保留，不参与全局 Google Sans 替换。
Rectangle {
    id: root
    objectName: "readOnlyTextView"

    property string text: ""
    property color textColor: Theme.foreground
    property real fontPixelSize: Math.max(11, 12 * Theme.scaleFactor)
    property string fontFamily: "monospace"
    // 测试输出需要跟随末尾；开发者面板默认停在用户当前浏览位置。
    property bool followEnd: false

    readonly property alias contentX: flick.contentX
    readonly property alias contentY: flick.contentY
    readonly property alias contentWidth: flick.contentWidth
    readonly property alias contentHeight: flick.contentHeight

    color: Theme.background
    radius: Theme.shapeSmall
    clip: true

    function scrollToEnd() {
        flick.contentY = Math.max(0, flick.contentHeight - flick.height)
    }

    function scrollToStart() {
        flick.contentX = 0
        flick.contentY = 0
    }

    Flickable {
        id: flick
        objectName: "readOnlyTextViewFlick"
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.AutoFlickDirection
        contentWidth: Math.max(width, body.width + Theme.gap * 2)
        contentHeight: Math.max(height, body.implicitHeight + Theme.gap * 2)

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            implicitWidth: 12 * Theme.scaleFactor
        }
        ScrollBar.horizontal: ScrollBar {
            policy: ScrollBar.AsNeeded
            implicitHeight: 12 * Theme.scaleFactor
        }

        Text {
            id: body
            x: Theme.gap
            y: Theme.gap
            width: Math.max(flick.width - Theme.gap * 2, implicitWidth)
            text: root.text
            textFormat: Text.PlainText
            wrapMode: Text.NoWrap
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.fontPixelSize
            activeFocusOnTab: false
            Accessible.role: Accessible.StaticText
            Accessible.name: root.text
        }
    }

    onTextChanged: if (followEnd) Qt.callLater(scrollToEnd)
}
