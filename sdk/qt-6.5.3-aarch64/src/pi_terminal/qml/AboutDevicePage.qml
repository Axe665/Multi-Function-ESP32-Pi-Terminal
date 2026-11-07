import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 「关于本机」二级页：从设置页最后一张卡片滑入（240ms，同连接设置）。
//
// 边界（与作者约定一致）：
// - 本机名称只是本应用设置里的一个字段，不改 /etc/hostname、不改程序内部
//   applicationName / productName，也不影响登录页与托盘里作者写死的产品名。
// - 型号「模块化终端（第一代）」集中放在 modelName 一处，将来换真实型号只改这里。
// - 硬件信息全部来自 MachineInfo::snapshot()（运行时读 /proc、statvfs、QSysInfo），
//   读不到就显示「未知」，不编造。
// - 编辑复用项目现有虚拟键盘：输入框聚焦时发 keyboardRequested，由 Main 打开
//   FloatingKeyboard，不改键盘本身。
// - 软件更新只做占位弹窗，不放假的下载/进度 UI。
RightSlidePage {
    id: page
    objectName: "aboutDevicePage"

    signal keyboardRequested()
    signal keyboardDismissRequested()

    readonly property string defaultName: "模块化终端（第一代）"
    readonly property string modelName: "模块化终端（第一代）"

    property string deviceName: ""
    property var info: ({})
    property bool editing: false
    property string draft: ""
    // 「开发者与感谢」名单页是否打开。名单页是本页的下一层，
    // 关闭关于本机时一并收起，避免下次打开残留。
    property bool creditsOpen: false

    // 彩蛋：连点「版本号」5 次才放出「开发者与感谢」入口，名单页里的「取消」
    // 把它收回。状态只在本次运行里保持，不写设置、不落盘。
    property bool creditsRevealed: false
    property int creditsTapCount: 0

    function registerVersionTap() {
        if (creditsRevealed) return
        creditsTapCount += 1
        creditsTapReset.restart()
        if (creditsTapCount >= 5) {
            creditsTapCount = 0
            creditsTapReset.stop()
            creditsRevealed = true
        }
    }

    // 连点窗口 1.5 秒：停手就清零，零散点击凑不满 5 次。
    Timer {
        id: creditsTapReset
        interval: 1500
        onTriggered: page.creditsTapCount = 0
    }

    z: 30
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    function reload() {
        info = machineInfo.snapshot()
        let saved = systemTools.settingsRead("about/device-name", "")
        deviceName = saved.length > 0 ? saved : defaultName
    }
    // 点铅笔只进入编辑态，不立刻聚焦：键盘一弹就盖住编辑行，先让用户看到
    // 输入框与保存/取消，点输入框时再按作者原有方式弹出虚拟键盘。
    function startEditing() {
        draft = deviceName
        editing = true
    }
    // 键盘弹出后把编辑行滚到可视区顶部（键盘占掉下半屏，不滚就看不见输入内容）。
    function revealEditor() {
        Qt.callLater(function() {
            const target = namePlate.y + 72 * Theme.scaleFactor
            aboutFlick.contentY = Math.max(0, Math.min(aboutFlick.contentHeight - aboutFlick.height, target))
        })
    }
    function saveName() {
        const value = draft.trim()
        if (value.length === 0) return
        if (systemTools.settingsWrite("about/device-name", value)) deviceName = value
        editing = false
        page.keyboardDismissRequested()
    }
    function resetName() {
        systemTools.settingsWrite("about/device-name", "")
        deviceName = defaultName
        editing = false
        page.keyboardDismissRequested()
    }
    function bytes(value) {
        if (!value || value <= 0) return ""
        const gb = value / 1073741824
        return gb >= 10 ? gb.toFixed(0) + " GB" : gb.toFixed(1) + " GB"
    }
    function cpuLine() {
        const model = info.cpuModel && info.cpuModel.length ? info.cpuModel : I18n.t("未知")
        const cores = info.cpuCores > 0 ? " × " + info.cpuCores : ""
        // 不换行空格把「· 架构」绑在一起：折行时整段一起走，不会断成孤零零的 "·"。
        const arch = info.cpuArch ? "\u00A0·\u00A0" + info.cpuArch : ""
        return model + cores + arch
    }
    // 中英文语序不同，用占位符模板而不是拼接："16 GB（可用 5.2 GB）" /
    // "5.2 GB free of 16 GB"（词表里是 AVAIL free of TOTAL）。
    function usageLine(totalBytes, availableBytes) {
        const total = bytes(totalBytes)
        if (total.length === 0) return I18n.t("未知")
        const available = bytes(availableBytes)
        if (available.length === 0) return total
        return I18n.t("TOTAL（可用 AVAIL）").replace("TOTAL", total).replace("AVAIL", available)
    }
    function memoryLine() { return usageLine(info.memTotalBytes, info.memAvailableBytes) }
    function storageLine() { return usageLine(info.diskTotalBytes, info.diskAvailableBytes) }
    function gpuLine() {
        const name = info.gpuName || ""
        const driver = info.gpuDriver || ""
        const pci = info.gpuPciId || ""
        if (name.length && driver.length) return name + " · " + driver
        if (name.length) return name
        if (driver.length) return driver + (pci.length ? " · " + pci : "")
        if (pci.length) return pci
        return I18n.t("未知")
    }
    // 无线 / 有线各一行：多张同类型网卡用「；」串起来，没有就写未检测到。
    function nicLine(kind) {
        const all = info.nics || []
        const items = all.filter(function(n) { return n.kind === kind })
        if (items.length === 0) return I18n.t("未检测到")
        return items.map(function(n) {
            const ips = (n.addresses && n.addresses.length) ? n.addresses.join(", ") : ""
            let text = n.name
            if (ips.length) text += " · " + ips
            if (n.mac && n.mac.length) text += " · " + n.mac
            return text
        }).join(I18n.t("；"))
    }
    function kernelLine() {
        if (!info.kernelVersion) return I18n.t("未知")
        // QSysInfo::kernelType() 返回小写 "linux"，界面上按惯例写成 Linux。
        const type = info.kernelType
        const pretty = type.length > 0 ? type.charAt(0).toUpperCase() + type.slice(1) : ""
        return (pretty.length > 0 ? pretty + " " : "") + info.kernelVersion
    }
    function buildLine() {
        return info.buildDate && info.buildDate.length ? "build " + info.buildDate : I18n.t("未知")
    }

    onOpenChanged: {
        if (open) {
            editing = false
            reload()
            // 每次打开从顶部开始。
            Qt.callLater(function() { aboutFlick.contentY = 0 })
        } else {
            // 关于本机整体收起时，名单页也要无动画归位，不能留在右侧滑出位置。
            creditsOpen = false
            credits.hideImmediately()
            if (updateDialog.opened) updateDialog.close()
        }
    }

    Shortcut {
        sequence: "Escape"
        // 名单页打开时 Esc 先关名单（它自己的 Shortcut），不要再关整个关于本机。
        enabled: page.open && !page.creditsOpen
        onActivated: page.closeRequested()
    }

    // 外层直角底把设置页彻底盖住；圆角交给内层面板画，四角不漏底色。
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
                    objectName: "aboutDeviceBack"
                    iconName: "arrow_back"
                    label: I18n.t("返回")
                    onClicked: page.closeRequested()
                }
                CarText {
                    width: Math.max(1, panelColumn.width - backButton.width - Theme.gap / 2)
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    heading: true
                    text: I18n.t("关于本机")
                    elide: Text.ElideRight
                }
            }
        }

        Flickable {
            id: aboutFlick
            objectName: "aboutDeviceFlick"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: panelColumn.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.gap
            anchors.topMargin: Theme.gap / 2
            clip: true
            contentWidth: width
            contentHeight: aboutColumn.height
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
                id: aboutColumn
                width: aboutFlick.width
                spacing: Theme.gap

                // ---- 设备铭牌：名称（可编辑）+ 型号 ----
                Rectangle {
                    width: aboutColumn.width
                    height: namePlate.height + Theme.gap * 2
                    radius: Theme.shapeLarge
                    color: Theme.surface
                    border.color: Theme.outlineVariant
                    border.width: 1

                    Column {
                        id: namePlate
                        x: Theme.gap
                        y: Theme.gap
                        width: Math.max(1, parent.width - Theme.gap * 2)
                        spacing: Theme.gap / 2

                        Row {
                            width: namePlate.width
                            height: Math.max(56 * Theme.scaleFactor, nameBlock.height)
                            spacing: Theme.gap

                            MaterialIcon {
                                id: badge
                                anchors.verticalCenter: parent.verticalCenter
                                width: 44 * Theme.scaleFactor
                                height: width
                                name: "info"
                                light: true
                            }
                            Column {
                                id: nameBlock
                                // 右侧按钮宽约 Theme.hit（铅笔 / 恢复默认同尺寸），用常量算，
                                // 不引用按钮 width：初始化时按钮宽度还是 0，会把按钮挤出卡片。
                                width: Math.max(1, namePlate.width - badge.width - Theme.gap * 2 - Theme.hit)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2 * Theme.scaleFactor

                                CarText {
                                    objectName: "aboutDeviceName"
                                    width: nameBlock.width
                                    text: page.deviceName
                                    fontPixelSize: Theme.title
                                    elide: Text.ElideRight
                                    visible: !page.editing
                                }
                                CarText {
                                    width: nameBlock.width
                                    text: I18n.t("型号") + " · " + page.modelName
                                    subdued: true
                                    elide: Text.ElideRight
                                }
                            }
                            IconButton {
                                id: pencil
                                objectName: "aboutDeviceRename"
                                iconName: "build"
                                label: I18n.t("修改本机名称")
                                visible: !page.editing
                                onClicked: page.startEditing()
                            }
                            // 编辑态把「恢复默认」放到名称行右侧，编辑行只留
                            // 输入框 + 保存/取消：一行放得下，才不会被虚拟键盘压住。
                            IconButton {
                                objectName: "aboutDeviceNameReset"
                                iconName: "refresh"
                                label: I18n.t("恢复默认")
                                visible: page.editing
                                onClicked: page.resetName()
                            }
                        }

                        // 编辑态：输入框 + 保存 / 取消（同一行，落在键盘上方）。
                        // 用 anchors 分配宽度而不是 Row：Row 里 CarField 若引用按钮宽度，
                        // 初始化时按钮还是 0 宽，输入框会吃满整行、把按钮挤出卡片。
                        Item {
                            width: namePlate.width
                            height: Math.max(Theme.hit, 48 * Theme.scaleFactor)
                            visible: page.editing

                            CarField {
                                id: nameField
                                objectName: "aboutDeviceNameField"
                                anchors.left: parent.left
                                anchors.right: saveNameButton.left
                                anchors.rightMargin: Theme.gap / 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.draft
                                maximumLength: 40
                                // 不显示占位字样；键盘只在用户点输入框时打开。
                                // 不能用 onActiveFocusChanged：关闭键盘会让输入框重新拿到
                                // 焦点，又把键盘顶起来，看起来就是“关不上”。
                                onTextChanged: page.draft = text
                                Keys.onReturnPressed: page.saveName()
                                TapHandler {
                                    onTapped: { page.revealEditor(); page.keyboardRequested() }
                                }
                            }
                            CarButton {
                                id: cancelNameButton
                                objectName: "aboutDeviceNameCancel"
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: I18n.t("取消")
                                onClicked: { page.editing = false; page.keyboardDismissRequested() }
                            }
                            CarButton {
                                id: saveNameButton
                                objectName: "aboutDeviceNameSave"
                                anchors.right: cancelNameButton.left
                                anchors.rightMargin: Theme.gap / 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: I18n.t("保存")
                                enabled: page.draft.trim().length > 0
                                onClicked: page.saveName()
                            }
                        }
                    }
                }

                // ---- 设备信息：处理器 / 内存 / 存储 / 内核 / 版本号 ----
                SettingsGroup {
                    width: aboutColumn.width
                    iconName: "memory"
                    accentColor: "#4c9dff"
                    title: I18n.t("设备信息")
                    subtitle: I18n.t("本机实时读取，不做缓存")

                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoCpu"
                        iconName: "developer_board"
                        label: I18n.t("处理器")
                        value: page.cpuLine()
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoGpu"
                        iconName: "gpu"
                        label: I18n.t("图形处理器")
                        value: page.gpuLine()
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoMemory"
                        iconName: "memory"
                        label: I18n.t("内存")
                        value: page.memoryLine()
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoStorage"
                        iconName: "storage"
                        label: I18n.t("存储")
                        value: page.storageLine()
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoKernel"
                        iconName: "code"
                        label: I18n.t("内核")
                        value: page.kernelLine()
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoVersion"
                        iconName: "tag"
                        label: I18n.t("版本号")
                        value: page.buildLine()
                        // 彩蛋入口：连点本行 5 次放出「开发者与感谢」。
                        MouseArea {
                            anchors.fill: parent
                            onClicked: page.registerVersionTap()
                        }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoWifi"
                        iconName: "wifi"
                        label: I18n.t("无线网卡")
                        value: page.nicLine("wifi")
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
                    AboutInfoRow {
                        Layout.fillWidth: true
                        objectName: "aboutInfoEthernet"
                        iconName: "lan"
                        label: I18n.t("有线网卡")
                        value: page.nicLine("ethernet")
                    }
                }

                // ---- 开发者与感谢：彩蛋，连点版本号 5 次后才出现 ----
                SettingsGroup {
                    width: aboutColumn.width
                    visible: page.creditsRevealed
                    iconName: "code"
                    accentColor: "#4c9dff"
                    title: I18n.t("开发者与感谢")
                    subtitle: I18n.t("参与这台终端的人")

                    // 入口行：左侧人数摘要，右侧箭头；悬停时整行提亮。
                    Rectangle {
                        objectName: "creditsEntry"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.hit
                        radius: Theme.shapeMedium
                        color: entryMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                        border.width: 1
                        border.color: entryMouse.containsMouse ? Theme.accent : Theme.outlineVariant

                        CarText {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gap / 2
                            anchors.right: entryChevron.left
                            anchors.rightMargin: Theme.gap / 2
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.t("开发者 D 致谢 T")
                                      .replace("D", String(credits.developers.length))
                                      .replace("T", String(credits.thanks.length))
                            fontPixelSize: Theme.body
                            color: Theme.foreground
                            elide: Text.ElideRight
                        }
                        MaterialIcon {
                            id: entryChevron
                            width: Theme.icon
                            height: width
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.gap / 2
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron_right"
                            light: true
                        }
                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: page.creditsOpen = true
                        }
                    }
                }

                // ---- 运行记录（从设置页移入） ----
                SettingsGroup {
                    width: aboutColumn.width
                    iconName: "history"
                    accentColor: "#ad8cff"
                    title: I18n.t("运行记录")
                    subtitle: I18n.t("最近系统操作")
                    CarText {
                        Layout.fillWidth: true
                        visible: systemTools.logs.length === 0
                        text: I18n.t("暂无记录")
                        subdued: true
                    }
                    Repeater {
                        model: systemTools.logs
                        CarText {
                            required property string modelData
                            Layout.fillWidth: true
                            text: I18n.t(modelData)
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // ---- 软件更新（占位） ----
                SettingsGroup {
                    width: aboutColumn.width
                    iconName: "system_update"
                    accentColor: "#4fd4a4"
                    title: I18n.t("软件更新")
                    subtitle: I18n.t("检查并安装终端的新版本")
                    CarButton {
                        objectName: "aboutUpdateButton"
                        text: I18n.t("检查更新")
                        onClicked: updateDialog.open()
                    }
                }
            }
        }
    }

    // 名单页：关于本机的下一层，从右侧滑入（240ms，同开发者选项）。
    // 盖住本页内容（z 高于两层底与滚动区），关闭时滑出。
    CreditsPage {
        id: credits
        objectName: "creditsPageHost"
        width: page.width
        height: page.height
        z: 80
        open: page.creditsOpen
        onCloseRequested: page.creditsOpen = false
        // 名单页里的「取消」：关掉页面，并把彩蛋入口一起收回。
        onCancelRequested: {
            page.creditsOpen = false
            page.creditsRevealed = false
        }
    }

    Dialog {
        id: updateDialog
        objectName: "aboutUpdateDialog"
        parent: Overlay.overlay
        z: 30000
        anchors.centerIn: parent
        width: Math.min(parent ? parent.width - 48 : 360, 420 * Theme.scaleFactor)
        padding: Theme.gap
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        Overlay.modal: Rectangle {
            color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.72)
        }
        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 1
            border.color: Theme.outlineVariant
        }

        contentItem: ColumnLayout {
            spacing: Theme.gap

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                MaterialIcon {
                    Layout.preferredWidth: 40 * Theme.scaleFactor
                    Layout.preferredHeight: 40 * Theme.scaleFactor
                    name: "system_update"
                    light: true
                }
                CarText {
                    Layout.fillWidth: true
                    heading: true
                    text: I18n.t("软件更新")
                }
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("功能完善中，敬请期待。")
                color: Theme.foreground
                wrapMode: Text.Wrap
            }
            CarButton {
                Layout.fillWidth: true
                text: I18n.t("知道了")
                onClicked: updateDialog.close()
            }
        }
    }
}
