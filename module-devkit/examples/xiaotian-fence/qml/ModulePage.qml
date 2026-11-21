import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Material
import "components"

// 啸天红外围界模块页面（模块自带 QML，由宿主独立引擎加载）。
//
// 可用注入项只有三个（报告 §6.1 / §8.4）：
//   sessionModel  模块实时数据
//   moduleData    当前用户的数据接口（appendSample / historySeries / ...）
//   hostTheme     主题值（background/surface/foreground/accent/scale）
//
// 拿不到宿主的 I18n：文案在本文件内自带中英双语。
// 拿不到宿主的任何服务对象、数据库或密钥。
Rectangle {
    id: page
    property bool english: false

    // 宿主经 context 注入 hostTheme（含 scale）；页面不声明同名属性，
    // 否则会**遮蔽** context property（模块页拿到的永远是自己的默认值）。
    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1

    property double clock: Date.now()
    property bool diagnosticsOpen: false
    property var historyPoints: []

    readonly property var latest: latestData
    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)
    readonly property color warn: "#fbbf24"
    readonly property real gap: 16 * uiScale
    readonly property real hit: Math.max(48, 64 * uiScale)

    readonly property bool hosted: typeof sessionModel !== "undefined" && sessionModel
    readonly property var demo: ({
        armed: true, sensor_online: true, fault_code: "", trigger_count: 2,
        trigger_ms: Date.now() - 120000, heartbeat_ms: Date.now(),
        power_known: true, power_source: "battery", has_battery: true, battery_percent: 76,
        segments: [
            { segment_id: "A", blocked: false, sample_ms: Date.now(), valid: true },
            { segment_id: "B", blocked: true, sample_ms: Date.now(), valid: true }
        ]
    })
    readonly property string statusKind: !hosted ? "empty"
        : fence.state(page.clock) === "fault" || fence.state(page.clock) === "alarm" ? "error"
        : fence.state(page.clock) === "offline" ? "offline"
        : fence.state(page.clock) === "unknown" ? "stale"
        : "live"
    readonly property string statusText: !hosted ? "演示数据 · 未连接宿主" : page.label(fence.state(page.clock))

    // 把模块上报的字段喂给状态对象（同目录的 FenceState.qml）。
    function applySample(d) {
        if (!d) return
        if (d.armed !== undefined) fence.moduleArmed = !!d.armed
        if (d.trigger_count !== undefined) fence.triggerCount = Number(d.trigger_count)
        if (d.sensor_online !== undefined) fence.sensorOnline = !!d.sensor_online
        if (d.fault_code !== undefined) fence.faultCode = String(d.fault_code)
        if (d.heartbeat_ms !== undefined) fence.lastHeartbeatMs = Number(d.heartbeat_ms)
        if (d.trigger_ms !== undefined) fence.lastTriggerMs = Number(d.trigger_ms)
        if (d.power_known !== undefined) {
            fence.powerKnown = !!d.power_known
            fence.powerSource = d.power_source || "unknown"
            fence.hasBattery = !!d.has_battery
            fence.batteryPercent = d.battery_percent === undefined ? -1 : Number(d.battery_percent)
        }
        if (d.segments !== undefined && d.segments !== null) fence.segments = d.segments
    }

    // sessionModel 是 C++ 注入的 SessionModel，它的 data 是 NOTIFY changed 的属性。
    // latest 直接绑定到它的 data，变更时 QML 会重算并触发 onLatestChanged。
    readonly property var latestData: hosted ? (sessionModel.data || ({})) : page.demo
    onLatestDataChanged: applySample(latestData)


    // 落库：围界模块没有连续测量值，当前只上报事件；不写伪造的样本。
    function refreshHistory() {
        if (typeof moduleData === "undefined" || !moduleData) return
        historyPoints = moduleData.historySeries(7 * 24 * 3600 * 1000, 60 * 60 * 1000)
    }

    FenceState { id: fence }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: page.clock = Date.now()
    }

    Component.onCompleted: {
        applySample(page.latestData)
        refreshHistory()
    }

    Connections {
        target: typeof moduleData !== "undefined" ? moduleData : null
        function onDataChanged() { page.refreshHistory() }
    }

    function label(key) {
        const zh = {
            armed: "已布防", disarmed: "未布防", alarm: "告警",
            offline: "离线", fault: "故障", unknown: "状态未知",
            blocked: "遮挡", clear: "未遮挡", notDetected: "未检测",
            external: "外部供电", battery: "电池供电"
        }
        const en = {
            armed: "Armed", disarmed: "Disarmed", alarm: "Alarm",
            offline: "Offline", fault: "Fault", unknown: "Unknown",
            blocked: "Blocked", clear: "Clear", notDetected: "Not detected",
            external: "External power", battery: "Battery"
        }
        const table = page.english ? en : zh
        return table[key] || key
    }

    color: page.background
    Material.theme: Material.Dark
    Material.accent: page.accent

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: page.gap
        spacing: page.gap

        Item {
            Layout.fillWidth: true
            implicitHeight: Math.max(titleColumn.implicitHeight, badge.implicitHeight)

            Column {
                id: titleColumn
                width: parent.width - badge.implicitWidth - page.gap
                spacing: 4 * page.uiScale
                Text {
                    text: page.english ? "Xiaotian fence" : "啸天红外围界"
                    color: page.foreground
                    font.pixelSize: 22 * page.uiScale
                    font.bold: true
                }
                Text {
                    text: page.english ? "Outdoor infrared perimeter" : "门口通行与户外折线围界"
                    color: page.muted
                    font.pixelSize: 12 * page.uiScale
                }
            }

            StateBadge {
                id: badge
                anchors.right: parent.right
                anchors.top: parent.top
                theme: page.theme
                kind: page.statusKind
                text: page.statusText
            }
        }

        // ---- 主状态 ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: page.hit * 1.6
            radius: 16 * page.uiScale
            color: page.surface
            border.width: 2
            border.color: fence.stateIsWarning(page.clock) ? page.warn : page.line
            Text {
                anchors.centerIn: parent
                text: page.label(fence.state(page.clock))
                color: fence.stateIsWarning(page.clock) ? page.warn : page.foreground
                font.pixelSize: 24 * page.uiScale
            }
        }

        // ---- 双路遮挡 ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: blockageColumn.implicitHeight + 2 * page.gap
            radius: 16 * page.uiScale
            color: page.surface
            border.width: 1
            border.color: page.line

            ColumnLayout {
                id: blockageColumn
                anchors.fill: parent
                anchors.margins: page.gap
                spacing: page.gap / 2
                Text {
                    text: page.english ? "Blockage" : "遮挡状态"
                    color: page.foreground
                    font.pixelSize: 14 * page.uiScale
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: page.gap / 2
                    Repeater {
                        model: fence.segments
                        delegate: Rectangle {
                            required property var modelData
                            width: 170 * page.uiScale
                            height: page.hit
                            radius: 12 * page.uiScale
                            color: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.05)
                            border.width: 1
                            border.color: fence.segmentState(modelData) === "blocked" ? page.warn : page.line
                            Text {
                                anchors.centerIn: parent
                                text: (modelData.segment_id || "?") + "  "
                                      + page.label(fence.segmentState(modelData))
                                color: page.foreground
                                font.pixelSize: 14 * page.uiScale
                            }
                        }
                    }
                }
                Text {
                    visible: !fence.segments || fence.segments.length === 0
                    text: page.english ? "No segment data" : "还没有分段数据"
                    color: page.muted
                    font.pixelSize: 12 * page.uiScale
                }
            }
        }

        // ---- 计数与新鲜度 ----
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: infoColumn.implicitHeight + 2 * page.gap
            radius: 16 * page.uiScale
            color: page.surface
            border.width: 1
            border.color: page.line

            ColumnLayout {
                id: infoColumn
                anchors.fill: parent
                anchors.margins: page.gap
                spacing: page.gap / 2
                Text {
                    text: (page.english ? "Triggers since boot: " : "本次启动后触发: ")
                          + fence.triggerCount
                    color: page.foreground
                    font.pixelSize: 16 * page.uiScale
                }
                Text {
                    readonly property double age: fence.dataAgeMs(page.clock)
                    text: (page.english ? "Data: " : "数据: ")
                          + (age < 0 ? (page.english ? "no data" : "尚无数据")
                                     : age <= fence.heartbeatTimeoutMs
                                       ? (page.english ? "fresh" : "新鲜")
                                       : (page.english ? "stale" : "已过期"))
                    color: page.muted
                    font.pixelSize: 12 * page.uiScale
                }
                Text {
                    text: (page.english ? "Power: " : "供电: ")
                          + (fence.powerKnown
                             ? page.label(fence.powerSource)
                               + (fence.hasBattery && fence.batteryPercent >= 0
                                  ? " " + fence.batteryPercent + "%" : "")
                             : page.label("notDetected"))
                    color: page.muted
                    font.pixelSize: 12 * page.uiScale
                }
            }
        }

        // ---- 诊断：默认折叠 ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: page.hit
            radius: 12 * page.uiScale
            color: page.diagnosticsOpen ? Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.24)
                                        : Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
            border.width: 1
            border.color: page.diagnosticsOpen ? page.accent : page.line
            Text {
                anchors.centerIn: parent
                text: page.diagnosticsOpen
                      ? (page.english ? "Hide diagnostics" : "收起诊断")
                      : (page.english ? "Show diagnostics" : "显示诊断")
                color: page.foreground
                font.pixelSize: 14 * page.uiScale
            }
            MouseArea {
                anchors.fill: parent
                onClicked: page.diagnosticsOpen = !page.diagnosticsOpen
            }
        }
        Rectangle {
            Layout.fillWidth: true
            visible: page.diagnosticsOpen
            implicitHeight: diagnosticsText.implicitHeight + 2 * page.gap
            radius: 12 * page.uiScale
            color: page.surface
            border.width: 1
            border.color: page.line
            Text {
                id: diagnosticsText
                anchors.fill: parent
                anchors.margins: page.gap
                text: JSON.stringify(page.latest, null, 2)
                color: page.muted
                font.pixelSize: 12 * page.uiScale
                wrapMode: Text.WrapAnywhere
            }
        }

        Item { Layout.fillHeight: true }
    }
}
