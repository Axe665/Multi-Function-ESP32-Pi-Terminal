import QtQuick
import QtQuick.Layouts

// 第 4 步：网络。只显示本机接口状态，不发包、不改策略。
// 联网需求留到桌面设置页：隐藏 SSID / 802.1x 不该塞进开箱向导。
Item {
    id: step
    property var wizard
    property string primaryLabel: I18n.t("继续设置")
    property bool primaryEnabled: true
    property bool canGoBack: true

    signal primaryAction()
    onPrimaryAction: wizard.goTo(4)

    Component.onCompleted: onboarding.probeNetwork()

    Column {
        width: parent.width
        spacing: Theme.gap * 1.2

        Text {
            width: parent.width
            text: I18n.t("网络连接")
            color: Theme.foreground
            font.pointSize: Theme.title
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            text: I18n.t("可以现在跳过。需要联网的应用稍后可在设置里连接网络。")
            color: Theme.secondary
            opacity: 0.78
            font.pointSize: Theme.body
            lineHeight: 1.4
            wrapMode: Text.WordWrap
        }

        Rectangle {
            width: parent.width
            height: 104 * Theme.scaleFactor
            radius: Theme.shapeLarge
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.outlineVariant

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.gap * 1.25
                anchors.right: parent.right
                anchors.rightMargin: Theme.gap * 1.25
                spacing: Theme.gap

                Rectangle {
                    width: 10
                    height: 10
                    radius: 5
                    anchors.verticalCenter: parent.verticalCenter
                    color: onboarding.networkConnected ? Theme.accent : Theme.outline
                }
                Column {
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        text: onboarding.networkConnected ? I18n.t("网络已连接") : I18n.t("未连接")
                        color: Theme.foreground
                        font.pointSize: Theme.body
                    }
                    Text {
                        text: onboarding.networkConnected
                              ? onboarding.networkSummary
                              : I18n.t("插上网线后点“重新检测”，或直接继续")
                        color: Theme.secondary
                        opacity: 0.66
                        font.pointSize: Theme.body * 0.82
                    }
                }
            }
        }

        CarButton {
            text: I18n.t("重新检测")
            onClicked: onboarding.probeNetwork()
        }
    }
}
