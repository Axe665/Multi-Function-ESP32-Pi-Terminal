import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 安全状态只读区（信任库 / 本机身份 / UID 索引密钥 / 槽位）。
//
// 从「用户与权限」页抽出，供「连接管理 → 连接设置」复用；本组件不画标题，
// 外层 SettingsGroup 提供图标与标题。接 SecurityStatus 单例，不提供写操作。
Item {
    id: section

    readonly property bool hasSecurityStatus: typeof securityStatus !== "undefined" && securityStatus
    // 安全状态是响应式的（QFileSystemWatcher），直接绑定即可。
    readonly property var trustRows: hasSecurityStatus ? securityStatus.trustRecords : []
    readonly property bool trustHealthy: hasSecurityStatus ? securityStatus.trustStoreHealthy : false
    readonly property string trustPath: hasSecurityStatus ? securityStatus.trustStorePath : ""
    readonly property string identityFingerprint: hasSecurityStatus ? securityStatus.identityFingerprint : ""
    readonly property string identityState: hasSecurityStatus ? securityStatus.identityState : "unavailable"
    readonly property bool uidKeyReady: hasSecurityStatus ? securityStatus.uidKeyReady : false
    property var slotRows: []
    property string slotStatsText: ""

    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Theme.gap / 2

        CarText {
            Layout.fillWidth: true
            visible: !section.hasSecurityStatus
            text: I18n.t("安全状态接口不可用")
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
        }
        CarText {
            Layout.fillWidth: true
            visible: section.hasSecurityStatus
            text: I18n.t("信任库：") + (section.trustHealthy ? I18n.t("正常") : I18n.t("异常"))
                  + " " + I18n.t("已配对 ") + section.trustRows.length
            color: section.trustHealthy ? Theme.foreground : Theme.warning
            fontPixelSize: Theme.body
        }
        Repeater {
            model: section.trustRows
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    text: (modelData.bridgeId || "") + " · " + (modelData.fingerprintHex || "")
                    color: Theme.outline
                    fontPixelSize: Theme.fontCaption
                    elide: Text.ElideMiddle
                }
            }
        }
        CarText {
            Layout.fillWidth: true
            visible: section.hasSecurityStatus
            text: I18n.t("本机身份：") + (section.identityFingerprint.length > 0
                                          ? section.identityFingerprint
                                          : I18n.t("未生成"))
                  + " · " + section.identityStateText()
            color: section.identityState === "ready" ? Theme.foreground : Theme.warning
            fontPixelSize: Theme.body
            wrapMode: Text.WrapAnywhere
        }
        CarText {
            Layout.fillWidth: true
            visible: section.hasSecurityStatus
            text: I18n.t("UID 索引密钥：") + (section.uidKeyReady ? I18n.t("就绪") : I18n.t("未就绪"))
            color: section.uidKeyReady ? Theme.foreground : Theme.warning
            fontPixelSize: Theme.body
        }
        CarText {
            Layout.fillWidth: true
            visible: section.hasSecurityStatus
            text: I18n.t("槽位：") + section.slotStatsText
            color: Theme.outline
            fontPixelSize: Theme.fontCaption
            wrapMode: Text.WordWrap
        }
        Repeater {
            model: section.slotRows
            delegate: CarText {
                required property var modelData
                Layout.fillWidth: true
                text: I18n.t("槽 ") + modelData.slotId + I18n.t("：") + modelData.label
                color: Theme.foreground
                fontPixelSize: Theme.fontLabel
            }
        }
        CarButton {
            objectName: "refreshSecurityStatusButton"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            visible: section.hasSecurityStatus
            text: I18n.t("刷新安全状态")
            onClicked: section.refreshSecurityStatus()
        }
    }

    Component.onCompleted: refreshSecurityStatus()

    function identityStateText() {
        if (identityState === "ready") return I18n.t("正常")
        if (identityState === "missing") return I18n.t("未生成")
        if (identityState === "corrupt") return I18n.t("已损坏")
        return I18n.t("不可用")
    }

    function refreshSecurityStatus() {
        if (!hasSecurityStatus) {
            slotRows = []
            slotStatsText = ""
            return
        }
        securityStatus.refresh()
        const rows = []
        for (const slot of securityStatus.slotSnapshot()) {
            rows.push({
                slotId: slot.slot,
                label: slot.bound ? (slot.deviceId + " · " + slot.generation) : I18n.t("未绑定")
            })
        }
        slotRows = rows
        const stats = securityStatus.slotStats()
        slotStatsText = I18n.t("接受 ") + stats.accepted + " " + I18n.t("拒绝 ") + stats.rejected
                        + (stats.lastRejection ? " " + stats.lastRejection : "")
    }
}
