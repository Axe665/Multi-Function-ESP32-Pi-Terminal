import QtQuick
import QtQuick.Layouts

// 第 3 步：一次性展示恢复码，要求抄写并核对第 2、5 组。
// 这是全流程唯一的“强排版”时刻：24 字符分 6 组、等宽大字号。
// 顺序上恢复码在此生成，管理员要到第 5 步才真正写盘——中途退出不会
// 留下“有用户但没恢复码”的死局。
//
// 布局注意：软键盘从屏幕下方约 y=256 处弹出，确认输入必须与恢复码
// 放在同一行（y<250），否则会被键盘整个盖住（真机截图发现）。
Item {
    id: step
    property var wizard
    property string primaryLabel: I18n.t("已抄写或已保存，继续")
    // 核对框已去掉：主按钮始终可点，点完弹一个 5 秒冷静期的确认。
    property bool primaryEnabled: true
    property bool canGoBack: true

    signal primaryAction()
    onPrimaryAction: { if (wizard) wizard.showRecoveryAck() }

    Component.onCompleted: onboarding.prepareRecoveryCode()

    Column {
        width: parent.width
        spacing: Theme.gap * 0.9

        Text {
            width: parent.width
            text: I18n.t("保存恢复码")
            color: Theme.foreground
            font.pointSize: Theme.title
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            text: I18n.t("忘记 PIN 时，这是唯一能找回数据的方式。请抄在纸上，它只显示这一次。")
            color: Theme.secondary
            opacity: 0.78
            font.pointSize: Theme.body
            lineHeight: 1.4
            wrapMode: Text.WordWrap
        }

        Row {
            spacing: Theme.gap

            Grid {
                columns: 3
                rowSpacing: Theme.gap * 0.45
                columnSpacing: Theme.gap * 1.6
                Repeater {
                    model: 6
                    Text {
                        required property int index
                        // 必须显式依赖 recoveryCode：recoveryGroup() 是 Q_INVOKABLE，
                        // 光靠函数调用不会让绑定在 prepareRecoveryCode() 之后重算，
                        // 结果就是 6 组全空（真机截图发现）。
                        text: onboarding.recoveryCode.length > 0
                              ? onboarding.recoveryGroup(index) : ""
                        color: Theme.foreground
                        font.family: "monospace"
                        // 24 而不是 27：软键盘从 y≈256 弹出，27 会把第二行压到键盘下。
                        font.pointSize: 24 * Theme.scaleFactor
                        font.letterSpacing: 3
                    }
                }
            }
        }

        // 抄写之外再给一条出路：直接存到 U 盘，省得手抄错一位。
        RecoveryExport {
            objectName: "onboardingRecoveryExport"
            width: parent.width
            recoveryCode: onboarding.recoveryCode
            userName: wizard ? wizard.displayName : ""
        }
    }

}
