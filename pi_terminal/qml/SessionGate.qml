import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts

// 登入门禁 + 锁屏遮罩 + 无交互自动锁（5 分钟）。
//
// 挂在 Overlay.overlay 最上层，z 高于启动动画。
// 未登录时挡住整个桌面；锁屏时挡住敏感内容但不停已授权任务。
//
// 所有判断取自 sessionManager（服务端状态），不看本地变量。
Item {
    id: gate
    anchors.fill: parent
    property var inputSource: null
    // --ui-test 无人值守审计没有登录步骤，门禁会挡住被审计的桌面。
    property bool enabledGate: typeof sessionGateBypassed !== "undefined" ? !sessionGateBypassed : true
    // 恢复码/改 PIN 输入需要宿主软键盘；Main.qml 把它接到 screenKeyboard。
    signal keyboardRequested()

    // 未登录 → 显示登录页；已登录但锁屏 → 显示锁屏。
    readonly property bool needLogin: gate.enabledGate && !sessionManager.loggedIn
    readonly property bool needUnlock: gate.enabledGate && sessionManager.loggedIn && sessionManager.locked
    readonly property bool blocking: needLogin || needUnlock

    visible: blocking
    // 挡住下层所有输入：未登录时桌面不可点。
    MouseArea {
        anchors.fill: parent
        enabled: gate.blocking
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.background
        opacity: 0.97
    }

    // ---- 无交互自动锁（每用户可设；0 表示永不）----
    // 任何输入都重置。只在已登录且未锁屏时计时。
    readonly property int autoLockSeconds: sessionManager.autoLockSeconds
    property int idleElapsed: 0

    Timer {
        id: idleTicker
        interval: 1000
        repeat: true
        running: gate.enabledGate && sessionManager.loggedIn && !sessionManager.locked
                 && gate.autoLockSeconds > 0
        onTriggered: {
            gate.idleElapsed += 1
            if (gate.autoLockSeconds > 0 && gate.idleElapsed >= gate.autoLockSeconds) {
                gate.idleElapsed = 0
                sessionManager.lockNow()
            }
        }
    }

    Connections {
        target: gate.inputSource
        function onActiveFocusItemChanged() { gate.idleElapsed = 0 }
    }

    // 用户刚改完锁屏时长，从这一刻重新计时；否则旧的 idleElapsed 可能让新值立刻触发。
    Connections {
        target: sessionManager
        function onLockTimeoutChanged() { gate.idleElapsed = 0 }
    }

    // 窗口级输入事件都会经过这里；用 TapHandler 覆盖全窗口不现实，
    // 因此改为监听根窗口的 signal（由 Main.qml 转发 clicked/keyed）。
    function noteInput() { gate.idleElapsed = 0 }

    // 有未完成任务时切用户会被服务端拒绝（login 返回 BUSY），
    // 这里给出可操作的出口，而不是让用户卡住。
    Loader {
        anchors.centerIn: gate
        width: Math.min(gate.width - Theme.margin * 2, 520 * Theme.scaleFactor)
        z: 10
        active: gate.needLogin && sessionManager.message === "BUSY"
        visible: active
        sourceComponent: TaskFinishDialog {
            tasks: gate.pendingTasks()
            message: gate.localizedMessage(sessionManager.message)
            onFinishTask: function(taskId) {
                sessionManager.finishTask(taskId)
                sessionManager.refreshUsers()
            }
            onCancelTask: function(taskId) {
                // 显式取消：标记 incomplete 后按正常收尾推进代次，迟到事件仍会被拒。
                sessionManager.cancelTaskAsIncomplete(taskId)
                sessionManager.refreshUsers()
            }
            onStopAll: function() {
                gate.stopAllTasks()
                sessionManager.refreshUsers()
            }
        }
    }

    function pendingTasks() {
        // SessionManager 不把 TaskCapability* 暴露给 QML；这里只给出可读标签。
        const list = []
        for (const task of sessionManager.pendingTaskSummaries())
            list.push({taskId: task.taskId, label: I18n.t("任务") + " " + task.deviceId})
        return list
    }

    function stopAllTasks() {
        for (const task of sessionManager.pendingTaskSummaries())
            sessionManager.finishTask(task.taskId)
    }

    // 报告 §5.1：刷卡只跳到该用户的 PIN 页，**不直接登录**。
    Connections {
        target: securityService
        function onCardUserSelected(userId) {
            if (gate.needLogin) {
                gate.preSelectedUserId = userId
                // 让登录页直接进入 PIN 输入状态（免去手动选人）。
                for (const user of sessionManager.users)
                    if (user.userId === userId) gate.preSelectedName = user.displayName
                // 同一张卡连续刷（例如进了 PIN 页又返回）也要重新预选：
                // preSelectedUserId 不变时 onXChanged 不会再触发，用序号强制一次。
                gate.cardSelectSeq += 1
                return
            }
            // 锁屏：只有卡主 = 当前用户才提示解锁，别人刷卡不切换账户。
            if (gate.locked) {
                if (userId === sessionManager.activeUserId) {
                    gate.cardNotice = I18n.t("已识别卡片，请输入 PIN 解锁")
                    gate.cardNoticeIsError = false
                } else {
                    gate.cardNotice = I18n.t("这张卡属于其他账户，请先退出当前账户")
                    gate.cardNoticeIsError = true
                }
            }
        }
    }
    property string preSelectedUserId: ""
    property string preSelectedName: ""
    property int cardSelectSeq: 0
    property string cardNotice: ""
    property bool cardNoticeIsError: false
    // KDF 在服务端同步执行，登录/解锁期间给它一个可见的 busy 标志。
    // 缺这一行会让下面 onPinSubmitted 里的 gate.verifying = true 抛
    // "Cannot assign to non-existent property"，整个处理函数被中断，
    // sessionManager.login() 根本不会执行 —— 登录点了没反应。
    property bool verifying: false
    // 点确认后先由界面拉起遮罩，等它真的画到屏幕上再开始 KDF。
    // 不直接用 sessionManager.unlocking：那个要等 login() 执行才变 true，
    // 而 login() 一进来就跑 PBKDF2，遮罩会来不及渲染（Pi 上就是一片静止画面）。
    property bool unlockingUi: false
    property string pendingPin: ""
    property string pendingUser: ""

    // 150ms ≈ 9 帧（60fps），足够让「正在解锁」这张卡片完整上屏。
    Timer {
        id: unlockStartDelay
        interval: 150
        repeat: false
        onTriggered: {
            const user = gate.pendingUser
            const pin = gate.pendingPin
            gate.pendingPin = ""
            gate.pendingUser = ""
            if (user === "") {
                // 异步：KDF 在子进程里算，主线程只画进度条；失败会自动回退同步。
                // 收尾（清 verifying/notice）统一由 onUnlockFinished 完成。
                sessionManager.unlockWithWorker(pin)
            } else {
                // 异步登录：结果经 loginFinished 回来，忙碌标记由该信号清除。
                const code = sessionManager.loginWithWorker(user, pin)
                if (!code) return
                gate.unlockingUi = false
                gate.verifying = false
                if (code === "") {
                    gate.idleElapsed = 0
                    gate.preSelectedUserId = ""
                    gate.preSelectedName = ""
                }
            }
        }
    }

    // ---- 登录 / 锁屏内容 ----
    // 登录页是全屏版式（ChromeOS 式居中头像 + 左下电源/右下更多）；
    // 锁屏页自带居中列，填满后仍保持视觉居中。
    Loader {
        anchors.fill: gate
        active: gate.blocking
        visible: active
        sourceComponent: gate.needLogin ? loginComponent : lockComponent
    }

    Component {
        id: loginComponent
        LoginPage {
            onKeyboardRequested: gate.keyboardRequested()
            users: sessionManager.users
            // 刷卡选中的用户优先：仍须输入 PIN 才登录。
            preSelectedUserId: gate.preSelectedUserId
            preSelectedDisplayName: gate.preSelectedName
            cardSelectSeq: gate.cardSelectSeq
            message: gate.localizedMessage(sessionManager.message)
            messageIsError: sessionManager.message.length > 0
            retryAfterMs: sessionManager.retryAfterMs
            busy: gate.verifying
            onPinSubmitted: function(userId, pin) {
                // 走同步路径：login() 内部会先把进度条那一帧刷出来再跑 KDF。
                // KDF 子进程（terminal_kdf_worker + KdfClient）已实现但尚未接线，
                // 异步路径：KDF 在子进程里算，结果经 loginFinished 回来。
                if (sessionManager.unlocking || gate.unlockingUi) return
                // 先把遮罩亮起来，150ms 后（它已上屏）才开始 KDF。
                gate.verifying = true
                gate.unlockingUi = true
                gate.pendingUser = userId
                gate.pendingPin = pin
                unlockStartDelay.restart()
            }
            onGuestRequested: {
                // 无 PIN：SessionManager 随机生成库密钥并建独立目录，
                // 退出时整目录删除（startGuestSession/endGuestSession）。
                const code = sessionManager.startGuestSession()
                if (code !== "") gate.cardNotice = gate.localizedMessage(code)
            }
            onRefreshRequested: sessionManager.refreshUsers()
            onRecoveryRequested: function(userId) { recoveryDialog.openFor(userId) }
            onPowerRequested: {
                if (typeof systemTools !== "undefined" && systemTools)
                    systemTools.requestPowerAction("poweroff")
            }
        }
    }

    // 异步认证收尾：无论成功失败都要放下忙碌标记，否则键盘会一直禁用。
    Connections {
        target: sessionManager
        function onLoginFinished(error) {
            gate.verifying = false
            if (error !== "") return
            gate.idleElapsed = 0
            gate.preSelectedUserId = ""
            gate.preSelectedName = ""
        }
        function onUnlockFinished(error) {
            gate.verifying = false
            if (error !== "") return
            gate.idleElapsed = 0
            gate.cardNotice = ""
            gate.cardNoticeIsError = false
        }
    }

    // 登录页的关机 / 关于 / 更多：放在窗口根级而不是 LoginPage 里面。
    // 原因：LoginPage 挂在 SessionGate 的 Loader 里，它根 Item 的 height 在子元素
    // 的计算上下文里读出来是 0（按钮 y 被算成 -150，整颗跑到屏幕外）。
    // ApplicationWindow 的尺寸是确定的，定位在这里才可靠。
    Item {
        id: loginChrome
        objectName: "loginChrome"
        anchors.fill: parent
        visible: gate.needLogin && !sessionManager.locked
        z: 30000   // 压在登录页 Loader（z=10）之上；本文件本身已在 Overlay 里


        Rectangle {
            objectName: "loginPower"
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: Theme.margin + Theme.hit + Theme.gap / 2
            anchors.bottomMargin: Theme.hit + Theme.gap * 2
            width: Theme.hit
            height: Theme.hit
            radius: width / 2
            color: powerMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
            border.width: 0

            MaterialIcon {
                anchors.centerIn: parent
                width: Theme.icon
                height: Theme.icon
                name: "power"
                light: true
            }
            MouseArea {
                id: powerMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: loginPowerConfirm.open()
                Accessible.role: Accessible.Button
                Accessible.name: I18n.t("关机")
            }
        }

        Rectangle {
            objectName: "loginMore"
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: Theme.margin
            anchors.bottomMargin: Theme.hit + Theme.gap * 2
            width: Theme.hit
            height: Theme.hit
            radius: width / 2
            color: moreMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
            border.width: 0

            MaterialIcon {
                anchors.centerIn: parent
                width: Theme.icon
                height: Theme.icon
                name: "more_vert"
                light: true
            }
            MouseArea {
                id: moreMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: loginMoreMenu.open()
                Accessible.role: Accessible.Button
                Accessible.name: I18n.t("更多")
            }
        }

        Popup {
            id: loginMoreMenu
            z: 40000   // Popup 渲染在窗口 overlay 上，z 需要单独压过登录门禁
            // 默认的 modal 遮罩是白色系，铺在深蓝主题上像一块白板。
            // 改用主题背景色的半透明：同色系压暗，弹窗自然浮起来。
            Overlay.modal: Rectangle {
                color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.72)
            }
            background: Rectangle {
                color: Theme.surface
                radius: Theme.shapeMedium
                border.width: 1
                border.color: Theme.outlineVariant
            }
            objectName: "loginMoreMenu"
            anchors.centerIn: parent
            width: 300 * Theme.scaleFactor
            height: moreCol.implicitHeight + 32 * Theme.scaleFactor
            padding: 16 * Theme.scaleFactor
            modal: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

            ColumnLayout {
                id: moreCol
                anchors.fill: parent
                spacing: Theme.gap

                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("关于")
                    fontPixelSize: Theme.title
                    color: Theme.foreground
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("树莓派终端 1.0")
                    color: Theme.foreground
                    fontPixelSize: Theme.body
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("PIN 与读数只在本机验证，不上传。")
                    color: Theme.outline
                    fontPixelSize: Theme.fontLabel
                    wrapMode: Text.WordWrap
                }
                CarButton {
                    Layout.fillWidth: true
                    text: I18n.t("关闭")
                    onClicked: loginMoreMenu.close()
                }
            }
        }

        // 关机是破坏性操作：二次确认，和系统其它电源入口一致。
        Popup {
            id: loginPowerConfirm
            z: 40000   // Popup 渲染在窗口 overlay 上，z 需要单独压过登录门禁
            // 与「关于」弹窗保持一致：默认遮罩是白色系，换成主题背景色的半透明。
            Overlay.modal: Rectangle {
                color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.72)
            }
            background: Rectangle {
                color: Theme.surface
                radius: Theme.shapeMedium
                border.width: 1
                border.color: Theme.outlineVariant
            }
            objectName: "loginPowerConfirm"
            anchors.centerIn: parent
            width: 340 * Theme.scaleFactor
            height: powerCol.implicitHeight + 32 * Theme.scaleFactor
            padding: 16 * Theme.scaleFactor
            modal: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

            ColumnLayout {
                id: powerCol
                anchors.fill: parent
                spacing: Theme.gap

                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("关机")
                    fontPixelSize: Theme.title
                    color: Theme.foreground
                }
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("这会立即中断当前工作。请确保可以重新接通电源。")
                    color: Theme.outline
                    fontPixelSize: Theme.fontLabel
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap / 2
                    CarButton {
                        Layout.fillWidth: true
                        text: I18n.t("取消")
                        onClicked: loginPowerConfirm.close()
                    }
                    CarButton {
                        Layout.fillWidth: true
                        text: I18n.t("关机")
                        accent: true
                        onClicked: {
                            loginPowerConfirm.close()
                            systemTools.requestPowerAction("poweroff")
                        }
                    }
                }
            }
        }
    }
    Component {
        id: lockComponent
        LockScreen {
            message: gate.cardNotice.length > 0 ? gate.cardNotice
                                                : gate.localizedMessage(sessionManager.message)
            messageIsError: gate.cardNotice.length > 0 ? gate.cardNoticeIsError
                                                       : sessionManager.message.length > 0
            busy: gate.verifying
            onPinSubmitted: function(pin) {
                if (sessionManager.unlocking || gate.unlockingUi) return
                gate.verifying = true
                gate.unlockingUi = true
                gate.pendingUser = ""
                gate.pendingPin = pin
                unlockStartDelay.restart()
            }
            onKeyboardRequested: gate.keyboardRequested()
            onLogoutRequested: {
                gate.cardNotice = ""
                gate.cardNoticeIsError = false
                // 访客的"退出登录"就是结束临时会话：整目录连库一起删。
                if (sessionManager.guestSession) {
                    sessionManager.endGuestSession()
                } else {
                    sessionManager.signOut()
                }
            }
        }
    }

    // 错误码 → 本地化提示。不回显账号是否存在。
    function localizedMessage(code) {
        if (!code || code.length === 0) return ""
        switch (code) {
        case "AUTH_FAILED":       return I18n.t("PIN 不正确")
        case "RATE_LIMITED":      return I18n.t("请稍候再试")
        case "NOT_AUTHORIZED":    return I18n.t("没有权限")
        case "SESSION_EXPIRED":   return I18n.t("会话已失效，请重新登录")
        case "SESSION_LOCKED":    return I18n.t("已锁定，请先解锁")
        case "SESSION_PIN_CHANGE_REQUIRED": return I18n.t("请先设置新的 PIN")
        case "STORAGE_UNAVAILABLE": return I18n.t("数据存储不可用")
        case "BUSY":              return I18n.t("请先结束正在进行的任务")
        case "LAST_ADMIN":        return I18n.t("至少保留一个管理员")
        case "NAME_MISMATCH":     return I18n.t("显示名不匹配")
        case "NOT_FOUND":         return I18n.t("账户不存在或已停用")
        case "ACCOUNT_DELETED":   return I18n.t("账户已删除")
        default:                  return I18n.t("操作失败")
        }
    }

    // 「没有用户」的指引已移到登录页用户列表内，避免和全屏版式底栏重叠。

    // ---------------------------------------------------------------- 解锁进度
    //
    // 为什么不是"转圈就算了"：解锁是两段真实耗时——KDF 60 万次（PC 约 110ms，
    // Pi 上按 R-01 测算到秒级）与打开加密库（SQLCipher 首开要解密首页）。
    // 两段都报给用户，进度条才有意义；纯粹的不确定转圈会让人以为卡死。
    Rectangle {
        id: unlockOverlay
        anchors.fill: parent
        objectName: "unlockOverlay"
        z: 31000                      // 压在登录页（30000）之上
        visible: gate.unlockingUi || sessionManager.unlocking
        color: Qt.rgba(0, 0, 0, 0.55)

        readonly property real progress:
            sessionManager.authStage === "verifying" ? 0.35 :
            sessionManager.authStage === "opening"   ? 0.82 : 1.0

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420 * Theme.scaleFactor, Math.max(240, parent.width - Theme.gap * 4))
            height: cardColumn.implicitHeight + Theme.gap * 2
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outlineVariant
            border.width: 1

            ColumnLayout {
                id: cardColumn
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    margins: Theme.gap
                }
                spacing: Theme.gap

                CarText {
                    Layout.fillWidth: true
                    heading: true
                    text: I18n.t("正在解锁")
                }

                // 线性进度：与启动层同一种视觉语言（4dp 圆角、轨道 + 填充）。
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 4
                    radius: 2
                    color: Theme.surfaceContainerHigh

                    Rectangle {
                        height: parent.height
                        radius: 2
                        color: Theme.accent
                        width: parent.width * unlockOverlay.progress
                        Behavior on width {
                            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                        }
                    }
                }

                CarText {
                    Layout.fillWidth: true
                    subdued: true
                    fontPixelSize: Theme.fontLabel
                    text: sessionManager.authStage === "opening"
                          ? I18n.t("正在打开数据")
                          : I18n.t("正在验证密码")
                }

                CarText {
                    Layout.fillWidth: true
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                    text: I18n.t("首次打开或数据较多时会慢一些，请勿关闭终端。")
                }
            }
        }
    }

    // ---- 恢复码登录 + 强制改 PIN + 新恢复码展示 ----
    Connections {
        target: sessionManager
        function onChanged() {
            if (sessionManager.loggedIn && sessionManager.mustChangePin
                    && !pinChangeDialog.opened)
                pinChangeDialog.open()
        }
    }

    Popup {
        id: recoveryDialog
        parent: Overlay.overlay
        z: 40000
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape
        width: Math.min(460 * Theme.scaleFactor, gate.width - Theme.gap * 4)
        height: recoveryColumn.implicitHeight + padding * 2
        x: (gate.width - width) / 2
        y: (gate.height - height) / 2
        padding: Theme.gap
        property string targetUserId: ""
        property string errorText: ""

        function openFor(userId) {
            targetUserId = userId
            errorText = ""
            recoveryCodeField.text = ""
            open()
        }
        function submit() {
            const code = sessionManager.loginWithRecoveryCode(targetUserId,
                                                               recoveryCodeField.text.trim())
            if (code !== "") {
                errorText = gate.localizedMessage(code)
                return
            }
            errorText = ""
            close()
        }

        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 1
            border.color: Theme.outlineVariant
        }
        contentItem: Column {
            id: recoveryColumn
            width: recoveryDialog.availableWidth
            spacing: Theme.gap / 2

            CarText { width: parent.width; heading: true; text: I18n.t("使用恢复码") }
            CarText {
                width: parent.width; subdued: true; fontPixelSize: Theme.fontLabel
                wrapMode: Text.Wrap
                text: I18n.t("恢复码只用于忘记 PIN。验证成功后必须先设置新 PIN，才能继续使用。")
            }
            CarField {
                id: recoveryCodeField
                width: parent.width
                placeholderText: I18n.t("恢复码（6 组，每组 4 位）")
                plainHint: true
                inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhUppercaseOnly
                onAccepted: recoveryDialog.submit()
                TapHandler { onTapped: gate.keyboardRequested() }
            }
            CarText {
                width: parent.width; visible: recoveryDialog.errorText.length > 0
                text: recoveryDialog.errorText; color: Theme.warning
                fontPixelSize: Theme.fontLabel; wrapMode: Text.Wrap
            }
            Row {
                width: parent.width
                spacing: Theme.gap
                layoutDirection: Qt.RightToLeft
                CarButton { text: I18n.t("取消"); onClicked: recoveryDialog.close() }
                CarButton { text: I18n.t("验证"); accent: true; onClicked: recoveryDialog.submit() }
            }
        }
    }

    Popup {
        id: pinChangeDialog
        parent: Overlay.overlay
        z: 41000
        modal: true
        focus: true
        closePolicy: Popup.NoAutoClose
        width: Math.min(460 * Theme.scaleFactor, gate.width - Theme.gap * 4)
        height: pinChangeColumn.implicitHeight + padding * 2
        x: (gate.width - width) / 2
        y: (gate.height - height) / 2
        padding: Theme.gap
        property string errorText: ""

        function submit() {
            const pin = newPinField.text
            if (pin.length < 6) { errorText = I18n.t("PIN 至少 6 位"); return }
            if (pin !== confirmPinField.text) { errorText = I18n.t("两次输入不一致"); return }
            if (!sessionManager.setRecoveryPin(pin)) {
                errorText = gate.localizedMessage(sessionManager.message)
                return
            }
            errorText = ""
            close()
            const code = sessionManager.beginRecoveryRotation()
            if (code.length > 0) {
                recoveryCodeDialog.code = code
                recoveryCodeDialog.open()
            }
        }

        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 1
            border.color: Theme.outlineVariant
        }
        contentItem: Column {
            id: pinChangeColumn
            width: pinChangeDialog.availableWidth
            spacing: Theme.gap / 2

            CarText { width: parent.width; heading: true; text: I18n.t("设置新的 PIN") }
            CarText {
                width: parent.width; subdued: true; fontPixelSize: Theme.fontLabel
                wrapMode: Text.Wrap
                text: I18n.t("恢复码已通过。设置新 PIN 后才能读写本机数据。")
            }
            CarField {
                id: newPinField
                width: parent.width
                placeholderText: I18n.t("新 PIN（至少 6 位）")
                plainHint: true
                echoMode: TextInput.Password
                inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhNoPredictiveText
                maximumLength: 32
                TapHandler { onTapped: gate.keyboardRequested() }
            }
            CarField {
                id: confirmPinField
                width: parent.width
                placeholderText: I18n.t("再次输入新 PIN")
                plainHint: true
                echoMode: TextInput.Password
                inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhNoPredictiveText
                maximumLength: 32
                onAccepted: pinChangeDialog.submit()
                TapHandler { onTapped: gate.keyboardRequested() }
            }
            CarText {
                width: parent.width; visible: pinChangeDialog.errorText.length > 0
                text: pinChangeDialog.errorText; color: Theme.warning
                fontPixelSize: Theme.fontLabel; wrapMode: Text.Wrap
            }
            CarButton {
                width: parent.width
                text: I18n.t("保存新 PIN")
                accent: true
                onClicked: pinChangeDialog.submit()
            }
        }
    }

    Popup {
        id: recoveryCodeDialog
        parent: Overlay.overlay
        z: 42000
        modal: true
        focus: true
        closePolicy: Popup.NoAutoClose
        width: Math.min(500 * Theme.scaleFactor, gate.width - Theme.gap * 4)
        height: codeColumn.implicitHeight + padding * 2
        x: (gate.width - width) / 2
        y: (gate.height - height) / 2
        padding: Theme.gap
        property string code: ""
        property string errorText: ""

        function commit() {
            if (!sessionManager.commitRecoveryRotation()) {
                errorText = I18n.t("保存恢复码失败，请稍后再试")
                return
            }
            errorText = ""
            close()
        }

        background: Rectangle {
            color: Theme.surface
            radius: Theme.shapeLarge
            border.width: 1
            border.color: Theme.outlineVariant
        }
        contentItem: Column {
            id: codeColumn
            width: recoveryCodeDialog.availableWidth
            spacing: Theme.gap / 2

            CarText { width: parent.width; heading: true; text: I18n.t("新的恢复码") }
            CarText {
                width: parent.width; subdued: true; fontPixelSize: Theme.fontLabel
                wrapMode: Text.Wrap
                text: I18n.t("请抄下并妥善保管。点击“我已保存”之前，旧恢复码仍然有效。")
            }
            CarText {
                width: parent.width
                text: recoveryCodeDialog.code
                color: Theme.accent
                fontPixelSize: Theme.title
                horizontalAlignment: Text.AlignHCenter
            }
            CarText {
                width: parent.width; visible: recoveryCodeDialog.errorText.length > 0
                text: recoveryCodeDialog.errorText; color: Theme.warning
                fontPixelSize: Theme.fontLabel; wrapMode: Text.Wrap
            }
            Row {
                width: parent.width
                spacing: Theme.gap
                layoutDirection: Qt.RightToLeft
                CarButton {
                    text: I18n.t("稍后")
                    onClicked: { sessionManager.cancelRecoveryRotation(); recoveryCodeDialog.close() }
                }
                CarButton {
                    text: I18n.t("我已保存")
                    accent: true
                    onClicked: recoveryCodeDialog.commit()
                }
            }
        }
    }
}
