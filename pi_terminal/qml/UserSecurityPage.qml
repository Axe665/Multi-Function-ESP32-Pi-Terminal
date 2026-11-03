import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 用户与权限（D 写）。
//
// 设计依据：docs/pi-ui-regression.md —— M3 列表语义、主要触控热区 ≥ Theme.hit（48px）、
// 颜色/圆角/间距一律取 Theme token、文案全走 I18n.t()，图标用本地 Material 资源。
//
// 边界：
// - 只在有会话的界面里做展示与输入；身份、PIN、恢复码的判定全在 SessionManager。
// - 恢复码由服务端生成，界面只显示一次，不落盘、不写日志。
// - 非管理员看到只读列表与明确的"需要管理员权限"，不是空白页。
// - 备份/恢复/清空与手工读数直接调 SecurityService 的既有接口；本页不碰数据库。
Item {
    id: page
    property string message: ""
    property string recoveryCode: ""
    // 与 WeatherTools 同一模式：页面只发信号，宿主把作者那个 screenKeyboard 弹出来。
    signal keyboardRequested()
    // 弹窗关闭时把宿主键盘收回去；条目本身仍是作者的 FloatingKeyboard。
    signal keyboardDismissed()

    // 恢复码按 4 字符分组：展示与抄写核对共用同一份拆分。
    readonly property var recoveryGroups: {
        const normalized = String(recoveryCode || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
        const out = []
        for (let i = 0; i + 4 <= normalized.length && out.length < 6; i += 4)
            out.push(normalized.substr(i, 4))
        return out
    }
    // 新建用户后的恢复码必须核对第 2、5 组才能关闭（与首次开机向导一致）。
    property string resetPinError: ""
    // 二级页分区：0 账户 / 1 安全 / 2 其他用户 / 3 数据 / 4 高级。
    // -1 = 不分区的整体视图。UserSecurityView 总会传 0..4；单独实例化本页
    // （配对 UI 测试、设计预览）时没有分区概念，五组同时显示。
    property int section: -1
    readonly property bool showAllSections: page.section < 0
    signal closeRequested()
    // 账户真正删掉之后发一次：宿主据此拉起等待层（至少 4 秒）再切下一个界面。
    signal accountDeleted(bool lastAdmin)

    function sectionTitle() {
        switch (section) {
        case 0: return I18n.t("我的账户")
        case 1: return I18n.t("安全")
        case 2: return I18n.t("其他用户")
        case 3: return I18n.t("数据")
        case 4: return I18n.t("高级")
        default: return I18n.t("用户与权限")
        }
    }

    // 手工读数：后端 readings 表是血压专用（metric=pressure，值域 0–400）。
    property var readingRows: []
    property string readingUnit: "mmHg"

    // 危险操作的待确认参数；点「确认」前不落任何状态。
    property string pendingRestorePath: ""
    property string pendingRestorePassword: ""

    // 数据页：目标 U 盘与备份文件选择。挂载点、文件名后缀都不展示给用户。
    // 插拔由 systemTools.removableDevices 驱动，界面跟着刷新。
    readonly property var usbDevices: (typeof systemTools !== "undefined" && systemTools)
                                      ? systemTools.removableDevices : []

    function usbStillPresent(id) {
        if (id === "") return false
        for (let i = 0; i < page.usbDevices.length; ++i)
            if (page.usbDevices[i].id === id) return true
        return false
    }

    onUsbDevicesChanged: {
        if (page.exportUsbId !== "" && !page.usbStillPresent(page.exportUsbId)) page.exportUsbId = ""
        if (page.backupUsbId !== "" && !page.usbStillPresent(page.backupUsbId)) page.backupUsbId = ""
        if (page.restoreUsbId !== "" && !page.usbStillPresent(page.restoreUsbId)) {
            page.restoreUsbId = ""
            page.restoreFiles = []
            page.restoreFileLocation = ""
        }
    }
    property string exportUsbId: ""
    property string backupUsbId: ""
    property string restoreUsbId: ""
    property var restoreFiles: []
    property string restoreFileLocation: ""

    // 头像选择器当前目录（相对 filesRoot）。
    property string avatarFolder: ""

    // 管理员删除目标；确认框每次只处理一个目标。
    property string adminTargetId: ""
    property string adminTargetDisplayName: ""

    // 删除账户的一次待确认：PIN 已经验过，等确认弹窗点头才真正动手。
    property bool pendingDeleteIsSelf: false
    property string pendingDeleteName: ""

    // 「添加用户」表单默认收起，点按钮再展开。
    property bool addUserOpen: false
    readonly property var users: sessionManager.users
    readonly property int adminCount: {
        let count = 0
        for (const user of page.users) if (user.admin) ++count
        return count
    }
    // 最后一名管理员也可以自删（2026-11-01 起）：删除后注册表为空，
    // 宿主把首次开机向导重新拉起来，用户在那里重建管理员。
    // adminCount 只用于提示"你现在是最后一名管理员"。
    readonly property bool lastAdmin: sessionManager.isAdmin && page.adminCount <= 1
    readonly property bool canDeleteOwnAccount: sessionManager.loggedIn
    readonly property bool hasSecurityService: typeof securityService !== "undefined" && securityService
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
        spacing: Theme.gap

        // 详情页头部：返回主页 + 当前分区标题。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap / 2
            IconButton {
                objectName: "userSecurityBack"
                iconName: "arrow_back"
                label: I18n.t("返回")
                onClicked: page.closeRequested()
            }
            CarText {
                Layout.fillWidth: true
                text: page.sectionTitle()
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
        }

        CarText {
            Layout.fillWidth: true
            visible: page.message.length > 0
            text: page.message
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAllSections || page.section === 2
            spacing: Theme.gap

        RowLayout {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin
            spacing: Theme.gap / 2
            Item { Layout.fillWidth: true }
            CarButton {
                objectName: "accountManagerButton"
                text: I18n.t("账户管理")
                onClicked: accountManager.open()
            }
        }

        CarText {
            Layout.fillWidth: true
            visible: !sessionManager.isAdmin
            text: I18n.t("需要管理员权限")
            color: Theme.warning
            fontPixelSize: Theme.fontLabel
        }

        // ---- 用户列表：一行一个账户（头像 + 名字 + 角色 + 删除），
        // 参考 Windows「其他用户」与 Android 的账户列表。----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: userRows.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.outlineVariant

            Column {
                id: userRows
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)

                Repeater {
                    model: page.users
                    delegate: Item {
                        id: userRow
                        required property var modelData
                        required property int index
                        width: userRows.width
                        height: Math.max(72 * Theme.scaleFactor, rowContent.implicitHeight + Theme.gap)

                        RowLayout {
                            id: rowContent
                            anchors.left: parent.left
                            anchors.right: rowDelete.left
                            anchors.rightMargin: Theme.gap / 2
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap

                            Avatar {
                                Layout.preferredWidth: 44 * Theme.scaleFactor
                                Layout.preferredHeight: 44 * Theme.scaleFactor
                                size: 44 * Theme.scaleFactor
                                displayName: userRow.modelData.displayName
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.gap / 2
                                    CarText {
                                        Layout.fillWidth: true
                                        text: userRow.modelData.displayName
                                        fontPixelSize: Theme.fontStrong
                                        color: Theme.foreground
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                    Rectangle {
                                        Layout.preferredHeight: 24 * Theme.scaleFactor
                                        Layout.preferredWidth: roleLabel.implicitWidth + Theme.gap
                                        radius: Theme.shapeFull
                                        color: userRow.modelData.admin ? Theme.primaryContainer : Theme.surfaceContainerHigh
                                        border.width: 1
                                        border.color: userRow.modelData.admin ? Theme.accent : Theme.outlineVariant
                                        CarText {
                                            id: roleLabel
                                            anchors.centerIn: parent
                                            text: userRow.modelData.admin ? I18n.t("管理员") : I18n.t("普通用户")
                                            fontPixelSize: Theme.fontCaption
                                            color: Theme.foreground
                                        }
                                    }
                                    CarText {
                                        visible: userRow.modelData.userId === sessionManager.activeUserId
                                        text: I18n.t("（你）")
                                        fontPixelSize: Theme.fontCaption
                                        color: Theme.outline
                                    }
                                }
                                CarText {
                                    Layout.fillWidth: true
                                    text: userRow.modelData.disabled ? I18n.t("已停用") : I18n.t("可以登录这台终端")
                                    fontPixelSize: Theme.fontCaption
                                    color: Theme.outline
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                        }

                        IconButton {
                            id: rowDelete
                            objectName: "deleteUserRow"
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: sessionManager.isAdmin
                                     && userRow.modelData.userId !== sessionManager.activeUserId
                            iconName: "delete"
                            label: I18n.t("删除账户")
                            onClicked: page.openAdminDelete(userRow.modelData)
                        }

                        Rectangle {
                            visible: userRow.index < page.users.length - 1
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: Theme.outlineVariant
                        }
                    }
                }

                CarText {
                    width: userRows.width
                    visible: page.users.length === 0
                    text: I18n.t("还没有用户")
                    subdued: true
                }
            }
        }

        // ---- 添加用户：默认收起，点按钮展开（Android 的「添加用户」）。----
        CarButton {
            objectName: "addUserButton"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            visible: sessionManager.isAdmin
            text: page.addUserOpen ? I18n.t("取消添加") : I18n.t("添加用户")
            accent: !page.addUserOpen
            onClicked: {
                page.addUserOpen = !page.addUserOpen
                if (!page.addUserOpen) {
                    newUserName.text = ""
                    newUserPin.text = ""
                    newUserAdmin.checked = false
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            visible: sessionManager.isAdmin && page.addUserOpen
            implicitHeight: addUserColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.outlineVariant

            ColumnLayout {
                id: addUserColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: newUserName
                    objectName: "newUserName"
                    Layout.fillWidth: true
                    placeholderText: I18n.t("显示名")
                }
                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: newUserPin
                    objectName: "newUserPin"
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: I18n.t("初始 PIN（至少 6 位数字）")
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    CarText { Layout.fillWidth: true; text: I18n.t("设为管理员"); color: Theme.foreground; fontPixelSize: Theme.body }
                    Switch { id: newUserAdmin; objectName: "newUserAdmin"; implicitHeight: Theme.hit }
                }
                CarButton {
                    objectName: "createUserButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    text: I18n.t("创建")
                    accent: true
                    onClicked: page.createUser()
                }
            }
        }

        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAllSections || page.section === 1
            spacing: Theme.gap

        // ---- 改自己的 PIN ----
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.loggedIn
            text: I18n.t("修改我的 PIN")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
        }
        CarField { plainHint: true
            onKeyboardRequested: page.keyboardRequested()
            id: oldPin
            Layout.fillWidth: true
            visible: sessionManager.loggedIn
            echoMode: TextInput.Password
            placeholderText: I18n.t("当前 PIN")
        }
        CarField { plainHint: true
            onKeyboardRequested: page.keyboardRequested()
            id: newPin
            Layout.fillWidth: true
            visible: sessionManager.loggedIn
            echoMode: TextInput.Password
            placeholderText: I18n.t("新 PIN（至少 6 位数字）")
        }
        CarButton {
            objectName: "changePinButton"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            visible: sessionManager.loggedIn
            text: I18n.t("保存新 PIN")
            onClicked: page.changePin()
        }
        // 忘记旧 PIN 时的自救路径：恢复码验证通过后重设 PIN，不需要旧 PIN。
        // 恢复码不轮换——它封装的是同一个 DB key，用户手里那份继续有效。
        CarButton {
            objectName: "resetPinWithCodeButton"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.hit
            visible: sessionManager.loggedIn
            text: I18n.t("忘记 PIN？用恢复码重置")
            buttonColor: "transparent"
            onClicked: {
                page.resetPinError = ""
                resetCode.text = ""
                resetNewPin.text = ""
                resetNewPin2.text = ""
                resetPinDialog.open()
            }
        }

        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAllSections || page.section === 0
            spacing: Theme.gap

        // 当前用户摘要（Windows/GNOME 账户页的首块）
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap
            Avatar {
                Layout.preferredWidth: 72 * Theme.scaleFactor
                Layout.preferredHeight: 72 * Theme.scaleFactor
                size: 72 * Theme.scaleFactor
                source: sessionManager.ownAvatarSource
                displayName: sessionManager.activeDisplayName
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    CarText { Layout.fillWidth: true; text: sessionManager.activeDisplayName; fontPixelSize: Theme.fontStrong; color: Theme.foreground; elide: Text.ElideRight }
                    IconButton {
                        objectName: "renameOwnAccount"
                        iconName: "build"
                        label: I18n.t("更改名字")
                        onClicked: {
                            renameField.text = sessionManager.activeDisplayName
                            renameError.text = ""
                            renameDialog.open()
                        }
                    }
                }
                CarText { Layout.fillWidth: true; text: sessionManager.isAdmin ? I18n.t("管理员") : I18n.t("普通用户"); fontPixelSize: Theme.fontCaption; color: Theme.outline }
            }
        }

        // ---- 头像：只能改自己的；图片由服务端裁圆并落到注册表同目录 ----
        CarText {
            Layout.fillWidth: true
            visible: sessionManager.loggedIn
            text: I18n.t("头像")
            fontPixelSize: Theme.fontLabel
            color: Theme.outline
        }
        RowLayout {
            Layout.fillWidth: true
            visible: sessionManager.loggedIn
            spacing: Theme.gap
            Avatar {
                Layout.preferredWidth: 56 * Theme.scaleFactor
                Layout.preferredHeight: 56 * Theme.scaleFactor
                size: 56 * Theme.scaleFactor
                source: sessionManager.ownAvatarSource
                displayName: sessionManager.activeDisplayName
            }
            Flow {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    objectName: "changeAvatarButton"
                    text: I18n.t("更换头像")
                    onClicked: {
                        page.avatarFolder = ""
                        page.message = ""
                        avatarPicker.open()
                    }
                }
                CarButton {
                    objectName: "removeAvatarButton"
                    text: I18n.t("移除头像")
                    visible: sessionManager.ownAvatarSource !== ""
                    onClicked: {
                        if (sessionManager.removeOwnAvatar()) page.message = I18n.t("头像已移除")
                    }
                }
            }
        }

        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAllSections || page.section === 3
            spacing: Theme.gap

        // ---- 导出：一张卡片一件事（Windows「备份」/ Android「存储」的信息层级）----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: exportColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.outlineVariant

            ColumnLayout {
                id: exportColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    MaterialIcon { Layout.preferredWidth: Theme.icon; Layout.preferredHeight: Theme.icon; name: "download"; light: true }
                    CarText { Layout.fillWidth: true; text: I18n.t("导出数据库"); fontPixelSize: Theme.fontStrong; color: Theme.foreground }
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("导出一份加密副本，包含本用户的全部数据。")
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }
                UsbDevicePicker {
                    objectName: "exportDevicePicker"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    devices: page.usbDevices
                    storage: (typeof systemTools !== "undefined" && systemTools) ? systemTools : null
                    selectedId: page.exportUsbId
                    writableOnly: true
                    caption: I18n.t("导出到")
                    onPicked: function(id) { page.exportUsbId = id }
                }
                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: exportPassword
                    objectName: "exportPassword"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    echoMode: TextInput.Password
                    placeholderText: I18n.t("导出密码（至少 8 位）")
                }
                CarButton {
                    objectName: "exportDatabaseButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    visible: sessionManager.loggedIn
                    enabled: page.exportUsbId !== ""
                    text: I18n.t("导出数据库")
                    accent: true
                    onClicked: page.exportDatabase()
                }
            }
        }

        // ---- 备份与恢复：同一张卡片里两条独立流程，中间一条发丝线 ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: backupColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.outlineVariant

            ColumnLayout {
                id: backupColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    MaterialIcon { Layout.preferredWidth: Theme.icon; Layout.preferredHeight: Theme.icon; name: "save"; light: true }
                    CarText { Layout.fillWidth: true; text: I18n.t("备份与恢复"); fontPixelSize: Theme.fontStrong; color: Theme.foreground }
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("备份是加密文件；恢复会用备份里的数据覆盖当前账户。")
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }

                CarText { Layout.fillWidth: true; text: I18n.t("创建备份"); fontPixelSize: Theme.fontLabel; color: Theme.outline }
                UsbDevicePicker {
                    objectName: "backupDevicePicker"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    devices: page.usbDevices
                    storage: (typeof systemTools !== "undefined" && systemTools) ? systemTools : null
                    selectedId: page.backupUsbId
                    writableOnly: true
                    caption: I18n.t("备份到")
                    onPicked: function(id) { page.backupUsbId = id }
                }
                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: backupPassword
                    objectName: "backupPassword"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    echoMode: TextInput.Password
                    placeholderText: I18n.t("备份密码（至少 8 位）")
                }
                CarButton {
                    objectName: "createBackupButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    visible: sessionManager.loggedIn
                    enabled: page.backupUsbId !== ""
                    text: I18n.t("备份当前用户")
                    onClicked: page.createBackup()
                }

                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }

                CarText { Layout.fillWidth: true; text: I18n.t("从备份恢复"); fontPixelSize: Theme.fontLabel; color: Theme.outline }
                UsbDevicePicker {
                    objectName: "restoreDevicePicker"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    devices: page.usbDevices
                    storage: (typeof systemTools !== "undefined" && systemTools) ? systemTools : null
                    selectedId: page.restoreUsbId
                    writableOnly: false
                    caption: I18n.t("从")
                    onPicked: function(id) {
                        page.restoreUsbId = id
                        page.restoreFileLocation = ""
                        page.restoreFiles = (typeof systemTools !== "undefined" && systemTools)
                                            ? systemTools.removableBackups(id) : []
                    }
                }
                CarText {
                    Layout.fillWidth: true
                    visible: page.restoreUsbId !== ""
                    text: I18n.t("这个 U 盘上的备份")
                    fontPixelSize: Theme.fontLabel
                    color: Theme.outline
                }
                CarText {
                    Layout.fillWidth: true
                    visible: page.restoreUsbId !== "" && page.restoreFiles.length === 0
                    text: I18n.t("这个 U 盘上没有备份文件")
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }
                Column {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    Repeater {
                        model: page.restoreFiles
                        delegate: Rectangle {
                            id: backupRow
                            required property var modelData
                            readonly property bool picked: page.restoreFileLocation === modelData.location
                            width: parent.width
                            height: 56 * Theme.scaleFactor
                            radius: Theme.shapeMedium
                            color: picked ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                            border.width: 1
                            border.color: picked ? Theme.accent : Theme.outlineVariant
                            CarText {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: Theme.gap
                                anchors.rightMargin: Theme.gap
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.backupLabel(modelData.modifiedMs)
                                fontPixelSize: Theme.fontLabel
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: page.restoreFileLocation = backupRow.modelData.location
                            }
                        }
                    }
                }
                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: restorePassword
                    objectName: "restorePassword"
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    echoMode: TextInput.Password
                    placeholderText: I18n.t("备份密码")
                }
                CarButton {
                    objectName: "restoreBackupButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    visible: sessionManager.loggedIn
                    enabled: page.restoreFileLocation !== ""
                    text: I18n.t("从备份恢复")
                    onClicked: page.requestRestore()
                }
            }
        }

        // ---- 清空本用户数据：危险卡片，红色描边 ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: purgeColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.danger

            ColumnLayout {
                id: purgeColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    MaterialIcon { Layout.preferredWidth: Theme.icon; Layout.preferredHeight: Theme.icon; name: "delete"; light: true }
                    CarText { Layout.fillWidth: true; text: I18n.t("清空本用户数据"); fontPixelSize: Theme.fontStrong; color: Theme.danger }
                }
                CarText {
                    Layout.fillWidth: true
                    visible: sessionManager.isAdmin
                    text: I18n.t("删除全部历史与读数，账户和密钥保留。不可撤销。")
                    color: Theme.warning
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }
                CarField { plainHint: true
                    onKeyboardRequested: page.keyboardRequested()
                    id: purgePin
                    objectName: "purgePin"
                    Layout.fillWidth: true
                    visible: sessionManager.isAdmin
                    echoMode: TextInput.Password
                    placeholderText: I18n.t("输入当前 PIN 以确认")
                }
                CarButton {
                    objectName: "purgeDataButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    visible: sessionManager.isAdmin
                    text: I18n.t("清空本用户数据")
                    onClicked: page.requestPurge()
                }
            }
        }

        }

        // ---- 手工读数（暂时不做）----
        // 血压计界面保留在项目内，当前版本不开放。readings 表、ModuleDataApi 的
        // 写入/查询接口、I18n 词条都还在，只是入口收起。恢复方法：把下面
        // visible 改成 true，并确认 SecurityService 的 readings 接口仍存在。
        ColumnLayout {
            Layout.fillWidth: true
            visible: false      // ← 暂时不做
            spacing: Theme.gap
            // ---- 手工读数 ----
            CarText {
                Layout.fillWidth: true
                visible: sessionManager.loggedIn
                text: I18n.t("手工录入与最近读数")
                fontPixelSize: Theme.title
                color: Theme.foreground
            }
            CarText {
                Layout.fillWidth: true
                visible: sessionManager.loggedIn
                text: I18n.t("手工录入记为 user.entry，与设备读数分开；数值范围 0–400。")
                color: Theme.outline
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            CarField { plainHint: true
                onKeyboardRequested: page.keyboardRequested()
                id: readingValue
                objectName: "readingValue"
                Layout.fillWidth: true
                visible: sessionManager.loggedIn
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                placeholderText: I18n.t("数值（0–400）")
            }
            RowLayout {
                Layout.fillWidth: true
                visible: sessionManager.loggedIn
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("单位")
                    color: Theme.foreground
                    fontPixelSize: Theme.body
                }
                CarButton {
                    objectName: "readingUnitMmHg"
                    text: "mmHg"
                    checked: page.readingUnit === "mmHg"
                    onClicked: page.readingUnit = "mmHg"
                }
                CarButton {
                    objectName: "readingUnitKPa"
                    text: "kPa"
                    checked: page.readingUnit === "kPa"
                    onClicked: page.readingUnit = "kPa"
                }
            }
            CarField { plainHint: true
                onKeyboardRequested: page.keyboardRequested()
                id: readingDevice
                objectName: "readingDevice"
                Layout.fillWidth: true
                visible: sessionManager.loggedIn
                placeholderText: I18n.t("设备型号（可选）")
                text: I18n.t("手动录入")
            }
            CarButton {
                objectName: "addReadingButton"
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.hit
                visible: sessionManager.loggedIn
                text: I18n.t("保存读数")
                accent: true
                onClicked: page.addReading()
            }

            CarText {
                Layout.fillWidth: true
                visible: sessionManager.loggedIn && page.readingRows.length === 0
                text: I18n.t("还没有读数")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
            }
            Repeater {
                model: page.readingRows
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.minimumHeight: Theme.hit
                    spacing: Theme.gap / 2
                    CarText {
                        Layout.preferredWidth: 150 * Theme.scaleFactor
                        text: Qt.formatDateTime(new Date(modelData.receivedAtMs), "MM-dd HH:mm")
                        color: Theme.outline
                        fontPixelSize: Theme.fontCaption
                    }
                    CarText {
                        Layout.fillWidth: true
                        text: (modelData.hasValue ? String(modelData.value) : I18n.t("无值"))
                              + " " + (modelData.unit || "")
                        color: Theme.foreground
                        fontPixelSize: Theme.body
                        elide: Text.ElideRight
                    }
                    CarText {
                        Layout.preferredWidth: 120 * Theme.scaleFactor
                        text: modelData.source === "user.entry" ? I18n.t("手动录入") : I18n.t("设备")
                        color: Theme.outline
                        fontPixelSize: Theme.fontCaption
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
            CarButton {
                objectName: "refreshReadingsButton"
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.hit
                visible: sessionManager.loggedIn
                text: I18n.t("刷新读数")
                onClicked: page.refreshReadings()
            }

        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAllSections || page.section === 4
            spacing: Theme.gap

        // 安全状态只读区：信任库/本机身份/UID key/槽位。
        SecurityStatusSection {
            Layout.fillWidth: true
        }

        // ---- 危险操作：删除账户（Windows / Android 的「删除账户」都在最后一张红卡里）----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: deleteAccountColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.danger

            ColumnLayout {
                id: deleteAccountColumn
                x: Theme.gap
                y: Theme.gap
                width: Math.max(240, parent.width - Theme.gap * 2)
                spacing: Theme.gap / 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    MaterialIcon { Layout.preferredWidth: Theme.icon; Layout.preferredHeight: Theme.icon; name: "delete"; light: true }
                    CarText { Layout.fillWidth: true; text: I18n.t("删除账户"); fontPixelSize: Theme.fontStrong; color: Theme.danger }
                }
                CarText {
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn
                    text: I18n.t("账户删除后无法恢复。")
                    color: Theme.outline
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }
                CarText {
                    Layout.fillWidth: true
                    visible: sessionManager.loggedIn && page.lastAdmin
                    text: I18n.t("你是最后一名管理员。删除后这台终端会回到首次开机向导，需要重新创建管理员并保存新的恢复码。")
                    color: Theme.warning
                    fontPixelSize: Theme.fontLabel
                    wrapMode: Text.Wrap
                }
                CarButton {
                    objectName: "deleteOwnAccountButton"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.hit
                    visible: sessionManager.loggedIn
                    enabled: page.canDeleteOwnAccount
                    opacity: enabled ? 1.0 : 0.55
                    text: I18n.t("删除我的账户")
                    buttonColor: enabled ? Theme.dangerContainer : Theme.disabledSurface
                    onClicked: selfDeleteDialog.open()
                }
            }
        }
        }
    }

    Component.onCompleted: {
        refreshReadings()
        refreshSecurityStatus()
    }

    function identityStateText() {
        if (identityState === "ready") return I18n.t("正常")
        if (identityState === "missing") return I18n.t("未生成")
        if (identityState === "corrupt") return I18n.t("已损坏")
        return I18n.t("不可用")
    }

    function refreshReadings() {
        if (!hasSecurityService) {
            readingRows = []
            return
        }
        readingRows = securityService.readings(10)
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

    function deleteErrorText(code) {
        switch (code) {
        case "AUTH_FAILED": return I18n.t("PIN 不正确")
        case "BUSY": return I18n.t("请先结束正在进行的任务")
        case "LAST_ADMIN": return I18n.t("至少保留一个管理员")
        case "NOT_AUTHORIZED": return I18n.t("没有权限")
        case "NOT_FOUND": return I18n.t("账户不存在或已停用")
        case "NAME_MISMATCH": return I18n.t("显示名不匹配")
        case "STORAGE_UNAVAILABLE": return I18n.t("删除失败")
        default: return I18n.t("操作失败")
        }
    }

    function openAdminDelete(user) {
        page.adminTargetId = user.userId
        page.adminTargetDisplayName = user.displayName
        accountManager.close()
        adminDeleteDialog.open()
    }

    // 第一段：只验 PIN。验过才开二次确认，PIN 错就地报错，不让人先点两层再失败。
    function confirmOwnDelete() {
        if (!sessionManager.verifyPin(selfDeletePin.text)) {
            selfDeleteError.text = page.deleteErrorText("AUTH_FAILED")
            return
        }
        selfDeleteError.text = ""
        page.pendingDeleteIsSelf = true
        page.pendingDeleteName = sessionManager.activeDisplayName
        deleteConfirm.open()
    }

    function confirmAdminDelete() {
        if (!sessionManager.verifyPin(adminPin.text)) {
            adminDeleteError.text = page.deleteErrorText("AUTH_FAILED")
            return
        }
        adminDeleteError.text = ""
        page.pendingDeleteIsSelf = false
        page.pendingDeleteName = page.adminTargetDisplayName
        deleteConfirm.open()
    }

    // 第二段：确认弹窗点头之后才真正删。
    function executeDelete() {
        deleteConfirm.close()
        if (page.pendingDeleteIsSelf) {
            const wasLastAdmin = page.lastAdmin
            const code = sessionManager.deleteOwnAccount(selfDeletePin.text)
            if (code === "") {
                // 账户已删；注册表为空时宿主拉起首次开机向导，但会先过等待层。
                page.keyboardDismissed()
                selfDeletePin.text = ""
                selfDeleteDialog.close()
                page.accountDeleted(wasLastAdmin)
                return
            }
            selfDeleteError.text = page.deleteErrorText(code)
            return
        }
        const removedName = page.adminTargetDisplayName
        const code = sessionManager.deleteUser(adminPin.text, page.adminTargetId,
                                               adminConfirmName.text)
        if (code === "") {
            adminDeleteDialog.close()
            page.adminTargetId = ""
            page.adminTargetDisplayName = ""
            page.message = I18n.t("已删除账户 ") + removedName
            page.accountDeleted(false)
            return
        }
        adminDeleteError.text = page.deleteErrorText(code)
    }

    function createUser() {
        const name = newUserName.text.trim()
        if (name.length === 0) { message = I18n.t("请填写显示名"); return }
        const out = sessionManager.createUser(name, newUserPin.text, newUserAdmin.checked)
        if (!out || !out.userId) {
            message = sessionManager.message || I18n.t("创建失败")
            return
        }
        message = ""
        recoveryCode = out.recoveryCode || ""
        newUserName.text = ""
        newUserPin.text = ""
        newUserAdmin.checked = false
        if (recoveryCode.length > 0) recoveryDialog.open()
    }

    // 改自己的显示名：名字不参与鉴权，后端只改注册表字段。
    function submitRename() {
        const name = renameField.text.trim()
        if (name.length < 2) { renameError.text = I18n.t("名字至少需要 2 个字符"); return }
        const code = sessionManager.changeOwnDisplayName(name)
        if (code !== "") {
            renameError.text = code === "NAME_INVALID"
                    ? I18n.t("名字需要 2–24 个字符")
                    : I18n.t("保存失败，请重试")
            return
        }
        renameError.text = ""
        page.keyboardDismissed()
        renameDialog.close()
        page.message = I18n.t("名字已更新")
    }

    function changePin() {
        if (!sessionManager.changeOwnPin(oldPin.text, newPin.text)) {
            message = I18n.t("PIN 不正确或新 PIN 不合规")
            return
        }
        message = I18n.t("PIN 已更新")
        oldPin.text = ""
        newPin.text = ""
    }

    // 已登录时用恢复码重设自己的 PIN。服务端负责验证恢复码、限速与锁定；
    // 这里只做两次输入与长度校验，错误统一成一句，避免探测。
    function submitRecoveryReset() {
        page.resetPinError = ""
        if (resetNewPin.text !== resetNewPin2.text) {
            page.resetPinError = I18n.t("两次 PIN 不一致")
            return
        }
        if (resetNewPin.text.length < 6) {
            page.resetPinError = I18n.t("PIN 至少 6 位数字")
            return
        }
        if (!sessionManager.changeOwnPinWithRecoveryCode(resetCode.text, resetNewPin.text)) {
            page.resetPinError = I18n.t("恢复码或 PIN 不正确，请重试")
            return
        }
        message = I18n.t("PIN 已更新")
        resetCode.text = ""
        resetNewPin.text = ""
        resetNewPin2.text = ""
        resetPinDialog.close()
    }

    // U 盘上的真实文件名只在这里出现，界面只显示盘名与「备份 日期 时间」。
    function usbTimestamp() {
        const d = new Date()
        const p2 = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate())
             + "-" + p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds())
    }

    function usbFilePath(deviceId, fileName) {
        if (deviceId === "" || typeof systemTools === "undefined" || !systemTools) return ""
        return systemTools.resolveRemovablePath("@usb/" + deviceId + "/" + fileName, true)
    }

    function backupLabel(ms) {
        const d = new Date(ms)
        const p2 = n => (n < 10 ? "0" : "") + n
        return I18n.t("备份 ") + d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate())
             + " " + p2(d.getHours()) + ":" + p2(d.getMinutes())
    }

    function exportDatabase() {
        // 先查用户已经填的密码，再查盘：密码短更容易理解成「我这条没填对」。
        const pw = exportPassword.text
        if (pw.length < 8) { message = I18n.t("导出密码至少 8 位"); return }
        if (page.exportUsbId === "") { message = I18n.t("请先选择 U 盘"); return }
        const path = page.usbFilePath(page.exportUsbId, "terminal-export-" + page.usbTimestamp() + ".enc")
        if (path === "") { message = I18n.t("U 盘不可写或已拔出"); return }
        if (!securityService.exportEncrypted(path, pw)) {
            message = securityService.lastMessage || I18n.t("导出失败")
            return
        }
        message = I18n.t("已导出到 U 盘")
        exportPassword.text = ""
    }

    function createBackup() {
        const pw = backupPassword.text
        if (pw.length < 8) { message = I18n.t("备份密码至少 8 位"); return }
        if (page.backupUsbId === "") { message = I18n.t("请先选择 U 盘"); return }
        const path = page.usbFilePath(page.backupUsbId, "terminal-backup-" + page.usbTimestamp() + ".optbk")
        if (path === "") { message = I18n.t("U 盘不可写或已拔出"); return }
        if (!securityService.createBackup(path, pw)) {
            message = securityService.lastMessage || I18n.t("备份失败")
            return
        }
        message = I18n.t("已备份到 U 盘")
        backupPassword.text = ""
        // 刚写的备份很可能就是要恢复的那一份，顺手刷新列表。
        if (page.restoreUsbId === page.backupUsbId
                && typeof systemTools !== "undefined" && systemTools)
            page.restoreFiles = systemTools.removableBackups(page.backupUsbId)
    }

    function requestRestore() {
        const pw = restorePassword.text
        if (pw.length < 8) { message = I18n.t("备份密码至少 8 位"); return }
        if (page.restoreFileLocation === "") { message = I18n.t("请先选择备份文件"); return }
        const path = (typeof systemTools !== "undefined" && systemTools)
                     ? systemTools.resolveRemovablePath(page.restoreFileLocation, false) : ""
        if (path === "") { message = I18n.t("U 盘已拔出或备份文件不存在"); return }
        pendingRestorePath = path
        pendingRestorePassword = pw
        restoreConfirm.open()
    }

    function confirmRestore() {
        const ok = securityService.restoreBackup(pendingRestorePath, pendingRestorePassword)
        message = ok ? I18n.t("已从备份恢复")
                     : (securityService.lastMessage || I18n.t("恢复失败"))
        pendingRestorePassword = ""
        restorePassword.text = ""
        restoreConfirm.close()
        if (ok) refreshReadings()
    }

    function requestPurge() {
        if (purgePin.text.length === 0) { message = I18n.t("请输入当前 PIN"); return }
        purgeConfirm.open()
    }

    function confirmPurge() {
        if (!sessionManager.verifyPin(purgePin.text)) {
            message = I18n.t("PIN 不正确")
            purgeConfirm.close()
            return
        }
        const ok = securityService.purgeOwnData()
        message = ok ? I18n.t("已清空本用户数据")
                     : (securityService.lastMessage || I18n.t("清空失败"))
        purgePin.text = ""
        purgeConfirm.close()
        if (ok) refreshReadings()
    }

    function addReading() {
        const value = Number(readingValue.text)
        if (!isFinite(value) || value <= 0 || value > 400) {
            message = I18n.t("数值需在 0–400 之间")
            return
        }
        const model = readingDevice.text.trim().length > 0 ? readingDevice.text.trim()
                                                           : I18n.t("手动录入")
        if (!securityService.addManualReading(value, readingUnit, model)) {
            message = securityService.lastMessage || I18n.t("保存失败")
            return
        }
        message = I18n.t("已记录 ") + value + " " + readingUnit
        readingValue.text = ""
        refreshReadings()
    }

    // ---- 头像选择：复用文件管理器的同一份目录数据，不改文件管理器本身 ----
    function avatarEntries() {
        const rows = systemTools.files(page.avatarFolder).filter(function(entry) {
            return entry.directory || /\.(png|jpe?g|webp|bmp)$/i.test(entry.name)
        })
        rows.sort(function(a, b) {
            if (a.directory !== b.directory) return a.directory ? -1 : 1
            return a.name.localeCompare(b.name)
        })
        return rows
    }

    function avatarRelative(entry) {
        return (page.avatarFolder ? page.avatarFolder + "/" : "") + entry.name
    }

    function chooseAvatarEntry(entry) {
        if (entry.directory) {
            page.avatarFolder = page.avatarRelative(entry)
            return
        }
        const code = sessionManager.setOwnAvatar(systemTools.fileDisplayPath(page.avatarRelative(entry)))
        if (code !== "") {
            switch (code) {
            case "INVALID_IMAGE": page.message = I18n.t("图片无法读取"); break
            case "NOT_AUTHORIZED": page.message = I18n.t("没有权限"); break
            default: page.message = I18n.t("保存失败"); break
            }
            return
        }
        page.message = I18n.t("头像已更新")
        avatarPicker.close()
    }

    // 恢复码只显示这一次；必须核对第 2、5 组才能关闭（与首次开机向导一致）。
    Popup {
        id: recoveryDialog
        objectName: "recoveryCodeDialog"
        parent: Overlay.overlay
        // 顶部对齐：作者的软键盘从 y≈256 弹出，居中会把第 2/5 组输入框压住。
        x: (parent ? parent.width - width : 0) / 2
        y: 6
        modal: true; dim: true
        closePolicy: Popup.NoAutoClose
        onClosed: page.keyboardDismissed()
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(640 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle { radius: Theme.shapeLarge; color: Theme.surface; border.color: Theme.outline; border.width: 1 }
        // 打开时才创建内容：未打开时 Overlay 宽度可能是 0，里面那行
        // 「第 2 组 / 第 5 组 / 按钮」的最小宽度放不下，会让 Popup 的
        // implicitHeight 反复算（Binding loop detected）。
        // 软键盘从 y≈256 弹出，内容一高底部按钮就被顶出屏幕（「我已抄写」点不到）。
        // 限高 + 可滚动：多出来的部分自己滚，输入框和按钮始终够得着。
        height: recoveryContent.height + topPadding + bottomPadding
        contentItem: Loader {
            id: recoveryContent
            width: recoveryDialog.availableWidth
            height: Math.min(implicitHeight, Math.max(200, (parent ? parent.height : 600) - Theme.gap * 8))
            active: recoveryDialog.opened
            sourceComponent: Component {
        Flickable {
            id: recoveryScroll
            implicitHeight: recoveryInner.implicitHeight
            contentWidth: width
            contentHeight: recoveryInner.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
        ColumnLayout {
            id: recoveryInner
            width: recoveryScroll.width
            spacing: Theme.gap / 2
            CarText { Layout.fillWidth: true; text: I18n.t("恢复码（只显示一次）"); fontPixelSize: Theme.fontLabel; color: Theme.warning }
            Grid {
                columns: 3
                rowSpacing: Theme.gap / 2
                columnSpacing: Theme.gap * 1.6
                Repeater {
                    model: 6
                    Text {
                        required property int index
                        text: page.recoveryGroups.length > index ? page.recoveryGroups[index] : ""
                        color: Theme.foreground
                        font.family: "monospace"
                        font.pointSize: 22 * Theme.scaleFactor
                        font.letterSpacing: 2
                    }
                }
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("没有恢复码，忘记 PIN 时数据无法恢复。请离线抄录，并核对第 2、5 组。")
                color: Theme.outline
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("确认前请先抄写或导出")
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                }
                CarButton {
                    objectName: "recoveryAck"
                    text: I18n.t("我已抄写")
                    accent: true
                    onClicked: recoveryAckConfirm.open()
                }
            }
            // 恢复码最容易丢，给一条直接落 U 盘的路径（截图/转述都不如原件）。
            RecoveryExport {
                Layout.fillWidth: true
                recoveryCode: page.recoveryCode
                userName: sessionManager.activeDisplayName
            }
                }
            }
            }
        }
    }

    // 「我已抄写」的二次确认：三处恢复码共用同一个组件（5 秒冷静期）。
    RecoveryAckConfirm {
        id: recoveryAckConfirm
        onAccepted: {
            page.recoveryCode = ""
            recoveryDialog.close()
        }
    }

    // 用恢复码重设自己的 PIN：不需要旧 PIN，恢复码验证后只重封装 DB key。
    Dialog {
        id: resetPinDialog
        objectName: "resetPinWithCodeDialog"
        parent: Overlay.overlay
        x: (parent ? parent.width - width : 0) / 2
        y: 0
        modal: true
        closePolicy: Popup.NoAutoClose
        onClosed: page.keyboardDismissed()
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap / 2
        width: Math.min(560 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        height: resetPinColumn.implicitHeight + topPadding + bottomPadding
        background: Rectangle { radius: Theme.shapeLarge; color: Theme.surface; border.color: Theme.warning; border.width: 1 }
        contentItem: ColumnLayout {
            id: resetPinColumn
            spacing: Theme.gap * 0.6
            CarText { Layout.fillWidth: true; text: I18n.t("用恢复码重置 PIN"); fontPixelSize: Theme.fontLabel; color: Theme.warning }
            CarField {
                id: resetCode
                Layout.fillWidth: true
                maximumLength: 29
                placeholderText: I18n.t("恢复码（24 个字符）")
                font.family: "monospace"
                onTextChanged: {
                    const filtered = text.toUpperCase()
                    if (filtered !== text) text = filtered
                }
                onKeyboardRequested: page.keyboardRequested()
            }
            CarField {
                id: resetNewPin
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("新 PIN（至少 6 位数字）")
                onKeyboardRequested: page.keyboardRequested()
            }
            CarField {
                id: resetNewPin2
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("再输一次新 PIN")
                onKeyboardRequested: page.keyboardRequested()
            }
            CarText {
                Layout.fillWidth: true
                visible: page.resetPinError.length > 0
                text: page.resetPinError
                color: Theme.danger
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                CarButton { text: I18n.t("取消"); onClicked: resetPinDialog.close() }
                CarButton {
                    objectName: "confirmResetPin"
                    text: I18n.t("重置 PIN")
                    accent: true
                    onClicked: page.submitRecoveryReset()
                }
            }
        }
    }

    Popup {
        id: restoreConfirm
        objectName: "restoreConfirmDialog"
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
        modal: true; dim: true
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(460 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle { radius: Theme.shapeLarge; color: Theme.surface; border.color: Theme.outline; border.width: 1 }
        contentItem: Loader {
            active: restoreConfirm.opened
            sourceComponent: Component {
                ColumnLayout {
            spacing: Theme.gap / 2
            CarText { Layout.fillWidth: true; text: I18n.t("确认从备份恢复？"); fontPixelSize: Theme.title; color: Theme.foreground }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("当前用户的数据会被备份内容覆盖，且不可撤销。")
                color: Theme.warning
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    objectName: "restoreCancel"
                    Layout.fillWidth: true
                    text: I18n.t("取消")
                    onClicked: { page.pendingRestorePassword = ""; restoreConfirm.close() }
                }
                CarButton {
                    objectName: "restoreConfirm"
                    Layout.fillWidth: true
                    text: I18n.t("确认恢复")
                    accent: true
                    onClicked: page.confirmRestore()
                }
            }
                }
            }
        }
    }

    // 删除账户的二次确认：PIN 已经验过，这里是最后一道门。
    Popup {
        id: deleteConfirm
        objectName: "deleteAccountConfirm"
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
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle {
            color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55)
        }
        padding: Theme.gap
        width: Math.min(460 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }
        contentItem: Loader {
            active: deleteConfirm.opened
            sourceComponent: Component {
                ColumnLayout {
                    spacing: Theme.gap / 2
                    CarText {
                        Layout.fillWidth: true
                        text: I18n.t("确认删除账户？")
                        fontPixelSize: Theme.title
                        color: Theme.foreground
                    }
                    CarText {
                        Layout.fillWidth: true
                        text: page.pendingDeleteName
                        fontPixelSize: Theme.fontStrong
                        color: Theme.foreground
                        wrapMode: Text.WordWrap
                    }
                    CarText {
                        Layout.fillWidth: true
                        text: I18n.t("账户及其绑定数据会被永久删除，无法恢复。")
                        color: Theme.warning
                        fontPixelSize: Theme.fontLabel
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.gap / 2
                        CarButton {
                            objectName: "deleteConfirmCancel"
                            Layout.fillWidth: true
                            text: I18n.t("取消")
                            onClicked: deleteConfirm.close()
                        }
                        CarButton {
                            objectName: "deleteConfirmAccept"
                            Layout.fillWidth: true
                            text: I18n.t("永久删除")
                            buttonColor: Theme.dangerContainer
                            onClicked: page.executeDelete()
                        }
                    }
                }
            }
        }
    }

    Popup {
        id: purgeConfirm
        objectName: "purgeConfirmDialog"
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
        modal: true; dim: true
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(460 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle { radius: Theme.shapeLarge; color: Theme.surface; border.color: Theme.outline; border.width: 1 }
        contentItem: Loader {
            active: purgeConfirm.opened
            sourceComponent: Component {
                ColumnLayout {
            spacing: Theme.gap / 2
            CarText { Layout.fillWidth: true; text: I18n.t("确认清空本用户数据？"); fontPixelSize: Theme.title; color: Theme.foreground }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("全部历史与读数会被删除，账户和密钥保留，操作不可撤销。")
                color: Theme.warning
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    objectName: "purgeCancel"
                    Layout.fillWidth: true
                    text: I18n.t("取消")
                    onClicked: purgeConfirm.close()
                }
                CarButton {
                    objectName: "purgeConfirm"
                    Layout.fillWidth: true
                    text: I18n.t("确认清空")
                    accent: true
                    onClicked: page.confirmPurge()
                }
            }
                }
            }
        }
    }

    Popup {
        id: avatarPicker
        objectName: "avatarPicker"
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
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(680 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        height: Math.min(540 * Theme.scaleFactor, (parent ? parent.height : 600) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.gap / 2

            RowLayout {
                Layout.fillWidth: true
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("选择头像")
                    fontPixelSize: Theme.title
                    color: Theme.foreground
                }
                IconButton {
                    iconName: "close"
                    label: I18n.t("关闭")
                    onClicked: avatarPicker.close()
                }
            }

            CarText {
                Layout.fillWidth: true
                text: systemTools.filesRoot + (page.avatarFolder ? "/" + page.avatarFolder : "")
                color: Theme.outline
                fontPixelSize: Theme.fontCaption
                elide: Text.ElideMiddle
                maximumLineCount: 1
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    text: I18n.t("主目录")
                    onClicked: page.avatarFolder = ""
                }
                CarButton {
                    text: I18n.t("上一级")
                    enabled: page.avatarFolder !== ""
                    onClicked: {
                        const cut = page.avatarFolder.lastIndexOf("/")
                        page.avatarFolder = cut > 0 ? page.avatarFolder.substring(0, cut) : ""
                    }
                }
                Item { Layout.fillWidth: true }
            }

            GridView {
                id: avatarGrid
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                cellWidth: 116 * Theme.scaleFactor
                cellHeight: 124 * Theme.scaleFactor
                model: page.avatarEntries()

                delegate: Item {
                    id: avatarCell
                    required property var modelData
                    width: avatarGrid.cellWidth
                    height: avatarGrid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4 * Theme.scaleFactor
                        radius: Theme.shapeMedium
                        color: avatarCellMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 8 * Theme.scaleFactor
                        spacing: 4 * Theme.scaleFactor

                        FileThumbnail {
                            width: 72 * Theme.scaleFactor
                            height: 72 * Theme.scaleFactor
                            anchors.horizontalCenter: parent.horizontalCenter
                            entry: avatarCell.modelData
                            relative: page.avatarRelative(avatarCell.modelData)
                            fallback: avatarCell.modelData.directory ? "folder" : "image"
                        }
                        CarText {
                            width: parent.width
                            text: avatarCell.modelData.name
                            color: Theme.foreground
                            fontPixelSize: Theme.fontCaption
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideMiddle
                            maximumLineCount: 1
                        }
                    }

                    MouseArea {
                        id: avatarCellMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.chooseAvatarEntry(avatarCell.modelData)
                    }
                }
            }

            CarText {
                Layout.fillWidth: true
                visible: avatarGrid.count === 0
                text: I18n.t("没有图片")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
            }

            RowLayout {
                Layout.fillWidth: true
                CarText {
                    Layout.fillWidth: true
                    text: page.message
                    color: Theme.warning
                    fontPixelSize: Theme.fontCaption
                    elide: Text.ElideRight
                }
                CarButton {
                    text: I18n.t("取消")
                    onClicked: avatarPicker.close()
                }
            }
        }
    }
    // ---- 本人删号：PIN + 红色警示 + 5 秒冷静期 ----
    Popup {
        id: selfDeleteDialog
        objectName: "deleteOwnAccountDialog"
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
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(560 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        property int cooldown: 5

        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.danger
            border.width: 2
        }

        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                text: I18n.t("永久删除我的账户？")
                fontPixelSize: Theme.title
                color: Theme.danger
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("此操作会永久删除：")
                color: Theme.foreground
                fontPixelSize: Theme.fontLabel
            }
            CarText {
                Layout.fillWidth: true
                text: "• " + I18n.t("加密数据库与全部读数") + "\n"
                      + "• " + I18n.t("头像与个人设置") + "\n"
                      + "• " + I18n.t("已绑定卡片与权限") + "\n"
                      + "• " + I18n.t("恢复码与登录锁定记录")
                color: Theme.danger
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("已导出的备份和 USB 备份不会被删除。")
                color: Theme.warning
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("账户删除后无法恢复。")
                color: Theme.danger
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                visible: page.lastAdmin
                text: I18n.t("这是终端上的最后一名管理员。删除完成后会直接进入首次开机向导，请在那里创建新的管理员。")
                color: Theme.warning
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            CarField {
                onKeyboardRequested: page.keyboardRequested()
                id: selfDeletePin
                objectName: "deleteOwnPin"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("输入当前 PIN")
                plainHint: true
                onAccepted: if (selfDeleteConfirm.enabled) page.confirmOwnDelete()
            }
            CarText {
                id: selfDeleteError
                Layout.fillWidth: true
                color: Theme.danger
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    text: selfDeleteDialog.cooldown > 0
                          ? I18n.t("冷静期") + " " + selfDeleteDialog.cooldown + " " + I18n.t("秒")
                          : I18n.t("确认后立即删除")
                    color: selfDeleteDialog.cooldown > 0 ? Theme.warning : Theme.danger
                    fontPixelSize: Theme.fontCaption
                }
                CarButton {
                    text: I18n.t("取消")
                    onClicked: selfDeleteDialog.close()
                }
                CarButton {
                    id: selfDeleteConfirm
                    objectName: "deleteOwnConfirm"
                    text: I18n.t("永久删除")
                    enabled: selfDeleteDialog.cooldown <= 0 && selfDeletePin.text.length > 0
                    buttonColor: enabled ? Theme.dangerContainer : Theme.disabledSurface
                    onClicked: page.confirmOwnDelete()
                }
            }
        }

        Timer {
            interval: 1000
            repeat: true
            running: selfDeleteDialog.opened && selfDeleteDialog.cooldown > 0
            onTriggered: selfDeleteDialog.cooldown--
        }
        onOpened: {
            selfDeleteDialog.cooldown = 5
            selfDeletePin.text = ""
            selfDeleteError.text = ""
        }
        // 上一级弹窗被关掉时，二次确认不能留在屏幕上。
        onClosed: deleteConfirm.close()
    }

    // ---- 管理员账户管理：二级页，只列启用账户，不含自己 ----
    Popup {
        id: accountManager
        objectName: "accountManagerDialog"
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
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(680 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        height: Math.min(560 * Theme.scaleFactor, (parent ? parent.height : 600) - Theme.gap * 4)

        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outline
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            RowLayout {
                Layout.fillWidth: true
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("账户管理")
                    fontPixelSize: Theme.title
                    color: Theme.foreground
                }
                IconButton {
                    iconName: "close"
                    label: I18n.t("关闭")
                    onClicked: accountManager.close()
                }
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("选择要删除的账户；不能删除自己。")
                color: Theme.outline
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }

            Flickable {
                id: accountListFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: accountList.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                Column {
                    id: accountList
                    width: accountListFlick.width
                    spacing: 2 * Theme.scaleFactor
                    Repeater {
                        // 弹层关闭后把模型清空：否则删除账户时（用户列表变化）
                        // 关闭中的 Repeater 也会重建，触发页面布局卡死。
                        model: accountManager.opened ? page.users.filter(function(user) {
                            return user.userId !== sessionManager.activeUserId
                        }) : []
                        delegate: Rectangle {
                            id: accountRow
                            required property var modelData
                            width: accountList.width
                            height: Math.max(Theme.hit, 56 * Theme.scaleFactor)
                            radius: Theme.shapeFull
                            color: "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.gap
                                anchors.rightMargin: Theme.gap
                                spacing: Theme.gap / 2
                                CarText {
                                    Layout.fillWidth: true
                                    text: modelData.displayName + (modelData.admin ? I18n.t("（管理员）") : "")
                                    color: Theme.foreground
                                    fontPixelSize: Theme.body
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                CarButton {
                                    text: I18n.t("删除账户")
                                    buttonColor: Theme.dangerContainer
                                    onClicked: page.openAdminDelete(accountRow.modelData)
                                }
                            }
                        }
                    }
                }
            }

            CarText {
                Layout.fillWidth: true
                visible: accountManager.opened && page.users.filter(function(user) {
                    return user.userId !== sessionManager.activeUserId
                }).length === 0
                text: I18n.t("没有其他账户")
                color: Theme.outline
                fontPixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
            }

            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                CarButton {
                    text: I18n.t("关闭")
                    onClicked: accountManager.close()
                }
            }
        }
    }

    // ---- 管理员删他人：PIN + 目标显示名 + 5 秒冷静期 ----
    Popup {
        id: adminDeleteDialog
        objectName: "adminDeleteUserDialog"
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
        closePolicy: Popup.NoAutoClose
        Overlay.modal: Rectangle { color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.55) }
        padding: Theme.gap
        width: Math.min(580 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        property int cooldown: 5

        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.danger
            border.width: 2
        }

        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                text: I18n.t("管理员删除账户")
                fontPixelSize: Theme.title
                color: Theme.danger
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("目标账户：") + page.adminTargetDisplayName
                color: Theme.danger
                fontPixelSize: Theme.fontStrong
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("此操作会永久删除：") + " "
                      + I18n.t("加密数据库与全部读数") + " / " + I18n.t("头像与个人设置") + " / "
                      + I18n.t("已绑定卡片与权限") + " / " + I18n.t("恢复码与登录锁定记录")
                color: Theme.foreground
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("已导出的备份和 USB 备份不会被删除。")
                color: Theme.warning
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.WordWrap
            }
            CarField {
                onKeyboardRequested: page.keyboardRequested()
                id: adminPin
                objectName: "deleteUserAdminPin"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: I18n.t("你的管理员 PIN")
                plainHint: true
            }
            CarField {
                onKeyboardRequested: page.keyboardRequested()
                id: adminConfirmName
                objectName: "deleteUserConfirmName"
                Layout.fillWidth: true
                placeholderText: I18n.t("输入目标显示名以确认")
                plainHint: true
                onAccepted: if (adminDeleteConfirm.enabled) page.confirmAdminDelete()
            }
            CarText {
                id: adminDeleteError
                Layout.fillWidth: true
                color: Theme.danger
                fontPixelSize: Theme.fontLabel
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    text: adminDeleteDialog.cooldown > 0
                          ? I18n.t("冷静期") + " " + adminDeleteDialog.cooldown + " " + I18n.t("秒")
                          : I18n.t("确认后立即删除")
                    color: adminDeleteDialog.cooldown > 0 ? Theme.warning : Theme.danger
                    fontPixelSize: Theme.fontCaption
                }
                CarButton {
                    text: I18n.t("取消")
                    onClicked: adminDeleteDialog.close()
                }
                CarButton {
                    id: adminDeleteConfirm
                    objectName: "adminDeleteConfirm"
                    text: I18n.t("永久删除")
                    enabled: adminDeleteDialog.cooldown <= 0 && adminPin.text.length > 0
                             && adminConfirmName.text.length > 0
                    buttonColor: enabled ? Theme.dangerContainer : Theme.disabledSurface
                    onClicked: page.confirmAdminDelete()
                }
            }
        }

        Timer {
            interval: 1000
            repeat: true
            running: adminDeleteDialog.opened && adminDeleteDialog.cooldown > 0
            onTriggered: adminDeleteDialog.cooldown--
        }
        onOpened: {
            adminDeleteDialog.cooldown = 5
            adminPin.text = ""
            adminConfirmName.text = ""
            adminDeleteError.text = ""
        }
        onClosed: deleteConfirm.close()
    }


    // ---- 更改名字（Windows / Android 的账户名编辑）----
    Popup {
        id: renameDialog
        objectName: "renameOwnAccountDialog"
        parent: Overlay.overlay
        // 顶部对齐而不是居中：软键盘从底部弹起时不会盖住输入框与保存按钮。
        x: parent ? (parent.width - width) / 2 : 0
        y: Theme.margin
        modal: true
        dim: true
        closePolicy: Popup.CloseOnEscape
        padding: Theme.gap
        width: Math.min(480 * Theme.scaleFactor, (parent ? parent.width : 800) - Theme.gap * 4)
        background: Rectangle {
            radius: Theme.shapeLarge
            color: Theme.surface
            border.width: 1
            border.color: Theme.outlineVariant
        }
        contentItem: ColumnLayout {
            spacing: Theme.gap / 2
            CarText { Layout.fillWidth: true; heading: true; text: I18n.t("更改名字") }
            CarText {
                Layout.fillWidth: true
                text: I18n.t("这个名字会显示在登录页、桌面与用户列表里。")
                subdued: true
                fontPixelSize: Theme.fontCaption
                wrapMode: Text.Wrap
            }
            CarField {
                id: renameField
                objectName: "renameField"
                Layout.fillWidth: true
                maximumLength: 24
                placeholderText: I18n.t("显示名（2–24 个字符）")
                onKeyboardRequested: page.keyboardRequested()
                onAccepted: page.submitRename()
            }
            CarText { id: renameError; Layout.fillWidth: true; color: Theme.danger; fontPixelSize: Theme.fontLabel; wrapMode: Text.Wrap }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                Item { Layout.fillWidth: true }
                CarButton { text: I18n.t("取消"); onClicked: { page.keyboardDismissed(); renameDialog.close() } }
                CarButton {
                    objectName: "renameOwnConfirm"
                    text: I18n.t("保存")
                    enabled: renameField.text.trim().length >= 2
                    onClicked: page.submitRename()
                }
            }
        }
    }
}
