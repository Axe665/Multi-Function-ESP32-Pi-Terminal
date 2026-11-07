import QtQuick

// 「关于本机」信息行：Material 图标 + 标签（左） + 值（右，右对齐、最多两行）。
// 不用 Qt Quick Layouts：这里全是静态行，anchors 足够，也避开小屏 + 高 DPR 下的
// 布局 polish 循环（项目里已被这个坑坑过一次）。
Item {
    id: row
    objectName: "aboutInfoRow"
    property string iconName: "info"
    property string label: ""
    property string value: ""

    readonly property real rowHeight: Math.max(56 * Theme.scaleFactor,
                                               Math.max(labelText.implicitHeight, valueText.implicitHeight) + Theme.gap)

    implicitHeight: rowHeight
    height: rowHeight

    MaterialIcon {
        id: rowIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 22 * Theme.scaleFactor
        height: width
        name: row.iconName
        Accessible.ignored: true
    }
    CarText {
        id: labelText
        anchors.left: rowIcon.right
        anchors.leftMargin: Theme.gap / 2
        anchors.verticalCenter: parent.verticalCenter
        text: row.label
        font.pointSize: Theme.body
        subdued: true
        maximumLineCount: 1
    }
    Text {
        id: valueText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // 值可能很长（处理器型号、内核版本），给右半区 66% 宽度并允许折两行。
        // 不要再用 Math.min(implicitWidth, …)：wrap 文本的 implicitWidth 依赖宽度，
        // 两者互相引用就是绑定循环（日志里报过 Binding loop detected for "width"）。
        width: Math.max(1, row.width * 0.66)
        text: row.value
        color: Theme.foreground
        font.pointSize: Theme.body
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignRight
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        Accessible.name: row.label + " " + row.value
    }
}
