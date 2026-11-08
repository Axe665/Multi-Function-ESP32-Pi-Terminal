import QtQuick

// 「正在删除，请稍候」等待层：Win10 关机那种五点圆环。
//
// 删除本身是同步调用，一瞬间就结束了；这一层负责把「删完」和「下一步」
// （首次开机向导 / 登录页 / 账户列表）之间补上一段可读的间隔，同时挡住界面，
// 不让人在过渡期间点到已经失效的控件。
//
// 视觉上只留一个重点：圆环。背景取主题深色，文字用主题前景色，不引入新色板。
Item {
    id: wait
    objectName: "accountDeleteWait"

    // 一圈 2 秒：每个点亮起占 1/5 圈，剩下 4/5 圈缓慢退回暗态，
    // 五个点错开 1/5 圈，看上去就是一点追着一点绕圈。
    readonly property int cycle: 2000
    readonly property real dotSize: 12 * Theme.scaleFactor
    readonly property real ringRadius: 24 * Theme.scaleFactor
    // 暗态不能太暗：五个点要一直看得见，只有亮度在跑，才像 Win10 的转圈。
    readonly property real dimOpacity: 0.28

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    Item {
        id: content
        anchors.centerIn: parent
        width: Math.max(ring.width, titleText.implicitWidth)
        height: ring.height + Theme.gap * 1.5 + titleText.implicitHeight

        Item {
            id: ring
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0
            width: wait.dotSize * 8
            height: width

            Repeater {
                model: 5

                delegate: Rectangle {
                    id: dot

                    required property int index

                    readonly property real angle: (-90 + index * 72) * Math.PI / 180

                    width: wait.dotSize
                    height: wait.dotSize
                    radius: width / 2
                    color: Theme.foreground
                    opacity: wait.dimOpacity
                    x: (ring.width - width) / 2 + Math.cos(angle) * wait.ringRadius
                    y: (ring.height - height) / 2 + Math.sin(angle) * wait.ringRadius

                    SequentialAnimation on opacity {
                        // 隐藏时停掉，别让五个循环动画在后台空转。
                        running: wait.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: dot.index * wait.cycle / 5 }
                        NumberAnimation {
                            from: wait.dimOpacity
                            to: 1.0
                            duration: wait.cycle / 5
                            easing.type: Easing.OutQuad
                        }
                        NumberAnimation {
                            from: 1.0
                            to: wait.dimOpacity
                            duration: wait.cycle * 4 / 5
                            easing.type: Easing.InQuad
                        }
                    }
                }
            }
        }

        CarText {
            id: titleText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: ring.bottom
            anchors.topMargin: Theme.gap * 1.5
            text: I18n.t("正在删除，请稍候")
            fontPixelSize: Theme.title
            color: Theme.foreground
        }
    }
}
