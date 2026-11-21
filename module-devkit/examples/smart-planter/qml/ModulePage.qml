import QtQuick
import QtQuick.Layouts
import "components"

Rectangle {
    id: page

    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
    readonly property real gap: 16 * uiScale

    property bool weekView: false
    property double clock: Date.now()
    property string storeMessage: ""
    readonly property bool hosted: typeof sessionModel !== "undefined" && sessionModel
    readonly property var latest: hosted ? (sessionModel.data || ({})) : page.demo
    property var historyPoints: []

    readonly property var demo: ({
        temperature_C: 24.6, humidity_RH: 61.2, light_lux: 720, pressure_hPa: 1015.1,
        battery_pct: 54, battery_V: 3.85, power_source: "unknown",
        power_protection: "source_unknown_auto_sleep_inhibited",
        received_at: Date.now(), history_day: page.demoHistory(24, 60), history_week: page.demoHistory(7 * 24, 2 * 60)
    })

    function demoHistory(hours, stepMinutes) {
        const out = [], end = Date.now(), step = stepMinutes * 60000
        for (let i = Math.floor(hours * 60 / stepMinutes); i >= 0; --i) {
            const v = 23 + 2.6 * Math.sin(i / 6)
            out.push({ t: end - i * step, v: v, min: v - 0.8, max: v + 0.8 })
        }
        return out
    }

    function number(v) {
        return v === null || v === undefined || typeof v === "boolean" ? NaN : Number(v)
    }
    function format(v, d) { return isFinite(v) ? v.toFixed(d) : "--" }

    function refreshHistory() {
        if (typeof moduleData === "undefined" || !moduleData) return
        historyPoints = moduleData.historySeries(7 * 24 * 3600 * 1000, 60 * 60 * 1000)
    }

    // 把当前读数落库（去重由 source 与时间保证）。
    function persistReading() {
        if (typeof moduleData === "undefined" || !moduleData) {
            storeMessage = "未连接宿主，无法保存"
            return
        }
        const t = page.number(page.latest.temperature_C)
        if (!isFinite(t)) {
            storeMessage = "没有可保存的温度读数"
            return
        }
        const ok = moduleData.appendSample({
            "temperature_c": t,
            "humidity_rh": page.number(page.latest.humidity_RH),
            "light_lux": page.number(page.latest.light_lux),
            "source": "device.auto",
            "valid": true
        })
        if (!ok) storeMessage = "数据存储不可用"
        else { storeMessage = "已保存"; page.refreshHistory() }
    }

    Component.onCompleted: refreshHistory()

    Connections {
        target: typeof moduleData !== "undefined" ? moduleData : null
        function onDataChanged() { page.refreshHistory() }
    }

    readonly property bool hasReading: latest.received_at !== undefined
    readonly property bool fresh: hasReading && clock - Number(latest.received_at) < 15000
    readonly property string statusKind: !hosted ? "empty" : (!hasReading ? "loading" : (fresh ? "live" : "stale"))
    readonly property string statusText: !hosted ? "演示数据 · 未连接宿主"
        : (!hasReading ? "等待新数据" : (fresh ? "实时监测中" : "数据已过期"))

    readonly property real temperature: number(latest.temperature_C)
    readonly property real humidity: number(latest.humidity_RH)
    readonly property real light: number(latest.light_lux)
    readonly property real battery: number(latest.battery_pct)
    readonly property bool external: latest.external_power === true
    readonly property string source: latest.power_source || "unknown"
    readonly property string sourceText: external ? "外部供电" : source === "battery" ? "电池供电" : "供电来源待检测"
    readonly property string lightText: !isFinite(light) ? "等待光照数据" : light < 50 ? "光线偏暗 · 可移近窗边" : light < 150 ? "光线较弱 · 留意植物需求" : light < 1000 ? "散射光环境 · 按品种调整" : "光线较强 · 留意暴晒"
    readonly property var points: {
        const history = weekView ? latest.history_week : latest.history_day
        return history || []
    }
    readonly property string protectionText: {
        const s = latest.power_protection || ""
        if (s === "source_unknown_auto_sleep_inhibited") return "未接供电检测，自动休眠未启用（需硬件电池保护）"
        if (s === "external_supply_no_low_battery_shutdown") return "外部供电有效，不因低电量关机"
        if (s === "battery_low_warning") return "电池低压警告，持续低压后安全休眠"
        if (s === "battery_guard_active") return "电池保护已启用，低于3.40V持续20秒后休眠"
        return "等待固件状态"
    }

    color: background

    Timer {
        interval: 1000
        running: page.visible
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
                height: Math.max(titleColumn.implicitHeight, statusBadge.implicitHeight)

                Column {
                    id: titleColumn
                    width: parent.width - statusBadge.implicitWidth - gap
                    spacing: 4 * uiScale
                    Text {
                        text: "PLANT COMPANION / 植物环境助手"
                        color: muted
                        font.pixelSize: 12 * uiScale
                        font.letterSpacing: 1
                    }
                    Text {
                        text: "让每一片叶子，都有好环境"
                        color: foreground
                        font.pixelSize: 24 * uiScale
                        font.bold: true
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                }

                StateBadge {
                    id: statusBadge
                    anchors.right: parent.right
                    anchors.top: parent.top
                    theme: page.theme
                    kind: page.statusKind
                    text: page.statusText
                }
            }

            Rectangle {
                width: parent.width
                height: width < 600 * uiScale ? 235 * uiScale : 208 * uiScale
                radius: 18 * uiScale
                color: surface
                border.width: 1
                border.color: line

                PlantScene {
                    width: Math.min(parent.width * 0.32, 210 * uiScale)
                    height: parent.height - 20 * uiScale
                    x: 8 * uiScale
                    y: 10 * uiScale
                }
                Column {
                    x: Math.min(parent.width * 0.32, 210 * uiScale) + 16 * uiScale
                    y: 22 * uiScale
                    width: parent.width - x - 18 * uiScale
                    spacing: 9 * uiScale
                    Text {
                        text: "我的植物小站"
                        font.pixelSize: 23 * uiScale
                        font.bold: true
                        color: foreground
                    }
                    Text {
                        text: page.lightText
                        font.pixelSize: 16 * uiScale
                        color: muted
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                    Text {
                        text: "环境建议仅供参考，最佳温湿度与光照因植物品种而异。"
                        font.pixelSize: 13 * uiScale
                        color: muted
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                    Rectangle {
                        width: parent.width
                        height: page.width < 600 * uiScale ? 75 * uiScale : 53 * uiScale
                        radius: 12 * uiScale
                        color: Qt.rgba(accent.r, accent.g, accent.b, 0.10)
                        Text {
                            anchors.fill: parent
                            anchors.margins: 10 * uiScale
                            verticalAlignment: Text.AlignVCenter
                            text: "BME280 空气温湿度  ·  BH1750 光照\n未接土壤湿度探头，不提供土壤读数或自动浇水"
                            color: foreground
                            font.pixelSize: 12 * uiScale
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            GridLayout {
                width: parent.width
                columns: page.width < 600 * uiScale ? 2 : 4
                columnSpacing: gap
                rowSpacing: gap

                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "temperature"; label: "空气温度"
                    value: page.format(page.temperature, 1); unit: "°C"
                    note: "观察昼夜温差"
                }
                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "humidity"; label: "空气湿度"
                    value: page.format(page.humidity, 1); unit: "%RH"
                    note: "非土壤含水率"
                }
                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "light"; label: "环境光照"
                    value: page.format(page.light, 0); unit: "lux"
                    note: "照度不等于光合辐射"
                }
                MetricTile {
                    Layout.fillWidth: true
                    theme: page.theme
                    kind: "counter"; label: "大气压力"
                    value: page.format(page.number(page.latest.pressure_hPa), 1); unit: "hPa"
                    note: "记录环境变化"
                }
            }

            Rectangle {
                width: parent.width
                height: chartColumn.implicitHeight + 32 * uiScale
                radius: 18 * uiScale
                color: surface
                border.width: 1
                border.color: line

                Column {
                    id: chartColumn
                    anchors.fill: parent
                    anchors.margins: 16 * uiScale
                    spacing: 8 * uiScale

                    Row {
                        width: parent.width
                        spacing: 8 * uiScale
                        Text {
                            width: parent.width - dayButton.width - weekButton.width - saveButton.width - 24 * uiScale
                            height: 48 * uiScale
                            verticalAlignment: Text.AlignVCenter
                            text: "温度生长日记"
                            color: foreground
                            font.pixelSize: 20 * uiScale
                            font.bold: true
                        }
                        Rectangle {
                            id: dayButton
                            width: 76 * uiScale; height: 44 * uiScale; radius: 22 * uiScale
                            color: !page.weekView ? Qt.rgba(accent.r, accent.g, accent.b, 0.30) : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
                            border.width: 1
                            border.color: !page.weekView ? accent : line
                            Text {
                                anchors.centerIn: parent
                                text: "一天"; color: foreground; font.pixelSize: 15 * uiScale
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: page.weekView = false
                                Accessible.name: "查看最近24小时温度"
                            }
                        }
                        Rectangle {
                            id: weekButton
                            width: 76 * uiScale; height: 44 * uiScale; radius: 22 * uiScale
                            color: page.weekView ? Qt.rgba(accent.r, accent.g, accent.b, 0.30) : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
                            border.width: 1
                            border.color: page.weekView ? accent : line
                            Text {
                                anchors.centerIn: parent
                                text: "一周"; color: foreground; font.pixelSize: 15 * uiScale
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: page.weekView = true
                                Accessible.name: "查看最近7天温度"
                            }
                        }
                        Rectangle {
                            id: saveButton
                            width: Math.max(88, 88 * uiScale); height: 44 * uiScale; radius: 22 * uiScale
                            color: Qt.rgba(accent.r, accent.g, accent.b, 0.18)
                            border.width: 1
                            border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.55)
                            Text {
                                anchors.centerIn: parent
                                text: "保存读数"; color: foreground; font.pixelSize: 14 * uiScale
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: page.persistReading()
                                Accessible.name: "保存当前读数"
                            }
                        }
                    }

                    TrendChart {
                        width: parent.width
                        height: 200 * uiScale
                        theme: page.theme
                        points: page.points
                        unit: "°C"
                        spanMs: page.weekView ? 7 * 24 * 3600 * 1000 : 24 * 3600 * 1000
                        endTime: page.number(page.latest.received_at)
                        emptyText: "开始积累真实温度，缺测时段保持空白"
                    }

                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: muted
                        font.pixelSize: 12 * uiScale
                        text: page.weekView ? "最近7天 · 每2小时均值 / 淡色带为最低～最高 · 缺测不连线" : "最近24小时 · 每15分钟均值 / 淡色带为最低～最高 · 缺测不连线"
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: page.latest.history_error ? "#f87171" : muted
                        font.pixelSize: 12 * uiScale
                        text: page.storeMessage !== "" ? page.storeMessage
                            : (page.latest.history_error || ("已记录 " + page.points.length + " 个时段 · 历史保存在 Pi，首次使用不会生成虚假日/周数据"))
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: page.width < 600 * uiScale ? 176 * uiScale : 150 * uiScale
                radius: 18 * uiScale
                color: surface
                border.width: 1
                border.color: line

                Column {
                    anchors.fill: parent
                    anchors.margins: 16 * uiScale
                    spacing: 9 * uiScale
                    Row {
                        spacing: 12 * uiScale
                        Rectangle {
                            width: 56 * uiScale; height: 30 * uiScale; radius: 5 * uiScale
                            color: "transparent"; border.width: 2; border.color: muted
                            Rectangle {
                                x: 4 * uiScale; y: 4 * uiScale
                                height: 22 * uiScale
                                width: isFinite(page.battery) ? 48 * uiScale * Math.max(0, Math.min(100, page.battery)) / 100 : 0
                                radius: 2 * uiScale
                                color: page.battery < 20 ? "#f87171" : "#4ade80"
                            }
                        }
                        Text {
                            text: "电量 " + page.format(page.battery, 0) + "%   " + page.format(page.number(page.latest.battery_V), 2) + " V"
                            font.pixelSize: 20 * uiScale
                            color: foreground
                            font.bold: true
                        }
                    }
                    Text {
                        text: page.sourceText + (page.latest.charging === true ? " · 充电中" : "")
                        color: muted
                        font.pixelSize: 15 * uiScale
                    }
                    Text {
                        width: parent.width
                        text: "电量计读数与供电来源分别判断；未接供电检测时显示未知，不推断为USB供电。"
                        wrapMode: Text.Wrap
                        font.pixelSize: 12 * uiScale
                        color: muted
                    }
                    Text {
                        width: parent.width
                        text: "低压保护：" + page.protectionText
                        wrapMode: Text.Wrap
                        font.pixelSize: 12 * uiScale
                        color: muted
                    }
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                font.pixelSize: 12 * uiScale
                color: muted
                text: "最后更新：" + (page.latest.received_at ? new Date(Number(page.latest.received_at)).toLocaleString(Qt.locale("zh_CN"), "MM-dd hh:mm:ss") : "尚未收到数据") + "   ·   本地采集，不依赖天气互联网服务"
            }
        }
    }
}
