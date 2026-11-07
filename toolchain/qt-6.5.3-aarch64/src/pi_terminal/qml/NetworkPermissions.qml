import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 设置页「联网权限」分区（§9.3）。
//
// 这里只留：总开关 + 一行状态说明 + 一个入口；六个分功能开关、每项说明与三态
// 状态都移到二级页 NetworkPermissionsPage.qml。二级页的开关绑定 NetworkGate 的
// Q_PROPERTY（browserAllowed 等），不能用 featureEnabled()——方法调用不建立依赖，
// changed 之后按钮外观不刷新，表现就是"点了没反应"。
//
// 语义：
// - 总开关关闭 = 所有功能都不再发起外网请求；子开关各自的状态**保留**，
//   重新打开总开关即原样恢复，不需要用户再逐个打开。
// - 关总开关前有确认弹窗，说明影响范围（含"正在播放的在线内容会立即停止"）。
// - 本地功能不受影响：本地音乐、本地视频、文件与模块的 BLE/LAN 链路照常。
SettingsGroup {
    id: root
    objectName: "networkPermissionsGroup"

    signal manageRequested()

    iconName: "wifi"
    accentColor: "#35a9ff"
    title: I18n.t("联网权限")
    subtitle: I18n.t("总开关与各功能联网")

    // 总开关。用 Binding 把 Switch 钉在真实状态上：点关闭时先弹确认，
    // 确认前开关会回弹，避免出现"看着关掉了其实没关"的错觉。
    // 总开关用 CarButton 而不是 Switch：Switch 会在 released 里先把 checked 翻掉
    // 再发 clicked，确认弹窗期间界面就会显示"已关闭"而实际还没关；把 checked
    // 绑死成只读、点击只走 onClicked，显示与状态才不会错位。
    CarButton {
        objectName: "networkMasterSwitch"
        Layout.fillWidth: true
        enabled: sessionManager.isAdmin
        text: networkGate.enabled
              ? I18n.t("联网总闸：已开启")
              : I18n.t("联网总闸：已关闭")
        checked: networkGate.enabled
        onClicked: {
            if (!sessionManager.isAdmin) return
            if (networkGate.enabled) confirmOff.open()
            else networkGate.setEnabledFromUi(true)
        }
    }

    CarText {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        subdued: true
        text: !sessionManager.isAdmin
              ? I18n.t("只有管理员可以修改联网权限。当前配置由管理员策略决定。")
              : (networkGate.enabled
                 ? I18n.t("所有应用默认拒绝；管理员可逐项开启。开启后只允许公网，本机与局域网始终拒绝。")
                 : I18n.t("联网总闸已关闭，终端的浏览器、音乐、电视、天气、校时与更新都不会访问外网。"))
    }

    CarButton {
        objectName: "openNetworkPermissions"
        Layout.fillWidth: true
        visible: sessionManager.isAdmin
        text: I18n.t("管理各功能联网")
        onClicked: root.manageRequested()
    }

    // 关闭确认：说清影响范围与在途行为，避免"点了才发现在放歌"。
    Popup {
        id: confirmOff
        objectName: "networkOffConfirm"
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
        width: Math.min(460 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }
        contentItem: Loader {
            active: confirmOff.opened
            sourceComponent: Component {
                ColumnLayout {
            spacing: Theme.gap
            CarText {
                Layout.fillWidth: true
                heading: true
                text: I18n.t("关闭联网权限？")
            }
            CarText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: I18n.t("浏览器、音乐、网络电视、天气、校时与更新都不会再发起外网请求，"
                             + "正在播放的在线内容会立即停止。本地文件播放不受影响。")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                Item { Layout.fillWidth: true }
                CarButton {
                    objectName: "networkOffCancel"
                    text: I18n.t("取消")
                    onClicked: confirmOff.close()
                }
                CarButton {
                    objectName: "networkOffConfirmAccept"
                    text: I18n.t("确认关闭")
                    onClicked: {
                        networkGate.setEnabledFromUi(false)
                        confirmOff.close()
                    }
                }
            }
                }
            }
        }
    }
}
