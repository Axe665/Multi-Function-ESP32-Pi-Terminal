import QtQuick
import QtQuick.Layouts

// 第 5 步：完成。创建管理员是最后一个动作——在此之前没有任何文件落盘。
// 创建成功后按钮变成“进入桌面”，由用户自己决定何时切换（不自动跳）。
Item {
    id: step
    property var wizard
    property string primaryLabel: onboarding.ready
                                 ? I18n.t("进入桌面")
                                 : onboarding.busy ? I18n.t("正在创建…") : I18n.t("完成设置")
    property bool primaryEnabled: !onboarding.busy
    property bool canGoBack: false

    signal primaryAction()
    onPrimaryAction: {
        if (onboarding.ready) onboarding.dismiss()
        else onboarding.createAdmin(wizard.displayName, wizard.pin, wizard.pin)
    }

    function errorText() {
        switch (onboarding.errorCode) {
        case "name_invalid": return I18n.t("名字需要 2–24 个字符")
        case "pin_mismatch": return I18n.t("两次 PIN 不一致")
        case "pin_invalid": return I18n.t("PIN 需要 6 位数字")
        case "create_failed": return I18n.t("无法创建管理员，请重试")
        case "login_failed": return I18n.t("管理员已创建，但自动登录失败；请用刚设置的 PIN 登录")
        default: return ""
        }
    }

    Column {
        width: parent.width
        spacing: Theme.gap * 1.15

        Text {
            width: parent.width
            text: onboarding.ready ? I18n.t("设置完成") : I18n.t("准备好了")
            color: Theme.foreground
            font.pointSize: Theme.hero
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
        }
        Text {
            width: parent.width
            text: I18n.english
                  ? (onboarding.ready
                     ? "The administrator “" + wizard.displayName + "” is ready. Your PIN and recovery code are set."
                     : "The administrator “" + wizard.displayName + "” will be created on this terminal. Your PIN and recovery code are ready.")
                  : (onboarding.ready
                     ? "管理员「" + wizard.displayName + "」已创建，PIN 与恢复码都已生效。"
                     : "管理员「" + wizard.displayName + "」将在这台终端上创建。PIN 与恢复码都已就绪。")
            color: Theme.secondary
            opacity: 0.78
            font.pointSize: Theme.body
            lineHeight: 1.4
            wrapMode: Text.WordWrap
        }

        Text {
            width: parent.width
            text: I18n.t("恢复码只显示这一次，请与设备分开保管。")
            color: Theme.secondary
            opacity: 0.66
            font.pointSize: Theme.body * 0.85
            wrapMode: Text.WordWrap
        }

        Text {
            width: parent.width
            visible: step.errorText().length > 0
            text: step.errorText()
            color: Theme.danger
            font.pointSize: Theme.body * 0.9
            wrapMode: Text.WordWrap
        }
    }
}
