import QtQuick
import QtQuick.Layouts
import "components"

// 最小模块页面：只用宿主注入的 hostTheme / sessionModel / moduleData。
// 脱离宿主单独打开时用内置演示数据，方便先验收布局。
Rectangle {
    id: page
    implicitWidth: 960
    implicitHeight: 600

    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property real gap: 16 * uiScale

    property double clock: Date.now()
    property string storeMessage: ""

    readonly property bool hosted: typeof sessionModel !== "undefined" && sessionModel
    readonly property var live: hosted ? (sessionModel.data || ({})) : page.demo
    readonly property bool hasReading: live.received_at !== undefined
    readonly property bool fresh: hasReading && clock - Number(live.received_at) < 15000
    readonly property string statusKind: !hosted ? "empty" : (!hasReading ? "loading" : (fresh ? "live" : "stale"))
    readonly property string statusText: !hosted ? "演示数据 · 未连接宿主"
        : (!hasReading ? "等待模块数据" : (fresh ? "实时" : "数据已过期"))
    readonly property var points: hosted ? (live.history || []) : page.demo.history

    readonly property var demo: ({
        received_at: Date.now(),
        temperature_C: 24.6,
        humidity_RH: 61.2,
        light_lux: 720,
        counter: 42,
        history: page.demoHistory()
    })

    function number(v) {
        return (v === undefined || v === null || typeof v === "boolean") ? NaN : Number(v)
    }

    function show(v, digits) {
        return isFinite(v) ? v.toFixed(digits) : "--"
    }

    function demoHistory() {
        const out = [], end = Date.now(), step = 15 * 60000
        for (let i = 23; i >= 0; --i) {
            const v = 24 + 2.4 * Math.sin(i / 4)
            out.push({ t: end - i * step, v: v, min: v - 0.6, max: v + 0.6 })
        }
        return out
    }

    function persist() {
        if (typeof moduleData === "undefined" || !moduleData) {
            storeMessage = "未连接宿主，无法保存"
            return
        }
        const t = page.number(page.live.temperature_C)
        if (!isFinite(t)) {
            storeMessage = "没有可保存的温度读数"
            return
        }
        const ok = moduleData.appendSample({
            "temperature_c": t,
            "humidity_rh": page.number(page.live.humidity_RH),
            "light_lux": page.number(page.live.light_lux),
            "source": "device.auto",
            "valid": true
        })
        storeMessage = ok ? "已保存" : "保存失败"
    }

    color: background

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: page.clock = Date.now()
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + 2 * gap
        clip: true

        Column {
            id: content
            x: gap
            y: gap
            width: parent.width - 2 * gap
            spacing: gap

            Item {
                width: parent.width
                height: Math.max(titleColumn.implicitHeight, badge.implicitHeight)

                Column {
                    id: titleColumn
                    width: parent.width - badge.implicitWidth - gap
                    spacing: 4 * uiScale
                    Text {
                        text: qsTr("@MODULE_NAME@")
                        color: foreground
                        font.pixelSize: 24 * uiScale
                        font.bold: true
                        width: parent.width
                        elide: Text.ElideRight
                    }
                    Text {
                        text: hosted ? qsTr("设备数据经模块会话上报") : qsTr("先看布局：下面是示例数据")
                        color: muted
                        font.pixelSize: 14 * uiScale
                        width: parent.width
                        elide: Text.ElideRight
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

            GridLayout {
                width: parent.width
                columns: page.width >= 760 * uiScale ? 3 : 2
                columnSpacing: gap
                rowSpacing: gap

                MetricTile {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 160 * uiScale
                    theme: page.theme
                    kind: "temperature"
                    label: qsTr("温度")
                    value: page.show(page.number(page.live.temperature_C), 1)
                    unit: "°C"
                }
                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "humidity"
                    label: qsTr("湿度")
                    value: page.show(page.number(page.live.humidity_RH), 1)
                    unit: "%RH"
                }
                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "light"
                    label: qsTr("照度")
                    value: page.show(page.number(page.live.light_lux), 0)
                    unit: "lux"
                    note: page.number(page.live.counter) >= 0 ? qsTr("样本 %1").arg(page.number(page.live.counter)) : ""
                }
            }

            Rectangle {
                width: parent.width
                height: 250 * uiScale
                radius: 16 * uiScale
                color: surface
                border.width: 1
                border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

                Column {
                    anchors.fill: parent
                    anchors.margins: 16 * uiScale
                    spacing: 8 * uiScale

                    Row {
                        width: parent.width
                        spacing: gap
                        Text {
                            text: qsTr("最近 6 小时")
                            color: foreground
                            font.pixelSize: 16 * uiScale
                            width: parent.width - save.width - gap
                        }
                        Rectangle {
                            id: save
                            width: Math.max(88, 88 * uiScale)
                            height: Math.max(44, 44 * uiScale)
                            radius: 10 * uiScale
                            color: mouse.pressed ? Qt.rgba(accent.r, accent.g, accent.b, 0.45)
                                                 : Qt.rgba(accent.r, accent.g, accent.b, 0.18)
                            border.width: 1
                            border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.55)
                            Text {
                                anchors.centerIn: parent
                                text: qsTr("保存读数")
                                color: foreground
                                font.pixelSize: 14 * uiScale
                            }
                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                onClicked: page.persist()
                            }
                        }
                    }

                    TrendChart {
                        width: parent.width
                        height: parent.height - 38 * uiScale
                        theme: page.theme
                        points: page.points
                        unit: "°C"
                        emptyText: qsTr("还没有历史读数")
                    }
                }
            }

            Text {
                text: page.storeMessage !== "" ? page.storeMessage
                    : qsTr("这是最小模板：发布字段在 firmware/main/main.c，页面在 qml/ModulePage.qml。")
                color: muted
                font.pixelSize: 12 * uiScale
                width: parent.width
                wrapMode: Text.Wrap
            }
        }
    }
}
