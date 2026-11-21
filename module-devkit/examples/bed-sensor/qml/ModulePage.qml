import QtQuick
import QtQuick.Controls
import "components"

Rectangle {
    id: page
    implicitHeight: content.implicitHeight + 2 * gap
    radius: 18 * uiScale

    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || page.surface
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
    readonly property color bedSurface: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
    readonly property color warn: "#fbbf24"
    readonly property color error: "#f87171"
    readonly property real gap: 14 * uiScale

    readonly property bool hosted: typeof sessionModel !== "undefined" && sessionModel
    readonly property var demo: ({
        w: 62.4, x: 48, y: 92, bw: 150, bl: 200, em: 20, state: "in",
        out_ms: 0, in_ms: 5400000, mov: 0.35, evt: 1, event: "none",
        received_at: Date.now(), night: false, fault: 0
    })
    property var d: hosted ? (sessionModel.data || ({})) : page.demo
    property int lastSeq: -1
    property double clock: Date.now()
    property bool fresh: d.received_at !== undefined && clock - Number(d.received_at) < 5000
    property real bw: Math.max(1, Number(d.bw) || 150)
    property real bl: Math.max(1, Number(d.bl) || 200)
    property real weight: Number(d.w || 0)
    property real cx: d.x === undefined ? -1 : Number(d.x)
    property real cy: d.y === undefined ? -1 : Number(d.y)
    property string st: String(d.state || "out")
    property string cal: String(d.cal || "idle")
    property real edgeCm: Math.max(0, Number(d.em || 20))

    readonly property bool faulted: Number(d.fault || 0) !== 0
    readonly property string statusKind: !hosted ? "empty"
        : faulted ? "error"
        : d.received_at === undefined ? "loading"
        : fresh ? "live" : "stale"
    readonly property string statusText: !hosted ? "演示数据 · 未连接宿主"
        : faulted ? "称重通道异常"
        : d.received_at === undefined ? "等待数据"
        : fresh ? (d.night ? "夜间 · 实时" : "实时监测") : "数据已过期"

    // v3 数据接口与建议接口；离线/演示时按钮会提示未连接，不伪造成功。
    readonly property bool dbReady: typeof appData !== "undefined" && appData && appData.ready
    readonly property bool adviceReady: typeof appAdvice !== "undefined" && appAdvice && appAdvice.ready
    property string storeMessage: ""
    property string adviceMessage: ""
    property bool adviceBusy: false

    color: background

    ListModel { id: eventModel }

    function num(v) { return v === undefined || v === null || typeof v === "boolean" ? NaN : Number(v) }
    function stateLabel(s) {
        return ({ out: "离床", "in": "在床", edge: "靠床边" })[s] || s
    }
    function eventLabel(n) {
        return ({ enter: "上床", exit: "离床", turn: "翻身", sit: "坐起",
                  edge: "靠床边", no_return: "离床未返回" })[n] || n
    }
    function clockText(ms) {
        const t = new Date(ms)
        return Qt.formatTime(t, "HH:mm:ss")
    }
    function duration(ms) {
        const total = Math.max(0, Math.floor(Number(ms || 0) / 1000))
        const h = Math.floor(total / 3600)
        const m = Math.floor((total % 3600) / 60)
        const s = total % 60
        return (h > 0 ? h + ":" : "") +
               (m < 10 && h > 0 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
    }
    function calHint(c) {
        const kg = Number(d.cw || 0)
        const w = kg > 0 ? kg + " kg" : "标定砝码"
        return ({
            ch1: "把 " + w + " 放到床头左角（1 号）",
            ch2: "把 " + w + " 放到床头右角（2 号）",
            ch3: "把 " + w + " 放到床尾左角（3 号）",
            ch4: "把 " + w + " 放到床尾右角（4 号）",
            done: "四点标定完成，可以移走砝码",
            error: "标定失败，请检查砝码位置或接线"
        })[c] || ""
    }

    function capture() {
        if (typeof sessionModel === "undefined" || !sessionModel) return
        const v = sessionModel.data
        if (!v) return
        page.d = v
        const seq = Number(v.evt || 0)
        if (seq > page.lastSeq) {
            page.lastSeq = seq
            const name = String(v.event || "none")
            if (name !== "none") {
                eventModel.insert(0, { name: name, at: Date.now() })
                while (eventModel.count > 6) eventModel.remove(eventModel.count - 1)
            }
        }
    }

    // DB API：把当前读数显式落库（不自动每秒写入，避免把 1 Hz 遥测灌进历史表）。
    function persistSample() {
        if (!page.dbReady) { page.storeMessage = "未连接宿主数据接口"; return }
        const v = page.d
        if (!v || v.received_at === undefined) { page.storeMessage = "没有可保存的读数"; return }
        const fields = {
            state: String(v.state || ""),
            event: String(v.event || "none"),
            night: v.night === true,
            fault: page.num(v.fault) || 0
        }
        const w = page.num(v.w); if (isFinite(w)) fields.w = w
        const x = page.num(v.x); if (isFinite(x)) fields.x = x
        const y = page.num(v.y); if (isFinite(y)) fields.y = y
        const bw = page.num(v.bw); if (isFinite(bw)) fields.bw = bw
        const bl = page.num(v.bl); if (isFinite(bl)) fields.bl = bl
        const em = page.num(v.em); if (isFinite(em)) fields.em = em
        const outMs = page.num(v.out_ms); if (isFinite(outMs)) fields.out_ms = outMs
        const inMs = page.num(v.in_ms); if (isFinite(inMs)) fields.in_ms = inMs
        const mov = page.num(v.mov); if (isFinite(mov)) fields.mov = mov
        const evt = page.num(v.evt); if (isFinite(evt)) fields.evt = evt
        const receivedAt = page.num(v.received_at); if (isFinite(receivedAt)) fields.received_at = receivedAt
        const result = appData.append("sample.bed", fields)
        if (result && result.ok) page.storeMessage = "已保存本次读数"
        else page.storeMessage = "保存失败：" + (result && result.error ? result.error : (appData.lastError || "未知原因"))
    }

    // User-side API：建议按“当前用户 + 本模块”请求，不把用户身份带进模块。
    function requestAdvice() {
        if (!page.adviceReady) { page.adviceMessage = "登录后可查看睡眠建议"; return }
        if (page.adviceBusy) return
        page.adviceBusy = true
        page.adviceMessage = ""
        appAdvice.setModuleId(appData.moduleId)
        appAdvice.request({ record: "sample.bed", windowMs: 86400000 })
    }

    Component.onCompleted: page.capture()

    Connections {
        target: typeof sessionModel !== "undefined" ? sessionModel : null
        function onChanged() { page.capture() }
    }

    Connections {
        target: typeof appAdvice !== "undefined" ? appAdvice : null
        function onAdviceReady(requestId, payload) {
            page.adviceBusy = false
            const items = (payload && payload.items) ? payload.items : []
            page.adviceMessage = items.length > 0 ? items[0].text : "当前数据没有需要提醒的事项"
        }
        function onAdviceFailed(requestId, code) {
            page.adviceBusy = false
            page.adviceMessage = "建议生成失败：" + (code || "未知原因")
        }
    }

    Timer {
        interval: 1000
        running: page.visible
        repeat: true
        onTriggered: page.clock = Date.now()
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: content
            x: 20
            y: 20
            width: flick.width - 40
            spacing: 14

        Row {
            width: parent.width
            spacing: 12

            Column {
                width: parent.width - statusBadge.implicitWidth - 12 * page.uiScale
                spacing: 6 * page.uiScale
                Text {
                    text: "BED GUARDIAN / 床边守护"
                    color: page.muted
                    font.pixelSize: 12
                    font.letterSpacing: 1
                }
                Text {
                    text: "四点称重，看得见起身与离床"
                    color: page.foreground
                    font.pixelSize: 22
                    font.bold: true
                }
                Text {
                    text: "只输出重量、重心和事件；不测睡姿、不装摄像头。"
                    color: page.muted
                    font.pixelSize: 13
                }
            }

            StateBadge {
                id: statusBadge
                theme: page.theme
                kind: page.statusKind
                text: page.statusText
            }
        }

        Text {
            width: parent.width
            visible: Number(page.d.fault || 0) !== 0
            text: "有称重通道读数异常，重量和重心可能不准，请检查 HX711 接线。"
            color: page.error
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Row {
            width: parent.width
            spacing: 14

            Rectangle {
                width: 250
                height: 330
                radius: 18
                color: page.bedSurface
                border.color: page.line

                property real marginX: page.edgeCm / page.bw * width
                property real marginY: page.edgeCm / page.bl * height

                Rectangle {
                    x: 0; y: 0; width: parent.marginX; height: parent.height
                    color: page.accent; opacity: 0.18
                }
                Rectangle {
                    x: parent.width - parent.marginX; y: 0; width: parent.marginX; height: parent.height
                    color: page.accent; opacity: 0.18
                }
                Rectangle {
                    x: 0; y: 0; width: parent.width; height: parent.marginY
                    color: page.accent; opacity: 0.12
                }
                Rectangle {
                    x: 0; y: parent.height - parent.marginY; width: parent.width; height: parent.marginY
                    color: page.accent; opacity: 0.12
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 8
                    text: "床头"
                    color: page.muted
                    font.pixelSize: 12
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: "床尾"
                    color: page.muted
                    font.pixelSize: 12
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 8
                    text: "左"
                    color: page.muted
                    font.pixelSize: 12
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    text: "右"
                    color: page.muted
                    font.pixelSize: 12
                }

                Rectangle {
                    visible: page.weight > 0.5 && page.cx >= 0 && page.cy >= 0
                    width: 22
                    height: 22
                    radius: 11
                    color: page.warn
                    border.color: page.surface
                    border.width: 3
                    x: Math.max(0, Math.min(parent.width - width,
                                             page.cx / page.bw * parent.width - width / 2))
                    y: Math.max(0, Math.min(parent.height - height,
                                             page.cy / page.bl * parent.height - height / 2))
                }

                Text {
                    anchors.centerIn: parent
                    visible: page.weight <= 0.5
                    text: "床上无人"
                    color: page.muted
                    font.pixelSize: 15
                }
            }

            Column {
                width: parent.width - 264
                spacing: 10

                Row {
                    width: parent.width
                    spacing: 10

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 92
                        radius: 14
                        color: page.surface
                        border.color: page.line
                        Text {
                            x: 14; y: 10
                            text: "床上重量 · kg"
                            color: page.muted
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 30
                            text: page.weight.toFixed(1)
                            color: page.foreground
                            font.pixelSize: 34
                            font.bold: true
                        }
                    }

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 92
                        radius: 14
                        color: page.st === "out" ? Qt.rgba(0.98, 0.55, 0.25, 0.16)
                             : page.st === "edge" ? Qt.rgba(0.98, 0.75, 0.25, 0.16)
                             : Qt.rgba(0.29, 0.87, 0.50, 0.14)
                        border.color: page.line
                        Text {
                            x: 14; y: 10
                            text: "状态"
                            color: page.muted
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 34
                            text: page.stateLabel(page.st)
                            color: page.foreground
                            font.pixelSize: 26
                            font.bold: true
                        }
                        Text {
                            x: 14; y: 66
                            text: page.st === "out" ? "离床 " + page.duration(page.d.out_ms)
                                                    : "在床 " + page.duration(page.d.in_ms)
                            color: page.muted
                            font.pixelSize: 12
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 10

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 78
                        radius: 14
                        color: page.surface
                        border.color: page.line
                        Text {
                            x: 14; y: 8
                            text: "重心位置"
                            color: page.muted
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 28
                            text: page.weight > 0.5 && page.cx >= 0
                                  ? "左右 " + page.cx.toFixed(0) + " · 头脚 " + page.cy.toFixed(0) + " cm"
                                  : "--"
                            color: page.foreground
                            font.pixelSize: 15
                        }
                        Text {
                            x: 14; y: 52
                            text: "床宽 " + page.bw.toFixed(0) + " × 床长 " + page.bl.toFixed(0) + " cm"
                            color: page.muted
                            font.pixelSize: 11
                        }
                    }

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 78
                        radius: 14
                        color: page.surface
                        border.color: page.line
                        Text {
                            x: 14; y: 8
                            text: "体动强度"
                            color: page.muted
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 28
                            text: Number(page.d.mov || 0).toFixed(2) + " kg RMS"
                            color: page.foreground
                            font.pixelSize: 15
                        }
                        Rectangle {
                            x: 14; y: 54
                            width: parent.width - 28
                            height: 8
                            radius: 4
                            color: page.line
                            Rectangle {
                                width: parent.width * Math.min(1, Number(page.d.mov || 0) / 2)
                                height: parent.height
                                radius: 4
                                color: page.warn
                            }
                        }
                    }
                }

                Rectangle {
                    visible: page.cal !== "idle" && page.cal !== ""
                    width: parent.width
                    height: 46
                    radius: 12
                    color: page.cal === "error" ? Qt.rgba(0.97, 0.44, 0.44, 0.16)
                                                : Qt.rgba(0.98, 0.75, 0.25, 0.14)
                    Text {
                        anchors.fill: parent
                        anchors.margins: 10
                        verticalAlignment: Text.AlignVCenter
                        text: page.calHint(page.cal)
                        color: page.cal === "error" ? page.error : page.warn
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 176
                    radius: 14
                    color: page.surface
                    border.color: page.line

                    Text {
                        x: 14; y: 10
                        text: "最近事件"
                        color: page.muted
                        font.pixelSize: 12
                    }
                    Text {
                        x: 14; y: 30
                        visible: eventModel.count === 0
                        text: "暂无事件"
                        color: page.muted
                        font.pixelSize: 14
                    }
                    Column {
                        x: 14; y: 30
                        width: parent.width - 28
                        Repeater {
                            model: eventModel
                            delegate: Row {
                                required property string name
                                required property double at
                                width: parent.width
                                height: 24
                                spacing: 10
                                Text {
                                    width: 66
                                    text: page.clockText(at)
                                    color: page.muted
                                    font.pixelSize: 12
                                }
                                Text {
                                    text: page.eventLabel(name)
                                    color: page.foreground
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            width: parent.width
            height: recordColumn.implicitHeight + 24
            radius: 14
            color: page.surface
            border.color: page.line

            Column {
                id: recordColumn
                x: 14; y: 12; width: parent.width - 28; spacing: 8

                Row {
                    width: parent.width
                    spacing: 8

                    Text {
                        width: parent.width - saveButton.width - adviceButton.width - 16
                        height: 44
                        verticalAlignment: Text.AlignVCenter
                        text: "记录与建议"
                        color: page.foreground
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: saveButton
                        width: 104; height: 44; radius: 12
                        opacity: page.dbReady ? 1 : 0.45
                        color: Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.18)
                        border.width: 1
                        border.color: Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.55)
                        Text {
                            anchors.centerIn: parent
                            text: "保存读数"
                            color: page.foreground
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: page.dbReady
                            onClicked: page.persistSample()
                            Accessible.name: "保存本次床边读数"
                        }
                    }

                    Rectangle {
                        id: adviceButton
                        width: 104; height: 44; radius: 12
                        opacity: page.adviceReady ? 1 : 0.45
                        color: Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.18)
                        border.width: 1
                        border.color: Qt.rgba(page.accent.r, page.accent.g, page.accent.b, 0.55)
                        Text {
                            anchors.centerIn: parent
                            text: page.adviceBusy ? "生成中…" : "提建议"
                            color: page.foreground
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: page.adviceReady && !page.adviceBusy
                            onClicked: page.requestAdvice()
                            Accessible.name: "按最近24小时数据生成睡眠建议"
                        }
                    }
                }

                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                    color: page.adviceMessage !== "" || page.storeMessage !== "" ? page.foreground : page.muted
                    text: page.adviceMessage !== ""
                          ? page.adviceMessage
                          : page.storeMessage !== "" ? page.storeMessage
                          : page.dbReady || page.adviceReady
                            ? "保存当前读数，或按最近 24 小时数据生成睡眠建议。"
                            : "未连接宿主数据/建议接口。"
                }
            }
        }

        Text {
            width: parent.width
            text: "去皮 / 四点标定 / 复位校准：在功能页的模块动作里点击 tare、calibrate 或 reset。标定时按页面提示依次放砝码；标定和去皮都要求床面空载。"
            color: page.muted
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }
}
}
