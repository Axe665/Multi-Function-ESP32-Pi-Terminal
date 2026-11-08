import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 「联网权限」二级页。
//
// 安全模型：
// - 页面只编辑草稿；真正写入必须点“保存”，再重验当前管理员 PIN；
// - 保存经 NetworkPolicyController → Polkit/pkexec → root helper 写 root 策略；
// - 默认拒绝；v2 只有应用级开关，不再维护域名 allowlist。
// - 代理仍只允许公网目的地；音乐本机 Node 例外。
// - 本页不做网络请求；networkGate 只在保存成功、策略重载后更新。
RightSlidePage {
    id: page
    objectName: "networkPermissionsPage"

    property var draftApps: []
    property bool dirty: false
    property string saveStatus: ""
    property bool saving: false
    property var moduleCards: []
    property var moduleDraft: []

    function refreshModuleCards() {
        moduleCards = (typeof connectionManager !== "undefined")
            ? connectionManager.cards.slice() : []
        if (!dirty) resetModuleDraft()
    }

    function resetModuleDraft() {
        const out = []
        for (let i = 0; i < moduleCards.length; ++i) {
            const card = moduleCards[i]
            const networkApi = String(card.networkApi || "none")
            const fileApi = String(card.fileApi || "none")
            if (networkApi !== "broker" && fileApi !== "home-read") continue
            const id = String(card.packageId || "")
            if (id === "") continue
            out.push({
                packageId: id,
                instance: String(card.instance || ""),
                title: String(card.title || id),
                networkApi: networkApi,
                fileApi: fileApi,
                network: networkPolicy.moduleNetworkEnabled(id),
                file: networkPolicy.moduleFileEnabled(id)
            })
        }
        moduleDraft = out
    }

    function updateModule(packageId, key, value) {
        const next = []
        for (let i = 0; i < moduleDraft.length; ++i) {
            const row = moduleDraft[i]
            if (row.packageId !== packageId) { next.push(row); continue }
            const updated = Object.assign({}, row)
            updated[key] = value
            next.push(updated)
        }
        moduleDraft = next
        dirty = true
        saveStatus = ""
    }

    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    Shortcut {
        sequence: "Escape"
        enabled: page.open && !adminPinDialog.opened
        onActivated: page.closeRequested()
    }

    onOpenChanged: {
        if (open) {
            if (!sessionManager.isAdmin) { page.closeRequested(); return }
            pageFlick.contentY = 0
            page.resetDraft()
            page.refreshModuleCards()
            networkPolicy.refresh()
        } else {
            if (adminPinDialog.opened) adminPinDialog.close()
        }
    }

    Connections {
        target: networkPolicy
        function onChanged() {
            if (!page.dirty) page.resetDraft()
        }
    }

    Connections {
        target: (typeof connectionManager !== "undefined") ? connectionManager : null
        function onCardsChanged() { page.refreshModuleCards() }
    }

    function copyApps(source) {
        const out = []
        if (!source) return out
        for (let i = 0; i < source.length; ++i) {
            const app = source[i]
            out.push({ id: String(app.id), name: String(app.name), enabled: !!app.enabled })
        }
        return out
    }

    function resetDraft() {
        draftApps = copyApps(networkPolicy.apps)
        resetModuleDraft()
        dirty = false
        saveStatus = networkPolicy.loaded ? "" : I18n.t("策略文件缺失或损坏：当前全部拒绝，保存后生效。")
    }

    function updateApp(appId, enabled) {
        const next = copyApps(draftApps)
        for (let i = 0; i < next.length; ++i) {
            if (next[i].id !== appId) continue
            if (enabled !== undefined) next[i].enabled = enabled
            break
        }
        draftApps = next
        dirty = true
        saveStatus = ""
    }

    function iconFor(appId) {
        if (appId === "browser") return "public"
        if (appId === "tv") return "tv"
        if (appId === "weather") return "wb_cloudy"
        if (appId === "time") return "schedule"
        if (appId === "music") return "volume_up"
        if (appId === "updates") return "download"
        return "apps"
    }

    function commit() {
        if (page.saving) return
        page.saving = true
        const result = networkPolicy.save(page.draftApps, page.moduleDraft, adminPinField.text)
        page.saving = false
        if (result.ok) {
            adminPinField.text = ""
            adminPinDialog.close()
            page.resetDraft()
            page.saveStatus = I18n.t("策略已保存并生效")
        } else {
            page.saveStatus = String(result.error || I18n.t("保存失败"))
            if (String(result.code) === "AUTH_FAILED" || String(result.code) === "RATE_LIMITED")
                adminPinField.text = ""
        }
    }

    // 外层直角底把设置页彻底盖住；圆角交给内层面板画。
    Rectangle {
        anchors.fill: parent
        radius: Theme.shapeLarge
        color: Theme.surfaceContainer
        antialiasing: true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.gap
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outlineVariant
        border.width: 1
        clip: true

        Column {
            id: panelColumn
            x: Theme.gap
            y: Theme.gap
            width: Math.max(1, parent.width - Theme.gap * 2)
            spacing: Theme.gap

            Row {
                width: panelColumn.width
                height: Math.max(Theme.hit, backButton.height)
                spacing: Theme.gap / 2

                IconButton {
                    id: backButton
                    objectName: "networkPermissionsBack"
                    iconName: "arrow_back"
                    label: I18n.t("返回")
                    onClicked: page.closeRequested()
                }
                CarText {
                    width: Math.max(1, panelColumn.width - backButton.width - Theme.gap / 2)
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    heading: true
                    text: I18n.t("各功能联网权限")
                    elide: Text.ElideRight
                }
            }
        }

        Flickable {
            id: pageFlick
            objectName: "networkPermissionsFlick"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: panelColumn.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.gap
            anchors.topMargin: Theme.gap / 2
            clip: true
            contentWidth: width
            contentHeight: pageColumn.height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                implicitWidth: 12 * Theme.scaleFactor
                contentItem: Rectangle {
                    implicitWidth: 4 * Theme.scaleFactor
                    radius: Theme.shapeFull
                    color: Theme.outline
                }
            }

            Column {
                id: pageColumn
                width: pageFlick.width
                spacing: Theme.gap

                SettingsGroup {
                    width: pageColumn.width
                    iconName: "public"
                    accentColor: "#35a9ff"
                    title: I18n.t("联网策略")
                    subtitle: I18n.t("默认拒绝；只有管理员保存后才生效")

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.gap / 2
                        CarText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            fontPixelSize: Theme.fontCaption
                            subdued: true
                            text: I18n.t("开启后允许访问公网；本机、局域网、链路本地和组播地址始终拒绝。音乐本机 Node 是唯一例外。")
                        }
                        CarButton {
                            objectName: "networkPolicySave"
                            text: page.saving ? I18n.t("保存中…") : I18n.t("保存策略")
                            accent: true
                            enabled: !page.saving && page.dirty
                            onClicked: {
                                adminPinField.text = ""
                                adminPinDialog.open()
                            }
                        }
                    }

                    CarText {
                        Layout.fillWidth: true
                        visible: page.saveStatus !== ""
                        wrapMode: Text.Wrap
                        color: page.saveStatus === I18n.t("策略已保存并生效") ? Theme.accent : Theme.warning
                        text: page.saveStatus
                    }

                    // 部署状态：helper 没装时保存一定失败，先在页面上说清楚。
                    CarText {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        fontPixelSize: Theme.fontCaption
                        color: networkPolicy.helperInstalled ? Theme.outline : Theme.warning
                        text: networkPolicy.helperInstalled
                              ? I18n.t("策略写入：已安装 helper，保存时需验证管理员 PIN 并通过系统认证。")
                              : I18n.t("策略写入：未安装 net-policy-helper，保存会失败。请先安装后再试。")
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }

                    Repeater {
                        objectName: "netPolicyRepeater"
                        model: page.draftApps
                        delegate: Column {
                            id: appRow
                            property int appIndex: index
                            property var appData: page.draftApps[appIndex]
                            Layout.fillWidth: true
                            width: pageColumn.width
                            spacing: 4 * Theme.scaleFactor

                            RowLayout {
                                width: parent.width
                                spacing: Theme.gap / 2
                                MaterialIcon {
                                    Layout.preferredWidth: 24 * Theme.scaleFactor
                                    Layout.preferredHeight: 24 * Theme.scaleFactor
                                    name: page.iconFor(appRow.appData.id)
                                }
                                CarText {
                                    Layout.fillWidth: true
                                    text: I18n.t(appRow.appData.name)
                                    elide: Text.ElideRight
                                }
                                Switch {
                                    objectName: "netPolicyApp_" + appRow.appData.id
                                    checked: appRow.appData.enabled
                                    onClicked: page.updateApp(appRow.appData.id, checked)
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                            }
                        }
                    }

                    CarText {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        fontPixelSize: Theme.fontCaption
                        subdued: true
                        text: I18n.t("修改联网策略需要当前管理员 PIN；失败按登录限速与锁定计数处理。")
                    }
                }

                SettingsGroup {
                    width: pageColumn.width
                    visible: page.moduleDraft.length > 0
                    iconName: "extension"
                    accentColor: "#8f7bff"
                    title: I18n.t("第三方应用")
                    subtitle: I18n.t("按模块授权公网/文件；保存后生效")

                    CarText {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        fontPixelSize: Theme.fontCaption
                        subdued: true
                        text: I18n.t("与内置应用一起经管理员 PIN 保存。模块仍只能访问公网；文件访问为家目录只读、本包数据可写。")
                    }

                    Repeater {
                        model: page.moduleDraft
                        delegate: Column {
                            id: moduleRow
                            required property var modelData
                            width: pageColumn.width
                            spacing: 4 * Theme.scaleFactor

                            RowLayout {
                                width: parent.width
                                spacing: Theme.gap / 2
                                MaterialIcon {
                                    Layout.preferredWidth: 24 * Theme.scaleFactor
                                    Layout.preferredHeight: 24 * Theme.scaleFactor
                                    name: "extension"
                                }
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 2 * Theme.scaleFactor
                                    CarText {
                                        width: parent.width
                                        text: moduleRow.modelData.title
                                        elide: Text.ElideRight
                                    }
                                    CarText {
                                        width: parent.width
                                        text: moduleRow.modelData.packageId
                                        fontPixelSize: Theme.fontCaption
                                        subdued: true
                                        elide: Text.ElideMiddle
                                    }
                                }
                                Switch {
                                    objectName: "netPolicyModule_" + moduleRow.modelData.packageId
                                    visible: moduleRow.modelData.networkApi === "broker"
                                    checked: moduleRow.modelData.network
                                    onClicked: page.updateModule(moduleRow.modelData.packageId,
                                                                 "network", checked)
                                }
                            }

                            RowLayout {
                                width: parent.width
                                visible: String(moduleRow.modelData.fileApi) === "home-read"
                                spacing: Theme.gap / 2
                                CarText {
                                    Layout.fillWidth: true
                                    text: I18n.t("文件访问（家目录只读）")
                                    fontPixelSize: Theme.fontCaption
                                    subdued: true
                                    wrapMode: Text.Wrap
                                }
                                Switch {
                                    objectName: "filePolicyModule_" + moduleRow.modelData.packageId
                                    checked: moduleRow.modelData.file
                                    onClicked: page.updateModule(moduleRow.modelData.packageId,
                                                                 "file", checked)
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                            }
                        }
                    }
                }
            }
        }
    }

    Popup {
        id: adminPinDialog
        objectName: "networkPolicyAdminPinDialog"
        parent: Overlay.overlay
        // 键盘可见时上移，避免弹窗里的输入框被挡。
        x: parent ? (parent.width - width) / 2 : 0
        y: {
            const host = parent ? parent.Window.window : null
            const kb = host ? host.virtualKeyboard : null
            const centered = parent ? Math.max(0, (parent.height - height) / 2) : 0
            if (!host || !kb || !kb.visible) return centered
            return Math.max(0, Math.min(centered, host.height - kb.y - height - Theme.gap))
        }
        modal: true
        dim: true
        closePolicy: Popup.CloseOnEscape
        padding: Theme.gap
        width: Math.min(420 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                heading: true
                text: I18n.t("验证管理员 PIN")
            }
            CarText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                fontPixelSize: Theme.fontCaption
                subdued: true
                text: I18n.t("保存后立即生效；连续失败会按登录策略锁定。")
            }
            CarField {
                id: adminPinField
                Layout.fillWidth: true
                placeholderText: I18n.t("管理员 PIN")
                echoMode: TextInput.Password
                inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhNoPredictiveText
                onAccepted: page.commit()
            }
            // 保存失败时把原因直接显示在弹窗里：pkexec/helper 的错误不会再让
            // 用户面对一个"输入 PIN 之后没反应"的弹窗。
            CarText {
                Layout.fillWidth: true
                visible: adminPinDialog.opened && page.saveStatus !== ""
                text: page.saveStatus
                color: Theme.warning
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                Item { Layout.fillWidth: true }
                CarButton {
                    objectName: "networkPolicyPinCancel"
                    text: I18n.t("取消")
                    onClicked: adminPinDialog.close()
                }
                CarButton {
                    objectName: "networkPolicyPinConfirm"
                    text: page.saving ? I18n.t("保存中…") : I18n.t("确认保存")
                    accent: true
                    enabled: !page.saving && adminPinField.text.length >= 6
                    onClicked: page.commit()
                }
            }
        }
    }
}
