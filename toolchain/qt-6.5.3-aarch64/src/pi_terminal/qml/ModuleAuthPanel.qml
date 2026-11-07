import QtQuick
import QtQuick.Layouts

// 模块认证常驻面板（D 写）。
//
// 用途：不管有没有模块连上，设置里都有一块地方回答"现在认证到什么程度"。
// 无连接时显示"当前无模块连接 · 未认证"；有模块时每个模块一行，列出它在
// manifest 里请求的能力与当前授予状态，管理员可以授予/撤销。
//
// 设计依据：docs/pi-ui-regression.md —— M3 列表语义、≥48px 热区、Theme token、
// 文案走 I18n、图标本地加载。数据全部来自 connectionManager 与 securityService，
// 本组件不缓存任何授权结论。
Item {
    id: panel
    property string message: ""
    // 连接设置里由外层 SettingsGroup 提供标题，避免重复。
    property bool showTitle: true

    // 模型显式重建：不做属性绑定推导，避免"函数调用不是可观察依赖"导致的空列表。
    readonly property int rowCount: rowModel.count
    ListModel { id: rowModel }

    function refresh() {
        rowModel.clear()
        const list = connectionManager.cards
        for (let i = 0; i < list.length; ++i) {
            const card = list[i]
            rowModel.append({
                kind: "card", title: String(card.title || ""),
                stateText: stateText(card), capability: "", granted: false,
                moduleId: Number(card.moduleId)
            })
            let caps = []
            try {
                caps = securityService.requestedCapabilities(card.moduleId)
            } catch (e) {
                console.warn("ModuleAuthPanel: requestedCapabilities failed", e)
                caps = []
            }
            for (let c = 0; c < caps.length; ++c) {
                rowModel.append({
                    kind: "cap", title: "", stateText: "",
                    capability: String(caps[c].capability),
                    granted: !!caps[c].granted,
                    moduleId: Number(caps[c].moduleId !== undefined ? caps[c].moduleId : card.moduleId)
                })
            }
            if (caps.length === 0)
                rowModel.append({ kind: "empty", title: I18n.t("该模块未声明任何能力请求"),
                                  stateText: "", capability: "", granted: false,
                                  moduleId: Number(card.moduleId) })
        }
        revision += 1
    }
    property int revision: 0
    Component.onCompleted: refresh()

    implicitHeight: column.implicitHeight

    Connections {
        target: securityService
        function onChanged() { panel.refresh() }
    }
    Connections {
        target: connectionManager
        function onCardsChanged() { panel.refresh() }
    }

    function stateText(card) {
        if (!card) return I18n.t("未认证")
        if (card.ready) return I18n.t("已连接")
        if (card.state === "awaiting_trust") return I18n.t("等待确认权限")
        if (card.state === "error") return I18n.t("连接失败")
        return I18n.t("连接中")
    }

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Theme.gap / 2

        CarText {
            Layout.fillWidth: true
            visible: panel.showTitle
            text: I18n.t("模块认证")
            fontPixelSize: Theme.title
            color: Theme.foreground
        }

        CarText {
            Layout.fillWidth: true
            visible: panel.rowCount === 0
            text: I18n.t("当前无模块连接 未认证")
            color: Theme.outline
            fontPixelSize: Theme.fontLabel
        }

        CarText {
            Layout.fillWidth: true
            visible: panel.message.length > 0
            text: panel.message
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        // 扁平模型：模块行、能力行、空能力提示都走同一个 Repeater，
        // 避免 ListModel 里再塞数组导致的绑定歧义。
        Repeater {
            model: rowModel
            delegate: RowLayout {
                required property string kind
                required property string title
                required property string stateText
                required property string capability
                required property bool granted
                required property int moduleId
                Layout.fillWidth: true
                Layout.minimumHeight: Theme.hit
                spacing: Theme.gap / 2

                MaterialIcon {
                    visible: kind === "card"
                    name: "verified_user"
                    Layout.preferredWidth: Theme.icon
                    Layout.preferredHeight: Theme.icon
                }
                CarText {
                    Layout.fillWidth: true
                    visible: kind !== "cap"
                    text: kind === "card" ? title + " " + stateText : title
                    color: kind === "empty" ? Theme.outline : Theme.foreground
                    fontPixelSize: kind === "empty" ? Theme.fontCaption : Theme.body
                    elide: Text.ElideRight
                }
                CarText {
                    Layout.fillWidth: true
                    visible: kind === "cap"
                    text: capability + " · " + (granted ? I18n.t("已授予") : I18n.t("未授予"))
                    color: granted ? Theme.foreground : Theme.outline
                    fontPixelSize: Theme.fontLabel
                    elide: Text.ElideRight
                }
                CarButton {
                    visible: kind === "cap"
                    text: granted ? I18n.t("撤销授权") : I18n.t("授予")
                    enabled: sessionManager.isAdmin
                    onClicked: {
                        const ok = granted
                            ? securityService.revokeCapability(sessionManager.activeUserId, moduleId, capability)
                            : securityService.grantCapability(sessionManager.activeUserId, moduleId, capability)
                        if (!ok) panel.message = securityService.lastMessage || I18n.t("操作失败")
                        else { panel.message = ""; panel.refresh() }
                    }
                }
            }
        }
    }
}
