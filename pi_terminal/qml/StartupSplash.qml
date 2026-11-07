import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Linux 风格的启动日志：黑色终端、等宽字体、逐行滚出的 [ OK ] 行。
// 语义不变：四行里程碑仍由真实状态驱动（interfaceReady/wallpaperReady/frameReady/cacheReady），
// objectName 与对外属性保持兼容（startupSplash/startupContent/startupStep*/startupProgress）。
FocusScope {
    id: splash
    objectName: "startupSplash"
    property bool interfaceReady: false
    property bool wallpaperReady: false
    property bool frameReady: false
    property bool cacheReady: false
    property bool wallpaperFailed: false
    property bool minimumElapsed: false
    property bool cacheDeadlineElapsed: false
    readonly property bool usingFallback: cacheDeadlineElapsed && !cacheReady
    // Ordered milestones, not elapsed-time estimates of work completed.
    readonly property int completedSteps: !interfaceReady ? 0 : !wallpaperReady ? 1
        : !frameReady ? 2 : !(cacheReady || cacheDeadlineElapsed) ? 3 : 4
    readonly property real progress: completedSteps / 4
    readonly property bool canFinish: completedSteps === 4 && minimumElapsed
    readonly property var steps: [I18n.t("读取界面与偏好设置"), I18n.t("加载桌面壁纸"),
        I18n.t("呈现桌面首帧"), I18n.t("准备窗口与面板模糊缓存")]
    readonly property string statusText: completedSteps < 4 ? steps[completedSteps]
        : usingFallback ? I18n.t("缓存预热较慢，使用兼容渲染进入桌面") : I18n.t("准备就绪")
    signal finished()

    // 真实墙钟时间：日志时间戳来自这里，不做“假进度”。
    property double bootMs: 0
    property double nowMs: 0
    readonly property string uptimeText: {
        const ms = Math.max(0, splash.nowMs - splash.bootMs);
        const s = Math.floor(ms / 1000);
        const frac = Math.floor(ms % 1000);
        return String(s).padStart(4, " ") + "." + String(frac).padStart(3, "0");
    }
    // 终端启动日志的固定前导行（事实性信息，不表示进度）
    readonly property var bootLines: [
        "Linux 6.12 aarch64 · orpi-terminal 6.5.3",
        "qt: connected to display · xcb · VC4 V3D",
        "config: product profile loaded · control bridge /dev/ttyACM0"
    ]

    focus: true
    Keys.onPressed: event => event.accepted = true
    Keys.onReleased: event => event.accepted = true
    Material.theme: Material.Dark
    Material.accent: Theme.accent
    Material.foreground: Theme.foreground

    onCanFinishChanged: if (canFinish) exitAnimation.start()

    Component.onCompleted: { splash.bootMs = Date.now(); splash.nowMs = Date.now(); }
    Timer { interval: 60; repeat: true; running: true; onTriggered: splash.nowMs = Date.now() }
    Timer { interval: 1100; running: splash.frameReady && !splash.minimumElapsed; onTriggered: splash.minimumElapsed = true }
    // Native per-surface fallback already exists. Never call a timed-out cache ready.
    Timer { interval: 6000; running: !splash.cacheReady; onTriggered: splash.cacheDeadlineElapsed = true }

    readonly property color termBg: "#05080b"
    readonly property color termPanel: "#0a0f14"
    readonly property color termBorder: "#1d2833"
    readonly property color termText: "#cfdae6"
    readonly property color termDim: "#5f7183"
    readonly property color termOk: "#6ee787"
    readonly property color termWarn: "#d29922"
    readonly property string mono: "monospace"

    Rectangle { anchors.fill: parent; color: splash.termBg }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: wheel => wheel.accepted = true }
    // 扫描线，弱化“纯色卡片”的观感
    Repeater {
        model: Math.ceil(splash.height / 4)
        Rectangle {
            width: splash.width; height: 1; y: index * 4
            color: "#ffffff"; opacity: 0.012
        }
    }

    ColumnLayout {
        id: content
        objectName: "startupContent"
        anchors.centerIn: parent
        width: Math.min(760, Math.max(240, splash.width - 48))
        spacing: 10
        // 首帧未到前保持可读；初始化卡住 GUI 线程时也不至于一片黑。
        opacity: 0.86
        scale: 0.98

        // 终端标题栏
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: ["#ff5f56", "#ffbd2e", "#27c93f"]
                Rectangle { width: 10; height: 10; radius: 5; color: modelData; opacity: 0.85 }
            }
            Label {
                Layout.fillWidth: true
                text: "root@orpi:~# systemctl --user start terminal"
                color: splash.termDim; font.family: splash.mono; font.pixelSize: 12
                elide: Text.ElideRight
            }
            Label {
                objectName: "startupPercent"
                text: Math.round(splash.progress * 100) + "%"
                color: splash.termOk; font.family: splash.mono; font.pixelSize: 12
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: log.implicitHeight + 24
            color: splash.termPanel
            radius: 8
            border.width: 1; border.color: splash.termBorder

            ColumnLayout {
                id: log
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                // 固定前导行：窗口够高时才显示，避免小窗溢出
                Repeater {
                    model: splash.height >= 440 ? splash.bootLines : []
                    delegate: RowLayout {
                        required property string modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Label {
                            text: "[ " + splash.uptimeText + "]"
                            color: splash.termDim; font.family: splash.mono; font.pixelSize: 12
                        }
                        Label {
                            Layout.fillWidth: true
                            text: modelData
                            color: splash.termDim; font.family: splash.mono; font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }
                }

                // 四行里程碑：仍是真实状态，只是换成日志行
                Repeater {
                    model: 4
                    // 用锚点而不是 RowLayout 对齐：中文/英文标签高度不同，
                    // RowLayout 的 VCenter 在中文字体下会差 1px，启动测试要求 <0.5px。
                    delegate: Item {
                        required property int index
                        objectName: "startupStep" + index
                        Layout.fillWidth: true
                        Layout.preferredHeight: 24
                        Label {
                            id: stepTag
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: index < splash.completedSteps ? "[  OK  ]" : "[ .... ]"
                            color: index < splash.completedSteps ? splash.termOk : splash.termWarn
                            font.family: splash.mono; font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                        Item {
                            id: stepIconSlot
                            objectName: "startupStepIconSlot" + index
                            width: 24; height: 24
                            anchors.left: stepTag.right
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            MaterialIcon {
                                objectName: "startupStepIcon" + index
                                anchors.fill: parent
                                name: index < splash.completedSteps ? "check_circle" : "pending"
                                // MaterialIcon 是 Image，只能选黑白两套 SVG，不能染色；用透明度表达未完成
                                light: true
                                opacity: index < splash.completedSteps ? 0.95 : 0.35
                            }
                        }
                        Label {
                            objectName: "startupStepText" + index
                            anchors.left: stepIconSlot.right
                            anchors.leftMargin: 8
                            anchors.right: stepElapsed.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            // 固定 24 高 + 显式垂直居中：中文行高是奇数（17）时，
                            // 按内容高度居中会落在 11.5，和 24 高图标槽的 12 差 0.5px。
                            height: 24
                            verticalAlignment: Text.AlignVCenter
                            text: index === 1 && splash.wallpaperFailed ? I18n.t("壁纸不可用，已使用默认背景")
                                : index === 3 && splash.usingFallback ? I18n.t("模糊缓存稍后就绪，使用兼容渲染") : splash.steps[index]
                            color: index <= splash.completedSteps ? splash.termText : splash.termDim
                            font.family: splash.mono; font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Label {
                            id: stepElapsed
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: index < splash.completedSteps
                            text: splash.uptimeText
                            color: splash.termDim; font.family: splash.mono; font.pixelSize: 11
                        }
                    }
                }

                // 收尾行 + 闪烁光标
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        visible: splash.completedSteps === 4
                        text: "[  OK  ] " + (splash.usingFallback ? I18n.t("已进入桌面（兼容渲染）") : I18n.t("桌面会话已就绪"))
                        color: splash.termOk; font.family: splash.mono; font.pixelSize: 12
                        Layout.fillWidth: true
                    }
                    Item { Layout.fillWidth: splash.completedSteps !== 4 }
                    Rectangle {
                        width: 8; height: 14
                        color: splash.termOk
                        visible: splash.completedSteps < 4
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.15; duration: 450 }
                            NumberAnimation { to: 1.0; duration: 450 }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "startupStatus"
                Layout.fillWidth: true
                text: splash.statusText
                color: splash.termDim; font.family: splash.mono; font.pixelSize: 11
                elide: Text.ElideRight
            }
            Label {
                text: I18n.t("启动日志")
                color: splash.termDim; font.family: splash.mono; font.pixelSize: 11
            }
        }

        // 保持测试与外部对启动进度的读取（细线，视觉上像终端进度条）
        ProgressBar {
            id: progressBar
            objectName: "startupProgress"
            Layout.fillWidth: true
            from: 0; to: 1; value: splash.progress
            padding: 0
            background: Rectangle { implicitHeight: 3; color: splash.termBorder; radius: 1.5 }
            contentItem: Rectangle {
                implicitHeight: 3
                width: progressBar.visualPosition * parent.width
                color: splash.termOk; radius: 1.5
            }
        }
    }

    ParallelAnimation {
        running: splash.frameReady
        NumberAnimation { target: content; property: "opacity"; to: 1; duration: 240 }
        NumberAnimation { target: content; property: "scale"; to: 1; duration: 360; easing.type: Easing.OutCubic }
    }
    SequentialAnimation {
        id: exitAnimation
        PauseAnimation { duration: 200 }
        NumberAnimation { target: splash; property: "opacity"; to: 0; duration: 240; easing.type: Easing.InOutCubic }
        ScriptAction { script: splash.finished() }
    }
}
