import QtQuick
import QtQuick.Layouts

// 第 1 步：欢迎 + 语言。
// 语言写全局 uiLanguage：OOBE 与桌面同时切换，避免进桌面后“变脸”。
Item {
    id: step
    property var wizard
    property string primaryLabel: I18n.t("开始")
    property bool primaryEnabled: true
    property bool canGoBack: false

    signal primaryAction()
    onPrimaryAction: wizard.goTo(1)

    Column {
        width: parent.width
        spacing: Theme.gap * 1.25

        Text {
            width: parent.width
            text: I18n.t("开始使用")
            color: Theme.foreground
            font.pointSize: Theme.hero
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
        }
        Text {
            width: parent.width
            text: I18n.t("这台终端还没有管理员。接下来四步，设置 PIN、保存恢复码，就完成了。")
            color: Theme.secondary
            opacity: 0.78
            font.pointSize: Theme.body
            lineHeight: 1.4
            wrapMode: Text.WordWrap
        }

        Row {
            spacing: Theme.gap / 2
            Repeater {
                model: [{ id: "zh", label: "中文" }, { id: "en", label: "English" }]
                delegate: Rectangle {
                    required property var modelData
                    width: 148 * Theme.scaleFactor
                    height: Theme.hit
                    radius: Theme.shapeFull
                    color: systemTools.uiLanguage === modelData.id ? Theme.accent : "transparent"
                    border.width: 1
                    border.color: systemTools.uiLanguage === modelData.id ? Theme.accent : Theme.outline
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: systemTools.uiLanguage === modelData.id ? Theme.accentInk : Theme.foreground
                        font.pointSize: Theme.body
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: systemTools.setUiLanguage(modelData.id)
                    }
                }
            }
        }
    }
}
