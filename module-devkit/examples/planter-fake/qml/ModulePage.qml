import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import "components"

// 宿主注入的上下文属性（ModulePageHost 每次加载新建 context，直接用名字）：
//   appData      本模块数据接口（v3 名称；moduleData 是兼容别名，保留一个版本周期）
//   appAdvice    建议通道（setModuleId + request，异步回 adviceReady / adviceFailed）
//   appNetwork   异步 HTTP(S)：request -> finished(id, response)
//   appFiles     受控文件：request(op, args)，写权限需先 requestWriteAccess()
//   sessionModel 当前会话 / userContext 当前用户 / hostTheme 主题令牌
// 完整说明见 docs/AI-CODING-GUIDE.md 的「宿主能提供什么」。

Rectangle {
    id: page

    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || page.surface
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
    readonly property color warn: "#fbbf24"
    readonly property color error: "#f87171"

    property bool weekView: false
    property double clock: Date.now()
    // 演示模式：假数据由页面自己每 3 s 生成。
    // 模块 worker 是同步阻塞循环、没有 Qt 事件循环，模块里的 QTimer 不会触发，
    // 所以定时只能放在这一端（主引擎有事件循环）。
    property bool demoMode: true
    property var demo: ({})
    property var demoDayPoints: []
    property var demoWeekPoints: []
    readonly property var latest: demoMode && demo.received_at !== undefined
                                 ? demo
                                 : (sessionModel ? sessionModel.data : ({}))
    // 报告 §6.1：模块页通过宿主注入的 moduleData 接口读写**当前用户**的数据。
    // 这里不是直接访问数据库，而是语义化接口（无 SQL、无文件路径）。
    property var historyPoints: []
    property string storeMessage: ""
    property var adviceItems: []
    property var historyItems: []
    property string adviceStatus: ""
    property bool adviceBusy: false
    function requestAdviceNow() {
        if (typeof appAdvice === "undefined" || !appAdvice) return
        adviceBusy = true
        adviceStatus = "refreshing"
        appAdvice.request({ windowMs: 300000 })
        appAdvice.loadHistory()
    }
    function formatTime(ms) {
        if (!ms) return "--"
        return new Date(Number(ms)).toLocaleString(Qt.locale("zh_CN"), "MM-dd hh:mm")
    }
    Connections {
        target: typeof appAdvice !== "undefined" ? appAdvice : null
        function onAdviceReady(requestId, payload) {
            page.adviceBusy = false
            page.adviceItems = (payload && payload.items) ? payload.items : []
            page.adviceStatus = page.adviceItems.length > 0 ? "ready" : "NO_ADVICE"
        }
        function onAdviceFailed(requestId, code) {
            page.adviceBusy = false
            page.adviceStatus = "error"
        }
        function onHistoryChanged() {
            page.historyItems = appAdvice ? appAdvice.history : []
        }
        function onStateChanged() {
            if (appAdvice && appAdvice.ready) appAdvice.loadHistory()
        }
    }

    function refreshHistory() {
        if (typeof appData === "undefined" || !appData) return
        historyPoints = appData.series("sample.environment", "temperature_c", 7 * 24 * 3600 * 1000, 60 * 60 * 1000)
    }

    // 把当前读数落库（去重由 source 与时间保证）。
    function persistReading() {
        if (typeof appData === "undefined" || !appData) return
        const t = page.number(page.latest.temperature_C)
        if (!isFinite(t)) return
        const ok = appData.append("sample.environment", {
            "temperature_c": t,
            "humidity_rh": page.number(page.latest.humidity_RH),
            "light_lux": page.number(page.latest.light_lux)
        })
        if (!ok) storeMessage = "数据存储不可用"
        else { storeMessage = ""; page.refreshHistory() }
    }

    Component.onCompleted: {
        if (demoMode) seedDemo()
        refreshHistory()
        if (typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready) appAdvice.loadHistory()
    }

    Connections {
        target: typeof appData !== "undefined" ? appData : null
        function onDataChanged() { page.refreshHistory() }
    }
    readonly property bool fresh: latest.received_at !== undefined && clock - Number(latest.received_at) < 15000
    readonly property string statusKind: !latest || latest.received_at === undefined ? "loading" : (fresh ? "live" : "stale")
    readonly property string statusText: !latest || latest.received_at === undefined ? "等待新数据" : (fresh ? "实时监测中" : "数据已过期")
    readonly property real temperature: number(latest.temperature_C)
    readonly property real humidity: number(latest.humidity_RH)
    readonly property real light: number(latest.light_lux)
    readonly property real battery: number(latest.battery_pct)
    readonly property bool external: latest.external_power === true
    readonly property string source: latest.power_source || "unknown"
    readonly property string sourceText: external ? "外部供电" : source === "battery" ? "电池供电" : "供电来源待检测"
    readonly property string lightText: !isFinite(light) ? "等待光照数据" : light < 50 ? "光线偏暗 · 可移近窗边" : light < 150 ? "光线较弱 · 留意植物需求" : light < 1000 ? "散射光环境 · 按品种调整" : "光线较强 · 留意暴晒"
    readonly property var points: (weekView ? latest.history_week : latest.history_day) || []
    readonly property string protectionText: {
        const s = latest.power_protection || ""
        if (s === "source_unknown_auto_sleep_inhibited") return "未接供电检测，自动休眠未启用（需硬件电池保护）"
        if (s === "external_supply_no_low_battery_shutdown") return "外部供电有效，不因低电量关机"
        if (s === "battery_low_warning") return "电池低压警告，持续低压后安全休眠"
        if (s === "battery_guard_active") return "电池保护已启用，低于3.40V持续20秒后休眠"
        return "等待固件状态"
    }
    Material.theme: Material.Dark
    Material.accent: page.accent
    implicitHeight: content.height + 40
    color: page.background
    radius: 20
    function number(v) { return v === null || v === undefined || typeof v === "boolean" ? NaN : Number(v) }
    function format(v, d) { return isFinite(v) ? v.toFixed(d) : "--" }

    // ------------------------------------------------ 演示数据
    // 平滑随机游走：每次只移动一小步并夹在区间内，读数看起来像真实传感器。
    function drift(v, step, lo, hi) {
        return Math.max(lo, Math.min(hi, v + (Math.random() - 0.5) * 2 * step))
    }
    // 把最新温度并进对应时间桶；返回**新数组**，否则属性变化不会通知到绑定。
    function withBucket(source, now, bucketMs, value, keep) {
        const out = source.slice()
        const t = Math.floor(now / bucketMs) * bucketMs
        const last = out.length ? out[out.length - 1] : null
        if (last && Number(last.t) === t) {
            out[out.length - 1] = {
                t: t, v: (Number(last.v) * 3 + value) / 4,
                min: Math.min(Number(last.min), value),
                max: Math.max(Number(last.max), value)
            }
        } else {
            out.push({ t: t, v: value, min: value - 0.5, max: value + 0.5 })
        }
        while (out.length > keep) out.shift()
        return out
    }
    function seedDemo() {
        const now = Date.now()
        const day = []
        for (let i = 95; i >= 0; i--) {
            const t = Math.floor((now - i * 15 * 60000) / 900000) * 900000
            const v = 24.6 + 2.4 * Math.sin(t / 86400000 * Math.PI * 2 - 1.2) + (Math.random() - 0.5) * 0.4
            day.push({ t: t, v: v, min: v - 0.6, max: v + 0.6 })
        }
        const week = []
        for (let i = 83; i >= 0; i--) {
            const t = Math.floor((now - i * 120 * 60000) / 7200000) * 7200000
            const v = 24.6 + 2.4 * Math.sin(t / 86400000 * Math.PI * 2 - 1.2) + (Math.random() - 0.5) * 0.8
            week.push({ t: t, v: v, min: v - 1.2, max: v + 1.2 })
        }
        page.demoDayPoints = day
        page.demoWeekPoints = week
        page.stepDemo()
    }
    function stepDemo() {
        const now = Date.now()
        const prev = page.demo || {}
        const prevNum = function (key, fallback) {
            const v = prev[key]
            return (typeof v === "number" && isFinite(v)) ? v : fallback
        }
        const temperature = page.drift(prevNum("temperature_C", 24.6), 0.15, 19, 31)
        const humidity = page.drift(prevNum("humidity_RH", 58.2), 0.8, 35, 85)
        const light = page.drift(prevNum("light_lux", 420), 22, 5, 1500)
        const pressure = page.drift(prevNum("pressure_hPa", 1013.2), 0.25, 995, 1035)
        const battery = page.drift(prevNum("battery_pct", 87), 0.15, 0, 100)
        page.demoDayPoints = page.withBucket(page.demoDayPoints, now, 15 * 60000, temperature, 97)
        page.demoWeekPoints = page.withBucket(page.demoWeekPoints, now, 120 * 60000, temperature, 85)
        page.demo = {
            temperature_C: temperature,
            humidity_RH: humidity,
            light_lux: light,
            pressure_hPa: pressure,
            battery_pct: Math.round(battery),
            battery_V: 3.7 + (battery - 50) / 100 * 0.5,
            external_power: false,
            power_source: "battery",
            power_protection: "battery_guard_active",
            charging: false,
            received_at: now,
            history_day: page.demoDayPoints,
            history_week: page.demoWeekPoints
        }
    }

    Timer { interval: 1000; running: page.visible; repeat: true; onTriggered: page.clock = Date.now() }
    Timer {
        interval: 3000; repeat: true
        running: page.demoMode && page.visible
        onTriggered: page.stepDemo()
    }
    Column {
        id: content
        x: 20; y: 20; width: parent.width - 40; spacing: 16
        Row {
            width: parent.width; spacing: 12
            Column {
                width: parent.width - statusBadge.implicitWidth - 12; spacing: 5
                Text { text: "PLANT COMPANION / 植物环境助手"; color: page.muted; font.pixelSize: 12; font.letterSpacing: 1 }
                Text { text: "让每一片叶子，都有好环境"; color: page.foreground; font.pixelSize: 24; font.bold: true; width: parent.width; wrapMode: Text.Wrap }
            }
            StateBadge {
                id: statusBadge
                theme: page.theme
                kind: page.statusKind
                text: page.statusText
            }
        }
        Rectangle {
            width: parent.width; height: width < 600 ? 235 : 212; radius: 22; color: page.surface
            PlantScene { width: Math.min(parent.width * 0.32, 210); height: 190; x: 8; y: 10 }
            Column {
                x: Math.min(parent.width * 0.32, 210) + 16; y: 22; width: parent.width - x - 18; spacing: 9
                Text { text: "我的植物小站"; font.pixelSize: 23; font.bold: true; color: page.foreground }
                Text { text: page.lightText; font.pixelSize: 16; color: page.foreground; width: parent.width; wrapMode: Text.Wrap }
                Text { text: "环境建议仅供参考，最佳温湿度与光照因植物品种而异。"; font.pixelSize: 13; color: page.muted; width: parent.width; wrapMode: Text.Wrap }
                Rectangle {
                    width: parent.width; height: page.width < 600 ? 75 : 53; radius: 12; color: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
                    Text { anchors.fill: parent; anchors.margins: 10; verticalAlignment: Text.AlignVCenter
                        text: "BME280 空气温湿度  ·  BH1750 光照\n未接土壤湿度探头，不提供土壤读数或自动浇水"; color: page.muted; font.pixelSize: 12; wrapMode: Text.Wrap }
                }
            }
        }
        Grid {
            id: metricGrid
            width: parent.width; columns: width < 600 ? 2 : 4; spacing: 10
            Repeater {
                model: [
                    { label: "空气温度", value: page.format(page.temperature, 1), unit: "°C", note: "观察昼夜温差", kind: "temperature", tint: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06) },
                    { label: "空气湿度", value: page.format(page.humidity, 1), unit: "%RH", note: "非土壤含水率", kind: "humidity", tint: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06) },
                    { label: "环境光照", value: page.format(page.light, 0), unit: "lux", note: "照度不等于光合辐射", kind: "light", tint: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06) },
                    { label: "大气压力", value: page.format(page.number(page.latest.pressure_hPa), 1), unit: "hPa", note: "记录环境变化", kind: "pressure", tint: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06) }
                ]
                MetricTile { required property var modelData; width: (metricGrid.width - (metricGrid.columns - 1) * metricGrid.spacing) / metricGrid.columns; theme: page.theme; metric: modelData }
            }
        }
        Rectangle {
            width: parent.width; height: 320; radius: 20; color: page.surface; border.color: page.line
            Column {
                x: 16; y: 14; width: parent.width - 32; spacing: 8
                Row {
                    width: parent.width; spacing: 8
                    Text { width: parent.width - 212; height: 48; verticalAlignment: Text.AlignVCenter; text: "温度生长日记"; color: page.foreground; font.pixelSize: 20; font.bold: true }
                    Button { width: 98; height: 48; text: "一天"; onClicked: page.weekView = false; Accessible.name: "查看最近24小时温度"
                        contentItem: Text { text: "一天"; color: page.foreground; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 24; color: !page.weekView ? Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.30) : page.line }
                    }
                    Button { width: 98; height: 48; text: "一周"; onClicked: page.weekView = true; Accessible.name: "查看最近7天温度"
                        contentItem: Text { text: "一周"; color: page.foreground; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 24; color: page.weekView ? Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.30) : page.line }
                    }
                }
                TrendChart { width: parent.width; height: 186; theme: page.theme; points: page.points; weekView: page.weekView; endTime: page.number(page.latest.received_at) }
                Text { width: parent.width; wrapMode: Text.Wrap; color: page.muted; font.pixelSize: 12
                    text: page.weekView ? "最近7天 · 每2小时均值 / 淡色带为最低～最高 · 缺测不连线" : "最近24小时 · 每15分钟均值 / 淡色带为最低～最高 · 缺测不连线" }
                Text { width: parent.width; wrapMode: Text.Wrap; color: page.latest.history_error ? page.error : page.muted; font.pixelSize: 12
                    text: page.latest.history_error
                          || (page.demoMode
                              ? "演示数据 · 每 3 秒刷新，曲线由页面本地生成"
                              : "已记录 " + page.points.length + " 个时段 · 历史保存在Pi，首次使用不会生成虚假日/周数据") }
            }
        }
        Rectangle {
            width: parent.width; height: width < 600 ? 176 : 150; radius: 20; color: page.surface; border.color: page.line
            Column {
                x: 16; y: 14; width: parent.width - 32; spacing: 9
                Row {
                    spacing: 12
                    Rectangle {
                        width: 56; height: 30; radius: 5; color: "transparent"; border.width: 2; border.color: page.muted
                        Rectangle { x: 4; y: 4; height: 22; width: isFinite(page.battery) ? 48 * Math.max(0, Math.min(100, page.battery)) / 100 : 0; radius: 2; color: page.battery < 20 ? page.error : page.accent }
                    }
                    Text { text: "电量 " + page.format(page.battery, 0) + "%   " + page.format(page.number(page.latest.battery_V), 2) + " V"; font.pixelSize: 20; color: page.foreground; font.bold: true }
                }
                Text { text: page.sourceText + (page.latest.charging === true ? " · 充电中" : ""); color: page.muted; font.pixelSize: 15 }
                Text { width: parent.width; text: "电量计读数与供电来源分别判断；未接供电检测时显示未知，不推断为USB供电。"; wrapMode: Text.Wrap; font.pixelSize: 12; color: page.muted }
                Text { width: parent.width; text: "低压保护：" + page.protectionText; wrapMode: Text.Wrap; font.pixelSize: 12; color: page.muted }
            }
        }
        Text {
            width: parent.width; wrapMode: Text.Wrap; font.pixelSize: 12; color: page.muted
            text: "最后更新：" + (page.latest.received_at ? new Date(Number(page.latest.received_at)).toLocaleString(Qt.locale("zh_CN"), "MM-dd hh:mm:ss") : "尚未收到数据") + "   ·   本地采集，不依赖天气互联网服务"
        }

        // ------------------------------------------------ 建议（当前 + 历史）
        // 与真模块页同一套卡片语言：hostTheme 深色底、前景色描边、20 圆角、强调色主按钮。
        Rectangle {
            width: parent.width; radius: 20; color: page.surface; border.color: page.line
            height: adviceColumn.childrenRect.height + 28
            Column {
                id: adviceColumn
                x: 16; y: 14; width: parent.width - 32; spacing: 10
                Row {
                    width: parent.width; spacing: 10
                    Text {
                        width: parent.width - (typeof appAdvice !== "undefined" && appAdvice
                                               ? adviceButton.width + 12 : 0)
                        height: 48; verticalAlignment: Text.AlignVCenter
                        text: "植物健康建议"; color: page.foreground; font.pixelSize: 20; font.bold: true
                    }
                    Button {
                        id: adviceButton
                        width: 118; height: 48; enabled: typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready
                        text: page.adviceBusy ? "生成中…" : "提建议"
                        onClicked: page.requestAdviceNow()
                        contentItem: Text {
                            text: adviceButton.text; color: adviceButton.enabled ? "white" : page.muted
                            font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: 24
                            color: adviceButton.enabled ? (adviceButton.pressed ? page.foreground : page.accent) : page.line
                        }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap; font.pixelSize: 13; color: page.muted
                    text: typeof appAdvice === "undefined" || !appAdvice
                          ? "建议功能不可用（宿主未连接）"
                          : !appAdvice.ready ? "登录并连接 HyperVisor 后可提建议"
                          : (page.adviceStatus === "refreshing" ? "正在根据最近 5 分钟数据生成建议…"
                             : page.adviceStatus === "NO_ADVICE" ? "当前数据没有命中建议规则，继续保持观察"
                             : page.adviceStatus === "error" ? "生成失败：" + appAdvice.lastError
                             : "依据最近 5 分钟环境数据，由端侧规则与本地模型生成")
                }
                Repeater {
                    model: page.adviceItems
                    Rectangle {
                        width: parent.width; radius: 12
                        height: adviceText.implicitHeight + 16
                        color: modelData.risk === "alert" ? Qt.rgba(page.error.r, page.error.g, page.error.b, 0.16)
                             : modelData.risk === "watch" ? Qt.rgba(page.warn.r, page.warn.g, page.warn.b, 0.18) : Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
                        Text {
                            id: adviceText
                            x: 12; y: 8; width: parent.width - 24
                            wrapMode: Text.Wrap; font.pixelSize: 15; color: page.foreground
                            text: modelData.text
                        }
                    }
                }
                Rectangle {
                    width: parent.width; height: 1; color: page.line
                    visible: page.historyItems.length > 0
                }
                Text {
                    width: parent.width; visible: page.historyItems.length > 0
                    text: "建议历史"; color: page.foreground; font.pixelSize: 16; font.bold: true
                }
                Repeater {
                    model: page.historyItems
                    Item {
                        width: parent.width
                        height: historyText.implicitHeight + historyMeta.implicitHeight + 10
                        Text {
                            id: historyText
                            width: parent.width; wrapMode: Text.Wrap
                            font.pixelSize: 14; color: page.foreground
                            text: modelData.text
                        }
                        Text {
                            id: historyMeta
                            y: historyText.implicitHeight + 4
                            width: parent.width; font.pixelSize: 12; color: page.muted
                            text: page.formatTime(modelData.generated_at) + "  ·  "
                                  + (modelData.risk === "alert" ? "需关注" : modelData.risk === "watch" ? "观察" : "正常")
                                  + "  ·  置信度 " + page.format(modelData.confidence, 2)
                        }
                    }
                }
                Text {
                    width: parent.width; visible: page.historyItems.length === 0
                    wrapMode: Text.Wrap; font.pixelSize: 13; color: page.muted
                    text: "还没有历史建议；点击「提建议」后会记录在这里。"
                }
            }
        }

    }
}
