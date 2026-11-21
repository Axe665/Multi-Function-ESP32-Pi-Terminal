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

    // 宿主注入的主题令牌；脱离宿主时用深色兜底。
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
    readonly property var latest: sessionModel ? sessionModel.data : ({})
    // 报告 §6.1：模块页通过宿主注入的 moduleData 接口读写**当前用户**的数据。
    // 这里不是直接访问数据库，而是语义化接口（无 SQL、无文件路径）。
    property var historyPoints: []
    property string storeMessage: ""

    // ---- 建议（方案 §4.5）----
    // 宿主注入的 appAdvice 负责“当前用户 + 本模块”的建议与历史；
    // 页面只做展示，不接触 user_id、数据库或 IPC。
    property bool showAdvice: false
    // 关闭时保留最后一帧，等滑出动画跑完再隐藏——与
    // pi_terminal/qml/RightSlidePage.qml 的 shown/parked 同一套做法。
    property bool adviceShown: false
    property int slideDuration: 240
    property var adviceItems: []
    property var historyItems: []
    property string adviceStatus: ""
    property bool adviceBusy: false

    function requestAdviceNow() {
        if (typeof appAdvice === "undefined" || !appAdvice) return
        adviceBusy = true
        adviceStatus = "refreshing"
        appAdvice.setModuleId(typeof appData !== "undefined" && appData ? appData.moduleId : 0)
        appAdvice.request({ record: "sample.environment", windowMs: 300000 })
        appAdvice.loadHistory()
    }
    function formatTime(ms) {
        if (!ms) return "--"
        return new Date(Number(ms)).toLocaleString(Qt.locale("zh_CN"), "MM-dd hh:mm")
    }
    function riskOf(item) {
        if (!item) return "normal"
        return item.risk === "alert" ? "alert" : item.risk === "watch" ? "watch" : "normal"
    }
    function riskText(risk) { return risk === "alert" ? "需关注" : risk === "watch" ? "留意" : "正常" }
    function alertCount() {
        let n = 0
        for (let i = 0; i < historyItems.length; ++i) if (riskOf(historyItems[i]) === "alert") ++n
        for (let j = 0; j < adviceItems.length; ++j) if (riskOf(adviceItems[j]) === "alert") ++n
        return n
    }
    // 入口条右侧的徽标只放“有信息量的数字”：有需关注就先说需关注，
    // 否则说条数，都没有才退回“查看”。不要放一个永远不变的箭头。
    function badgeText() {
        const n = alertCount()
        if (n > 0) return "需关注 " + n
        if (adviceItems.length > 0) return adviceItems.length + " 条建议"
        if (historyItems.length > 0) return historyItems.length + " 条记录"
        return "查看"
    }
    function summaryLine() {
        if (typeof appAdvice === "undefined" || !appAdvice) return "连接宿主后可查看端侧生成的养护建议"
        if (!appAdvice.ready) return "登录后可查看端侧生成的养护建议"
        if (adviceBusy || adviceStatus === "refreshing") return "正在根据最近 5 分钟环境数据生成建议…"
        if (adviceStatus === "error") return "生成失败：" + (appAdvice.lastError || "未知原因")
        const first = adviceItems.length > 0 ? adviceItems[0] : (historyItems.length > 0 ? historyItems[0] : null)
        if (first && first.text) return first.text
        return "当前没有需要提醒的异常，植物状态平稳"
    }
    function currentAdvice() { return adviceItems.length > 0 ? adviceItems[0] : null }
    function otherAdvices() {
        // 当前建议单独展示，剩下的作为「同批其它提示」。
        const out = []
        for (let i = 1; i < adviceItems.length; ++i) out.push(adviceItems[i])
        return out
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
        const result = appData.append("sample.environment", {
            "temperature_c": t,
            "humidity_rh": page.number(page.latest.humidity_RH),
            "light_lux": page.number(page.latest.light_lux),
            "source": "device.auto",
            "valid": true
        })
        if (result && result.ok) { storeMessage = ""; page.refreshHistory() }
        else storeMessage = "保存失败：" + (result && result.error ? result.error : (appData.lastError || "未知原因"))
    }

    Component.onCompleted: {
        refreshHistory()
        if (typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready) appAdvice.loadHistory()
    }

    Connections {
        target: typeof appData !== "undefined" ? appData : null
        function onDataChanged() { page.refreshHistory() }
    }
    readonly property bool fresh: latest.received_at !== undefined && clock - Number(latest.received_at) < 15000
    readonly property string statusKind: !latest || latest.received_at === undefined ? "loading"
        : latest.history_error ? "error" : (fresh ? "live" : "stale")
    readonly property string statusText: !latest || latest.received_at === undefined ? "等待新数据"
        : latest.history_error ? "历史读取失败" : (fresh ? "实时监测中" : "数据已过期")
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
    onShowAdviceChanged: {
        if (showAdvice) {
            adviceHideTimer.stop()
            adviceShown = true
        } else if (adviceShown) {
            adviceHideTimer.restart()
        }
    }
    Timer {
        id: adviceHideTimer
        interval: page.slideDuration + 20
        repeat: false
        onTriggered: if (!page.showAdvice) page.adviceShown = false
    }
    Material.theme: Material.Dark
    Material.accent: page.accent
    implicitHeight: Math.max(content.implicitHeight, adviceContent.implicitHeight) + 40
    color: page.background
    radius: 20
    function number(v) { return v === null || v === undefined || typeof v === "boolean" ? NaN : Number(v) }
    function format(v, d) { return isFinite(v) ? v.toFixed(d) : "--" }
    Timer { interval: 1000; running: page.visible; repeat: true; onTriggered: page.clock = Date.now() }

    // ===================================================== 首页
    Column {
        id: content
        x: 20; y: 20; width: parent.width - 40; spacing: 16

        // 建议入口：放在整页最上面。它本身带一句当前建议摘要，
        // 所以不点进去也能知道植物今天有没有状况。
        Rectangle {
            width: parent.width; height: 68; radius: 20; color: page.surface
            // 叶子标记：两个错位的圆构成叶片，和 hero 卡里的 PlantScene 同一套形状语言。
            Item {
                x: 14; y: 14; width: 40; height: 40
                Rectangle { x: 7; y: 2; width: 24; height: 24; radius: 12; color: page.accent }
                Rectangle { x: 7; y: 12; width: 24; height: 24; radius: 12; color: page.accent }
                Rectangle { x: 18.5; y: 24; width: 3; height: 14; radius: 1.5; color: page.muted }
            }
            Column {
                x: 68; y: 12; spacing: 3
                width: parent.width - 68 - badge.width - 44
                Text { text: "种植建议"; color: page.foreground; font.pixelSize: 17; font.bold: true }
                Text {
                    width: parent.width; text: page.summaryLine()
                    color: page.muted; font.pixelSize: 13
                    elide: Text.ElideRight; maximumLineCount: 1
                }
            }
            Rectangle {
                id: badge
                anchors.right: parent.right; anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                height: 32; radius: 16
                width: badgeLabel.implicitWidth + 26
                color: page.alertCount() > 0
                       ? Qt.rgba(page.error.r, page.error.g, page.error.b, 0.18)
                       : Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.10)
                Text {
                    id: badgeLabel
                    anchors.centerIn: parent
                    text: page.badgeText()
                    color: page.alertCount() > 0 ? page.error : page.foreground
                    font.pixelSize: 13
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    page.showAdvice = true
                    if (typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready)
                        page.requestAdviceNow()
                }
            }
        }

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
                        contentItem: Text { text: "一天"; color: !page.weekView ? "white" : page.foreground; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 24; color: !page.weekView ? page.accent : page.line }
                    }
                    Button { width: 98; height: 48; text: "一周"; onClicked: page.weekView = true; Accessible.name: "查看最近7天温度"
                        contentItem: Text { text: "一周"; color: page.weekView ? "white" : page.foreground; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 24; color: page.weekView ? page.accent : page.line }
                    }
                }
                TrendChart { width: parent.width; height: 186; theme: page.theme; points: page.points; weekView: page.weekView; endTime: page.number(page.latest.received_at) }
                Text { width: parent.width; wrapMode: Text.Wrap; color: page.muted; font.pixelSize: 12
                    text: page.weekView ? "最近7天 · 每2小时均值 / 淡色带为最低～最高 · 缺测不连线" : "最近24小时 · 每15分钟均值 / 淡色带为最低～最高 · 缺测不连线" }
                Text { width: parent.width; wrapMode: Text.Wrap; color: page.latest.history_error ? page.error : page.muted; font.pixelSize: 12
                    text: page.latest.history_error || ("已记录 " + page.points.length + " 个时段 · 历史保存在Pi，首次使用不会生成虚假日/周数据") }
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
    }

    // ===================================================== 建议页（右侧滑入）
    // 整幅同色底把首页完全盖住，再整体平移；只滑一块卡片会让下面透出来。
    Rectangle {
        id: adviceSurface
        width: parent.width; height: parent.height
        radius: page.radius
        color: page.background
        visible: page.adviceShown
        x: page.showAdvice ? 0 : page.width
        Behavior on x {
            NumberAnimation { duration: page.slideDuration; easing.type: Easing.OutCubic }
        }

        Column {
            id: adviceContent
            x: 20; y: 20; width: parent.width - 40; spacing: 14

        Row {
            width: parent.width; spacing: 12
            Rectangle {
                width: 48; height: 48; radius: 24; color: page.line
                Text { anchors.centerIn: parent; text: "‹"; font.pixelSize: 26; color: page.foreground; anchors.verticalCenterOffset: -1 }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.showAdvice = false }
            }
            Column {
                width: parent.width - 48 - 12 - 118 - 12; height: 48; spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Text { text: "种植建议"; color: page.foreground; font.pixelSize: 24; font.bold: true }
                Text {
                    width: parent.width; color: page.muted; font.pixelSize: 12
                    elide: Text.ElideRight; maximumLineCount: 1
                    text: typeof appAdvice === "undefined" || !appAdvice
                          ? "宿主未连接"
                          : !appAdvice.ready ? "登录后可用"
                          : "依据最近 5 分钟数据 · 端侧规则 + 本地模型"
                }
            }
            Button {
                id: adviceButton
                width: 118; height: 48
                enabled: typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready && !page.adviceBusy
                onClicked: page.requestAdviceNow()
                contentItem: Text {
                    text: page.adviceBusy ? "生成中…" : "提建议"
                    color: adviceButton.enabled ? "white" : page.muted
                    font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 24
                    color: adviceButton.enabled ? (adviceButton.pressed ? page.foreground : page.accent) : page.line
                }
            }
        }

        // 当前建议：与 hero 卡同一深绿，是整页唯一的强对比块。
        Rectangle {
            width: parent.width; radius: 22; color: page.surface
            height: currentInner.height + 36
            Column {
                id: currentInner
                x: 18; y: 18; width: parent.width - 36; spacing: 12
                Row {
                    width: parent.width; spacing: 10
                    Text {
                        text: "当前建议"; color: page.foreground; font.pixelSize: 20; font.bold: true
                        width: parent.width - riskChip.width - 10
                    }
                    Rectangle {
                        id: riskChip
                        visible: page.currentAdvice() !== null
                        height: 30; radius: 15; width: riskLabel.implicitWidth + 24
                        color: page.riskOf(page.currentAdvice()) === "alert" ? page.error
                             : page.riskOf(page.currentAdvice()) === "watch" ? page.warn : page.foreground
                        Text {
                            id: riskLabel; anchors.centerIn: parent
                            text: page.riskText(page.riskOf(page.currentAdvice()))
                            color: page.riskOf(page.currentAdvice()) === "alert" ? Qt.rgba(page.error.r, page.error.g, page.error.b, 0.18)
                                 : page.riskOf(page.currentAdvice()) === "watch" ? Qt.rgba(page.warn.r, page.warn.g, page.warn.b, 0.18) : page.muted
                            font.pixelSize: 13
                        }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap
                    color: page.foreground; font.pixelSize: 17; lineHeight: 1.25
                    text: {
                        if (page.adviceBusy) return "正在根据最近 5 分钟环境数据生成建议…"
                        const current = page.currentAdvice()
                        if (current && current.text) return current.text
                        if (page.adviceStatus === "NO_ADVICE") return "当前数据没有命中需要提醒的规则，植物状态平稳。"
                        if (page.historyItems.length > 0) return "本次未生成新建议；下方是已记录的 " + page.historyItems.length + " 条历史建议。"
                        return "还没有建议。点右上角「提建议」，端侧会按当前温湿度与光照生成一条。"
                    }
                }
                Row {
                    width: parent.width; spacing: 18
                    visible: page.currentAdvice() !== null
                    Text {
                        color: page.muted; font.pixelSize: 12
                        text: "置信度 " + page.format(page.number(page.currentAdvice() ? page.currentAdvice().confidence : NaN), 2)
                    }
                    Text {
                        color: page.muted; font.pixelSize: 12
                        text: "生成于 " + page.formatTime(page.currentAdvice() ? page.currentAdvice().generated_at : 0)
                    }
                }
                // 同批其它提示：不抢当前建议的位置，做安静的第二层。
                Repeater {
                    model: page.otherAdvices()
                    Rectangle {
                        width: parent.width; radius: 12; color: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
                        height: otherText.implicitHeight + 20
                        Rectangle {
                            x: 0; y: 10; width: 3; height: parent.height - 20; radius: 1.5
                            color: page.riskOf(modelData) === "alert" ? page.error
                                 : page.riskOf(modelData) === "watch" ? page.warn : page.accent
                        }
                        Text {
                            id: otherText
                            x: 14; y: 10; width: parent.width - 26; wrapMode: Text.Wrap
                            color: page.foreground; font.pixelSize: 14
                            text: modelData.text
                        }
                    }
                }
            }
        }

        // 历史汇总：先是统计，再是倒序明细。
        Rectangle {
            width: parent.width; radius: 20; color: page.surface; border.color: page.line
            height: historyInner.height + 28
            Column {
                id: historyInner
                x: 16; y: 14; width: parent.width - 32; spacing: 12
                Row {
                    width: parent.width; spacing: 10
                    Text { text: "历史建议"; color: page.foreground; font.pixelSize: 20; font.bold: true
                           width: parent.width - summaryRow.width - 10 }
                    Row {
                        id: summaryRow
                        spacing: 8
                        Rectangle {
                            height: 28; radius: 14; width: totalLabel.implicitWidth + 22; color: Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
                            Text { id: totalLabel; anchors.centerIn: parent; color: page.foreground; font.pixelSize: 12
                                   text: "共 " + page.historyItems.length + " 条" }
                        }
                        Rectangle {
                            height: 28; radius: 14; width: alertLabel.implicitWidth + 22
                            color: page.alertCount() > 0 ? Qt.rgba(page.error.r, page.error.g, page.error.b, 0.16) : Qt.rgba(page.foreground.r, page.foreground.g, page.foreground.b, 0.06)
                            Text { id: alertLabel; anchors.centerIn: parent; font.pixelSize: 12
                                   color: page.alertCount() > 0 ? page.error : page.foreground
                                   text: "需关注 " + page.alertCount() + " 条" }
                        }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: page.line }
                Repeater {
                    model: page.historyItems
                    Item {
                        width: parent.width
                        height: lineText.implicitHeight + metaRow.height + 14
                        Rectangle {
                            x: 0; y: 4; width: 3; height: parent.height - 10; radius: 1.5
                            color: page.riskOf(modelData) === "alert" ? page.error
                                 : page.riskOf(modelData) === "watch" ? page.warn : page.accent
                        }
                        Text {
                            id: lineText
                            x: 14; width: parent.width - 14
                            wrapMode: Text.Wrap; font.pixelSize: 14; color: page.foreground
                            lineHeight: 1.2
                            text: modelData.text
                        }
                        Item {
                            id: metaRow
                            x: 14; y: lineText.implicitHeight + 4
                            width: parent.width - 14; height: 18
                            Text {
                                anchors.left: parent.left
                                text: page.formatTime(modelData.generated_at)
                                color: page.muted; font.pixelSize: 12
                            }
                            Text {
                                anchors.right: parent.right
                                text: page.riskText(page.riskOf(modelData))
                                      + (modelData.confidence !== undefined ? "  ·  置信度 " + page.format(page.number(modelData.confidence), 2) : "")
                                color: page.riskOf(modelData) === "alert" ? page.error : page.muted
                                font.pixelSize: 12
                            }
                        }
                    }
                }
                Text {
                    width: parent.width; visible: page.historyItems.length === 0
                    wrapMode: Text.Wrap; font.pixelSize: 13; color: page.muted
                    text: "还没有历史建议。提建议之后，每一条都会记录在当前用户的加密库里，只在本模块可见。"
                }
            }
        }

        Text {
            width: parent.width; wrapMode: Text.Wrap; font.pixelSize: 12; color: page.muted
            text: "建议由端侧规则与本地模型生成，不联网；不同植物品种的最佳温湿度不同，请结合实际情况判断。"
        }
    }
    }
}
