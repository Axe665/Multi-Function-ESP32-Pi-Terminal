import QtQuick
import QtQuick.Controls

TextField {
    id: field
    property bool auditControl: true
    // 兼容旧调用点：属性保留，但提示行为已统一（见下）。
    property bool plainHint: false
    font.pointSize: Theme.body
    color: Theme.textOn(Theme.background)
    // 一律关掉 Material 的上浮标签：聚焦时提示文字不许“跑到上面”，
    // 由下面那个 Text 固定在框内居中显示，输入第一个字符才消失。
    placeholderTextColor: "transparent"
    selectionColor: Theme.accent; selectedTextColor: Theme.textOn(selectionColor)
    padding: Theme.gap
    implicitHeight: Math.max(Theme.hit, contentHeight + padding * 2)
    background: Rectangle {
        color: Theme.background; radius: Theme.shapeMedium
        border.color: field.activeFocus ? Theme.accent : Theme.outline
        border.width: field.activeFocus ? 3 : 1
    }
    Accessible.name: placeholderText

    // 点击输入框才请求虚拟键盘。不能用 onActiveFocusChanged：键盘收起时
    // Qt 会把焦点还给输入框，焦点变化又请求弹出，表现为"关不掉、循环开启"。
    // TapHandler 是 passive 的，不影响输入框自己的光标定位与选择。
    signal keyboardRequested()
    TapHandler {
        // Handler 挂在 contentItem 上，边界是文字区；margin 扩到 padding 外沿，
        // 点输入框任意位置（含左右留白）都能唤起键盘。
        margin: field.padding
        onTapped: field.keyboardRequested()
    }

    // 与输入文字同基线、同字号；只做提示，不接收鼠标。
    // 聚焦且为空时仍留在框内（不再失焦才出现），也不上浮成标签。
    Text {
        objectName: "carFieldHint"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: field.leftPadding
        anchors.rightMargin: field.rightPadding
        anchors.verticalCenter: parent.verticalCenter
        visible: field.length === 0 && field.placeholderText.length > 0
        text: field.placeholderText
        color: Theme.outline
        font: field.font
        elide: Text.ElideRight
        maximumLineCount: 1
        z: 1
        Accessible.ignored: true
    }
}
