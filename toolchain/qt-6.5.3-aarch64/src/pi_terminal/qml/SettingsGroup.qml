import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    property string iconName: "settings"
    property string title: ""
    // 页面已经有主标题时用它把分组标题收起来（彩蛋逻辑与 titleTapEnabled 不受影响）。
    property bool headerVisible: true
    property string subtitle: ""
    property color accentColor: Theme.accent
    property int titleTapCount: 0
    property double titleTapStarted: 0
    property bool titleTapEnabled: false
    onVisibleChanged: { if (!visible) titleTapCount = 0 }
    onTitleTapEnabledChanged: { titleTapCount = 0 }
    signal titleTapped()
    function registerTitleTap() {
        const now = Date.now()
        if (now - titleTapStarted > 1800) titleTapCount = 0
        titleTapStarted = now
        if (++titleTapCount >= 5) {
            titleTapCount = 0
            titleTapped()
        }
    }
    default property alias content: body.data
    radius: Theme.shapeLarge
    color: Theme.surface
    border.color: Theme.outlineVariant
    implicitHeight: column.implicitHeight + Theme.gap * 2
    Column {
        id: column
        x: Theme.gap
        y: Theme.gap
        // Hidden settings pages can be laid out at 1px during startup. A
        // 1px body makes Qt 6.5's ColumnLayout polish oscillate on wrapped
        // rows, so keep a usable measuring width for the off-screen card.
        width: Math.max(240, root.width - Theme.gap * 2)
        spacing: Theme.gap
        Item {
            width: column.width
            visible: root.headerVisible
            implicitHeight: root.headerVisible
                ? Math.max(48 * Theme.scaleFactor, headingColumn.implicitHeight) : 0
            Rectangle {
                width: 48 * Theme.scaleFactor; height: width
                anchors.verticalCenter: parent.verticalCenter
                radius: width / 2
                color: Qt.darker(root.accentColor, 2.1)
                border.color: Qt.lighter(root.accentColor, 1.15)
                MaterialIcon { anchors.centerIn: parent; width: 25 * Theme.scaleFactor; height: width; name: root.iconName; light: true }
            }
            Column {
                id: headingColumn
                x: 48 * Theme.scaleFactor + Theme.gap
                width: Math.max(1, column.width - 48 * Theme.scaleFactor - Theme.gap)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * Theme.scaleFactor
                CarText {
                    objectName: "settingsGroupTitle"
                    text: root.title; heading: true; width: parent.width
                    height: Math.max(implicitHeight, root.titleTapEnabled ? 48 : 0)
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.titleTapEnabled
                        acceptedButtons: Qt.LeftButton
                        onClicked: root.registerTitleTap()
                        // Qt sends doubleClicked instead of clicked for the
                        // second press of a native mouse double-click.
                        onDoubleClicked: root.registerTitleTap()
                    }
                }
                CarText { visible: root.subtitle !== ""; text: root.subtitle; subdued: true; width: parent.width; wrapMode: Text.Wrap }
            }
        }
        // 隐式宽度必须跟实际宽度一致：隐藏页初始化时 root.width 可能是 0，
        // body 被钳到测量宽度，而 implicitWidth 仍按内容算（更宽）。两者不一致时
        // Qt 6.5 的 ColumnLayout 两轮迭代算不出稳定高度，报 polish loop。
        ColumnLayout { id: body; width: column.width; implicitWidth: width; spacing: Theme.gap / 2; visible: root.width >= 240 }
    }
}
