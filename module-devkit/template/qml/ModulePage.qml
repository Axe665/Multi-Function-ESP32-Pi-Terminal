import QtQuick
import "components"

// 模块页面通用模板：结构与信息层级参照智能花盘（examples/smart-planter），
// 但**不写死任何颜色**——全部颜色来自宿主注入的 hostTheme，因此同一份页面
// 在浅色/深色主题下都成立，也不会和宿主主题打架。
//
// 宿主注入的上下文属性（直接按名字用，不要 import）：
//   hostTheme  {background, surface, foreground, accent, scale}  ← 只有这 5 个令牌
//   appData    模块数据入口（v3 名；moduleData 是兼容别名）
//   appAdvice  建议通道：setModuleId / request / history，异步回 adviceReady / adviceFailed
//   appNetwork 异步 HTTP(S)：request -> finished(id, response)
//   appFiles   受控文件：request(op, args)，写权限需先 requestWriteAccess()
//   sessionModel / userContext
//
// 改造步骤：
//   1. 改下面「模块配置」块里的 kicker / headline / heroNote / metrics；
//   2. 把 sampleRecord 换成你 manifest.json 里 data_schema.records 的真实记录名；
//   3. 需要主视觉时给 heroVisual 一个 Component（没有就用默认的几何占位）；
//   4. 数据点位、建议文案、风险等级都在这一层映射，不要改宿主注入的对象。
//
// 三条容易踩的坑：
//   - appData **没有** latest 属性，取最近一行要用 query(record, {limit:1})；
//   - 判断在线不能只看有没有数据（拔线后历史还在），要用 received_at 比时间；
//   - 建议是异步的：request 之后必须接 adviceReady / adviceFailed，否则永远停在 loading。
Rectangle {
    id: page

    // =========================================================== 主题令牌
    // 宿主只传 4 个色令牌 + 1 个缩放；卡片层次靠前景色低透明度叠加派生，
    // 不引入任何新颜色。兜底用全透明，不会污染主题。
    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property color cBackground: theme.background !== undefined ? theme.background : Qt.rgba(0, 0, 0, 0)
    readonly property color cSurface: theme.surface !== undefined ? theme.surface : Qt.rgba(0, 0, 0, 0)
    readonly property color cForeground: theme.foreground !== undefined ? theme.foreground : Qt.rgba(0, 0, 0, 0)
    readonly property color cAccent: theme.accent !== undefined ? theme.accent : Qt.rgba(0, 0, 0, 0)
    readonly property real u: theme.scale !== undefined ? theme.scale : 1

    // 低透明度叠层：前景色 → 卡片/分隔线/次级文字
    function veil(alpha) {
        return Qt.rgba(cForeground.r, cForeground.g, cForeground.b, alpha)
    }
    // 强调色叠层：状态胶囊、建议入口底色、主按钮
    function accentVeil(alpha) {
        return Qt.rgba(cAccent.r, cAccent.g, cAccent.b, alpha)
    }
    // 压暗：建议页背后的底，从背景色派生而不是写死黑色
    function shade(alpha) {
        return Qt.rgba(cBackground.r * 0.55, cBackground.g * 0.55, cBackground.b * 0.55, alpha)
    }

    color: cBackground

    // =========================================================== 模块配置
    // ↓↓↓ 新模块主要改这一段 ↓↓↓
    property string kicker: "MODULE / @MODULE_NAME@"
    property string headline: "一句话说明这个模块在观察什么"
    property string heroNote: "这里写这段数据的适用边界：测的是什么、不测什么、别据此推断什么。"
    property string heroCaption: "我的设备"

    // 必须与 manifest.json 的 data_schema.records 名字一致；写成未声明的名字会被静默丢弃。
    property string sampleRecord: "sample.demo"
    property string eventRecord: "event.module_ready"

    // 指标定义：key 对应记录字段名，unit 写单位，note 写这列数据的含义或局限。
    property var metrics: [
        { key: "value_a", label: "指标 A", unit: "", note: "这列数据从哪来" },
        { key: "value_b", label: "指标 B", unit: "", note: "采样周期、精度" },
        { key: "value_c", label: "指标 C", unit: "", note: "别据此推断的性质" }
    ]

    // 主视觉插槽：给一个 Component 就替换默认占位图形。
    property Component heroVisual: null

    // 趋势区：留空 trendField 即整块隐藏。series() 返回 [{t,v,min,max}]。
    property bool showTrend: true
    property string trendField: "value_a"
    property string trendUnit: ""
    property double trendSpanMs: 6 * 3600 * 1000
    property double trendStepMs: 15 * 60 * 1000

    // ↑↑↑ 到这里为止 ↑↑↑

    // =========================================================== 数据
    property var latest: ({})          // 最近一条 sample 记录
    property real lastSeenMs: 0
    property var trendPoints: []
    property double clock: Date.now()
    readonly property bool hosted: typeof appData !== "undefined" && appData
    readonly property bool demoMode: !hosted
    readonly property bool deviceOnline: lastSeenMs > 0 && (clock - lastSeenMs) < 15000
    readonly property bool dataReady: hosted && appData.ready
    readonly property bool schemaReady: hosted && appData.schemaReady
    readonly property string statusKind: !hosted ? "empty"
        : (appData.lastError ? "error" : "")
        || (!dataReady ? "loading" : "")
        || (!latest || latest.received_at === undefined ? "empty" : "")
        || (typeof sessionModel !== "undefined" && sessionModel
            && (sessionModel.online === false || sessionModel.connected === false) ? "offline" : "")
        || (deviceOnline ? "live" : "stale")
    readonly property string statusText: !hosted ? "演示数据 · 未连接宿主"
        : appData.lastError ? "数据接口错误"
        : !dataReady ? "等待宿主就绪"
        : !latest || latest.received_at === undefined ? "还没有读数"
        : (typeof sessionModel !== "undefined" && sessionModel
           && (sessionModel.online === false || sessionModel.connected === false)) ? "设备离线"
        : deviceOnline ? "实时监测中" : "数据已过期"

    function number(v) {
        return (v === null || v === undefined || typeof v === "boolean") ? NaN : Number(v)
    }
    function format(v, digits) {
        const n = number(v)
        return isFinite(n) ? n.toFixed(digits === undefined ? 1 : digits) : "--"
    }
    function receivedText() {
        const ms = latest && latest.received_at ? Number(latest.received_at) : 0
        return ms > 0 ? new Date(ms).toLocaleString(Qt.locale("zh_CN"), "MM-dd hh:mm:ss") : "尚未收到数据"
    }

    // 轮询最近一行。模块页没有推送机制，靠定时 query 取最新记录；
    // 间隔不要小于上报周期的 2 倍，否则只是空转。
    function refreshLatest() {
        if (!dataReady) return
        const rows = appData.query(sampleRecord, { limit: 1 })
        if (rows.length > 0) {
            latest = rows[0]
            lastSeenMs = Number(rows[0].received_at || 0)
        }
        refreshTrend()
    }

    function refreshTrend() {
        if (!dataReady || trendField === "") return
        trendPoints = appData.series(sampleRecord, trendField, trendSpanMs, trendStepMs)
    }

    // 脱离宿主单独打开时用演示数据，先验收布局；接上宿主后自动改用真实数据。
    function loadDemo() {
        latest = { value_a: 24.6, value_b: 61.2, value_c: 720, online: true, received_at: Date.now() }
        lastSeenMs = latest.received_at
        const out = [], end = Date.now(), step = 15 * 60000
        for (let i = 23; i >= 0; --i) {
            const v = 22 + 2.4 * Math.sin(i / 4)
            out.push({ t: end - i * step, v: v, min: v - 0.6, max: v + 0.6 })
        }
        trendPoints = out
    }

    Component.onCompleted: { if (demoMode) loadDemo() }

    Timer {
        interval: 3000
        repeat: true
        running: page.dataReady
        triggeredOnStart: true
        onTriggered: page.refreshLatest()
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: page.clock = Date.now()
    }

    // =========================================================== 建议
    property bool showAdvice: false
    property bool adviceShown: false
    property int slideDuration: 240
    property var adviceItems: []
    property string adviceStatus: ""     // "" | ready | NO_ADVICE | error | unavailable
    property string adviceSource: ""     // 建议来自哪条链路：local / api
    property bool adviceBusy: false

    readonly property bool adviceAvailable: typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready
    readonly property var currentAdvice: adviceItems.length > 0 ? adviceItems[0] : null

    function riskOf(item) {
        return (item && item.risk) ? item.risk : "normal"
    }
    function riskLabel(item) {
        const r = riskOf(item)
        return r === "alert" ? "需关注" : r === "watch" ? "留意" : "正常"
    }
    function sourceLabel() {
        if (adviceSource === "api") return "云端模型"
        if (adviceSource === "local") return "端侧规则/本地模型"
        return "依据最近 5 分钟数据"
    }
    function statusLine() {
        if (!adviceAvailable) return "宿主未连接"
        if (adviceStatus === "error") return "本次生成失败：" + (appAdvice.lastError || "未知原因")
        if (adviceStatus === "NO_ADVICE") return "数据不足，暂无建议"
        if (adviceBusy) return "生成中…"
        if (adviceItems.length > 0) return adviceItems.length + " 条 · " + sourceLabel()
        return "依据最近 5 分钟数据"
    }

    function openAdvice() {
        showAdvice = true
        adviceShown = true
        if (adviceAvailable && !adviceBusy) requestAdviceNow()
    }
    function closeAdvice() {
        showAdvice = false
    }
    function requestAdviceNow() {
        if (!adviceAvailable || adviceBusy) return
        adviceBusy = true
        adviceStatus = ""
        appAdvice.setModuleId(dataReady ? appData.moduleId : 0)
        // windowMs 只接受 300000 / 3600000 / 86400000 三档。
        appAdvice.request({ record: sampleRecord, windowMs: 300000 })
    }

    Connections {
        target: typeof appAdvice !== "undefined" ? appAdvice : null
        function onAdviceReady(requestId, payload) {
            page.adviceBusy = false
            page.adviceItems = (payload && payload.items) ? payload.items : []
            page.adviceSource = (payload && payload.source) ? payload.source : ""
            page.adviceStatus = page.adviceItems.length > 0 ? "ready" : "NO_ADVICE"
        }
        function onAdviceFailed(requestId, code) {
            page.adviceBusy = false
            page.adviceStatus = (code === "UNAVAILABLE") ? "unavailable" : "error"
        }
        function onStateChanged() {
            if (appAdvice && appAdvice.ready) appAdvice.loadHistory()
        }
    }

    // =========================================================== 首页
    Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.height + u * 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: content
            x: u * 20
            y: u * 20
            width: scroller.width - u * 40
            spacing: u * 16

            // ---- 建议入口：放在最上面，不点进去也能看到一句摘要 ----
            Rectangle {
                width: parent.width
                height: u * 68
                radius: u * 20
                color: accentVeil(0.12)
                border.width: u * 1
                border.color: accentVeil(0.28)

                // 叶子标记用几何形状画，不依赖图标字体或图片资源。
                Item {
                    x: u * 14
                    y: u * 14
                    width: u * 40
                    height: u * 40
                    Rectangle {
                        x: u * 7; y: u * 2
                        width: u * 24; height: u * 24; radius: u * 12
                        color: accentVeil(0.55)
                    }
                    Rectangle {
                        x: u * 7; y: u * 12
                        width: u * 24; height: u * 24; radius: u * 12
                        color: accentVeil(0.85)
                    }
                    Rectangle {
                        x: u * 18.5; y: u * 24
                        width: u * 3; height: u * 14; radius: u * 1.5
                        color: cBackground
                    }
                }

                Column {
                    x: u * 68
                    y: u * 12
                    spacing: u * 3
                    width: parent.width - u * 68 - statusChip.width - u * 44
                    Text {
                        text: "模块建议"
                        color: cForeground
                        font.pixelSize: u * 17
                        font.bold: true
                    }
                    Text {
                        width: parent.width
                        text: page.currentAdvice && page.currentAdvice.text
                              ? page.currentAdvice.text
                              : (page.adviceItems.length === 0 ? "查看本模块的建议与历史" : "")
                        color: veil(0.72)
                        font.pixelSize: u * 13
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }

                Rectangle {
                    id: statusChip
                    anchors.right: parent.right
                    anchors.rightMargin: u * 16
                    anchors.verticalCenter: parent.verticalCenter
                    height: u * 32
                    radius: u * 16
                    width: statusChipLabel.implicitWidth + u * 26
                    color: page.adviceBusy ? veil(0.12)
                                           : (page.currentAdvice && page.riskOf(page.currentAdvice) === "alert"
                                              ? accentVeil(0.42) : veil(0.10))
                    Text {
                        id: statusChipLabel
                        anchors.centerIn: parent
                        text: page.adviceBusy ? "生成中" : page.statusLine()
                        color: cForeground
                        font.pixelSize: u * 13
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.openAdvice()
                }
            }

            // ---- 标题行：小标签 + 大标题 + 在线状态胶囊 ----
            Row {
                width: parent.width
                spacing: u * 12

                Column {
                    width: parent.width - statusBadge.implicitWidth - u * 12
                    spacing: u * 5
                    Text {
                        text: page.kicker
                        color: cAccent
                        font.pixelSize: u * 12
                        font.letterSpacing: u * 1
                        font.capitalization: Font.AllUppercase
                    }
                    Text {
                        width: parent.width
                        text: page.headline
                        color: cForeground
                        font.pixelSize: u * 24
                        font.bold: true
                        wrapMode: Text.Wrap
                    }
                }

                StateBadge {
                    id: statusBadge
                    theme: page.theme
                    kind: page.statusKind
                    text: page.statusText
                }
            }

            // ---- Hero 卡：左侧主视觉插槽 + 右侧说明 ----
            Rectangle {
                width: parent.width
                height: width < u * 600 ? u * 235 : u * 212
                radius: u * 22
                color: cSurface
                border.width: u * 1
                border.color: veil(0.10)

                // 默认主视觉：同心圆 + 基线，替换 heroVisual 后自动让位。
                Item {
                    id: heroSlot
                    x: u * 8
                    y: u * 10
                    width: Math.min(parent.width * 0.32, u * 210)
                    height: parent.height - u * 20
                    visible: page.heroVisual !== null

                    Loader {
                        anchors.fill: parent
                        sourceComponent: page.heroVisual
                    }
                }

                Item {
                    id: heroPlaceholder
                    x: u * 8
                    y: u * 10
                    width: Math.min(parent.width * 0.32, u * 210)
                    height: parent.height - u * 20
                    visible: page.heroVisual === null

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.height * 0.62
                        height: width
                        radius: width / 2
                        color: Qt.rgba(0, 0, 0, 0)
                        border.width: u * 2
                        border.color: accentVeil(0.35)
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.height * 0.34
                        height: width
                        radius: width / 2
                        color: accentVeil(0.20)
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height * 0.5 + u * 24
                        width: parent.width * 0.6
                        height: u * 2
                        color: accentVeil(0.45)
                    }
                }

                Column {
                    x: heroSlot.x + heroSlot.width + u * 16
                    y: u * 22
                    width: parent.width - x - u * 18
                    spacing: u * 9

                    Text {
                        text: page.heroCaption
                        color: cForeground
                        font.pixelSize: u * 23
                        font.bold: true
                    }
                    Text {
                        text: page.heroNote
                        color: veil(0.80)
                        font.pixelSize: u * 16
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                    Rectangle {
                        width: parent.width
                        height: heroMeta.implicitHeight + u * 20
                        radius: u * 12
                        color: veil(0.07)
                        Text {
                            id: heroMeta
                            anchors.fill: parent
                            anchors.margins: u * 10
                            verticalAlignment: Text.AlignVCenter
                            text: "记录：" + page.sampleRecord
                                  + "   更新：" + page.receivedText()
                                  + "\n数据来自本机采集，不依赖互联网服务"
                            color: veil(0.72)
                            font.pixelSize: u * 12
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            // ---- 指标网格：宽屏 4 列、窄屏 2 列 ----
            Grid {
                id: metricGrid
                width: parent.width
                // 列数跟着指标数量走，避免「3 个指标却按 4 列排」时右边空一格。
                columns: Math.max(1, Math.min(page.metrics.length,
                                              width < u * 600 ? 2 : 4))
                spacing: u * 10

                Repeater {
                    model: page.metrics
                    delegate: MetricTile {
                        width: (metricGrid.width - (metricGrid.columns - 1) * metricGrid.spacing) / metricGrid.columns
                        height: u * 96
                        theme: page.theme
                        label: modelData.label
                        value: page.format(page.latest[modelData.key], 1)
                        unit: modelData.unit
                        note: modelData.note
                    }
                }
            }

            // ---- 趋势卡：trendField 为空时整块隐藏 ----
            Rectangle {
                visible: page.showTrend && page.trendField !== ""
                width: parent.width
                height: u * 250
                radius: u * 22
                color: cSurface
                border.width: u * 1
                border.color: veil(0.10)

                Column {
                    anchors.fill: parent
                    anchors.margins: u * 16
                    spacing: u * 8

                    Row {
                        width: parent.width
                        Text {
                            width: parent.width - spanLabel.implicitWidth
                            text: "最近趋势 · " + page.trendField
                            color: cForeground
                            font.pixelSize: u * 16
                            font.bold: true
                        }
                        Text {
                            id: spanLabel
                            text: page.trendSpanMs >= 86400000
                                  ? Math.round(page.trendSpanMs / 86400000) + " 天"
                                  : Math.round(page.trendSpanMs / 3600000) + " 小时"
                            color: veil(0.55)
                            font.pixelSize: u * 12
                        }
                    }

                    TrendChart {
                        width: parent.width
                        height: parent.height - u * 30
                        theme: page.theme
                        points: page.trendPoints
                        unit: page.trendUnit
                        spanMs: page.trendSpanMs
                        endTime: page.lastSeenMs
                        emptyText: "还没有趋势数据"
                    }
                }
            }

            // ---- 页脚：数据来源与局限 ----
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                font.pixelSize: u * 12
                color: veil(0.50)
                text: page.demoMode
                      ? "演示数据 · 未连接宿主；接入后改为 appData.query('" + page.sampleRecord + "')"
                      : page.schemaReady
                        ? "最后更新：" + page.receivedText()
                          + "   ·   记录名 " + page.sampleRecord + " 已在 data_schema 中声明"
                        : "宿主未就绪或 data_schema 未加载；检查 manifest.json 的 platform_api 与 data_schema 字段"
            }
        }
    }

    // =========================================================== 建议页（右侧滑入）
    // 整幅同色底盖住首页再整体平移；只滑一张卡片会让下面透出来。
    Rectangle {
        id: adviceSurface
        width: parent.width
        height: parent.height
        color: cBackground
        visible: page.adviceShown
        x: page.showAdvice ? 0 : page.width

        Behavior on x {
            NumberAnimation { duration: page.slideDuration; easing.type: Easing.OutCubic }
        }

        Column {
            x: u * 20
            y: u * 20
            width: parent.width - u * 40
            spacing: u * 14

            Row {
                width: parent.width
                spacing: u * 12

                Rectangle {
                    width: u * 48
                    height: u * 48
                    radius: u * 24
                    color: veil(0.10)
                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        font.pixelSize: u * 26
                        color: cForeground
                        anchors.verticalCenterOffset: -u * 1
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.closeAdvice()
                    }
                }

                Column {
                    width: parent.width - u * 48 - u * 12 - u * 118 - u * 12
                    height: u * 48
                    spacing: u * 2
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        text: "模块建议"
                        color: cForeground
                        font.pixelSize: u * 24
                        font.bold: true
                    }
                    Text {
                        width: parent.width
                        color: veil(0.62)
                        font.pixelSize: u * 12
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        text: page.statusLine()
                    }
                }

                Rectangle {
                    width: u * 118
                    height: u * 48
                    radius: u * 24
                    color: page.adviceBusy || !page.adviceAvailable ? veil(0.10) : cAccent
                    Text {
                        anchors.centerIn: parent
                        text: page.adviceBusy ? "生成中…" : "提建议"
                        color: page.adviceBusy || !page.adviceAvailable ? veil(0.55) : cBackground
                        font.pixelSize: u * 16
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: page.adviceAvailable && !page.adviceBusy
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: page.requestAdviceNow()
                    }
                }
            }

            // 当前建议：整页唯一的强对比块
            Rectangle {
                width: parent.width
                radius: u * 22
                color: accentVeil(0.16)
                border.width: u * 1
                border.color: accentVeil(0.30)
                height: currentInner.height + u * 36
                visible: page.currentAdvice !== null

                Column {
                    id: currentInner
                    x: u * 18
                    y: u * 18
                    width: parent.width - u * 36
                    spacing: u * 12

                    Row {
                        width: parent.width
                        spacing: u * 10
                        Text {
                            text: "当前建议"
                            color: cForeground
                            font.pixelSize: u * 20
                            font.bold: true
                            width: parent.width - riskChip.width - u * 10
                        }
                        Rectangle {
                            id: riskChip
                            height: u * 28
                            radius: u * 14
                            width: riskChipLabel.implicitWidth + u * 22
                            color: page.currentAdvice && page.riskOf(page.currentAdvice) === "alert"
                                   ? accentVeil(0.45) : veil(0.12)
                            Text {
                                id: riskChipLabel
                                anchors.centerIn: parent
                                text: page.riskLabel(page.currentAdvice)
                                color: cForeground
                                font.pixelSize: u * 12
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        text: page.currentAdvice && page.currentAdvice.text ? page.currentAdvice.text : ""
                        color: cForeground
                        font.pixelSize: u * 17
                        wrapMode: Text.Wrap
                        lineHeight: 1.35
                    }

                    Text {
                        width: parent.width
                        text: page.sourceLabel()
                        color: veil(0.60)
                        font.pixelSize: u * 12
                    }
                }
            }

            // 其余建议
            Repeater {
                model: page.adviceItems.length > 1 ? page.adviceItems.slice(1) : []
                delegate: Rectangle {
                    width: parent.width
                    radius: u * 16
                    color: veil(0.06)
                    height: itemText.implicitHeight + u * 28

                    Column {
                        x: u * 14
                        y: u * 14
                        width: parent.width - u * 28
                        spacing: u * 6
                        Text {
                            id: itemText
                            width: parent.width
                            text: modelData.text
                            color: cForeground
                            font.pixelSize: u * 15
                            wrapMode: Text.Wrap
                        }
                        Text {
                            text: page.riskLabel(modelData)
                            color: veil(0.55)
                            font.pixelSize: u * 12
                        }
                    }
                }
            }

            // 空态 / 错误态
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                font.pixelSize: u * 14
                color: veil(0.60)
                visible: page.adviceItems.length === 0 && !page.adviceBusy
                text: {
                    if (!page.adviceAvailable) return "宿主未连接建议通道。登录后可用。"
                    if (page.adviceStatus === "error") return "本次生成失败。云端不可用时，端侧会本地方案兜底；如果一直失败，检查数据是否足够。"
                    if (page.adviceStatus === "NO_ADVICE") return "最近这个时间窗内没有足够数据，先让设备上报一会儿。"
                    return "点右上角「提建议」生成。"
                }
            }
        }
    }
}
