import QtQuick
import QtQuick.Layouts

// 设置页的「锁屏与安全」分区：每个账户独立设置无操作自动锁屏时长。
// 0 表示永不；访客/临时用户不读取这里，固定 5 分钟（见 SessionGate/临时会话）。
SettingsGroup {
    id: root
    objectName: "lockSettings"
    iconName: "verified_user"
    accentColor: Theme.accent
    title: I18n.t("锁屏与安全")
    subtitle: I18n.t("无操作后自动锁定当前账户")

    // 0 放最后，界面顺序：常用时长 → 永不。
    readonly property var durations: [1, 2, 5, 10, 15, 30, 0]
    readonly property int savedMinutes: sessionManager.ownLockTimeoutMinutes
    readonly property int currentMinutes: savedMinutes >= 0 ? savedMinutes : 5
    readonly property int effectiveMinutes: Math.floor(sessionManager.autoLockSeconds / 60)
    property string notice: ""

    function durationLabel(minutes) {
        return minutes === 0 ? I18n.t("永不") : minutes + " " + I18n.t("分钟")
    }

    CarText {
        Layout.fillWidth: true
        text: I18n.t("当前：") + root.durationLabel(root.effectiveMinutes)
        color: Theme.foreground
        fontPixelSize: Theme.body
    }

    Flow {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        Repeater {
            model: root.durations
            delegate: CarButton {
                required property int modelData
                text: root.durationLabel(modelData)
                checked: root.currentMinutes === modelData
                Accessible.name: I18n.t("自动锁屏 ") + root.durationLabel(modelData)
                onClicked: {
                    root.notice = sessionManager.setOwnLockTimeout(modelData)
                                  ? "" : I18n.t("保存失败")
                }
            }
        }
    }

    CarText {
        Layout.fillWidth: true
        text: I18n.t("仅影响当前账户。")
        color: Theme.outline
        fontPixelSize: Theme.fontLabel
    }

    CarText {
        Layout.fillWidth: true
        visible: root.notice.length > 0
        text: root.notice
        color: Theme.warning
        fontPixelSize: Theme.fontLabel
        wrapMode: Text.WordWrap
    }

    CarText {
        Layout.fillWidth: true
        visible: sessionManager.autoLockSeconds === 0
        text: I18n.t("永不锁屏会让他人直接看到你的界面；仅建议在可信环境使用。")
        color: Theme.danger
        fontPixelSize: Theme.fontLabel
        wrapMode: Text.WordWrap
    }
}
