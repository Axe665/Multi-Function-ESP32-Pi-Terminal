import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Material
import "components"

// 血压读数模块页面（模块自带 QML，由宿主独立引擎加载）。
//
// 可用注入项（宿主 ModulePageHost 每次加载新建 context 注入，直接用名字）：
//   appData      本模块数据接口（v3 名称；moduleData 是兼容别名，保留一个版本周期）
//                append / query / series / records / validateRecord / moduleId / ready
//   appAdvice    建议通道（setModuleId + request，异步回 adviceReady / adviceFailed）
//   appNetwork   异步 HTTP(S)：request -> finished(id, response)
//   appFiles     受控文件：request(op, args)，写权限需先 requestWriteAccess()
//   sessionModel 当前会话 / userContext 当前用户 / hostTheme 主题令牌
// 完整说明见 docs/AI-CODING-GUIDE.md 的「宿主能提供什么」。
//
// appData 是宿主注入的**当前用户**数据接口；本页不持有数据库、密钥或 SQL。
Rectangle {
    id: page
    property bool english: false

    // 宿主经 context 注入 hostTheme（含 scale）；页面不声明同名属性，
    // 否则会**遮蔽** context property（模块页拿到的永远是自己的默认值）。
    readonly property var theme: (typeof hostTheme !== "undefined" && hostTheme) ? hostTheme : ({})
    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1

    // 一次测量三个指标（报告 §12.1）：分开录入但存成一条记录。
    property string entrySys: ""
    property string entryDia: ""
    property string entryPulse: ""
    property string entryUnit: "mmHg"
    property string message: ""
    property var rows: []
    // 方案 §4.5：user-side 建议由宿主注入的 appAdvice 提供；
    // 模块页只拿“当前用户 + 本模块”的建议文本，接触不到数据库/IPC。
    property var adviceItems: []
    property string adviceStatus: ""
    property bool adviceBusy: false

    readonly property color background: theme.background || "#08121f"
    readonly property color surface: theme.surface || "#102238"
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
    readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
    readonly property color warn: "#fbbf24"
    readonly property real gap: 16 * uiScale

    readonly property bool hosted: typeof appData !== "undefined" && appData
    readonly property string statusKind: !hosted ? "empty"
        : appData.lastError ? "error" : (rows.length === 0 ? "empty" : "live")
    readonly property string statusText: !hosted ? "未连接宿主"
        : appData.lastError ? "数据接口错误"
        : rows.length === 0 ? "还没有读数" : ("已加载 " + rows.length + " 条")
    readonly property real hit: Math.max(48, 64 * uiScale)

    function reload() {
        if (typeof appData === "undefined" || !appData) { rows = []; return }
        rows = appData.query("measurement.blood_pressure", { limit: 100 })
    }

    function requestAdvice() {
        if (typeof appAdvice === "undefined" || !appAdvice) {
            page.adviceStatus = page.english ? "Advice service unavailable" : "建议服务不可用"
            return
        }
        if (!appAdvice.ready) {
            page.adviceStatus = page.english ? "Sign in to view advice" : "登录后可用"
            return
        }
        page.adviceBusy = true
        page.adviceStatus = ""
        // windowMs 只接受 5m/1h/24h；7 天是 HV 的基线口径，不是窗口本身。
        appAdvice.request({ record: "measurement.blood_pressure", windowMs: 86400000 })
    }

    Connections {
        target: (typeof appAdvice !== "undefined") ? appAdvice : null
        function onAdviceReady(requestId, payload) {
            page.adviceBusy = false
            // 方案 §4.5：payload = { items, source }。
            page.adviceItems = (payload && payload.items) ? payload.items : []
            if (page.adviceItems.length === 0)
                page.adviceStatus = page.english ? "No advice right now" : "暂无建议"
        }
        function onAdviceFailed(requestId, errorCode) {
            page.adviceBusy = false
            page.adviceStatus = String(errorCode || "")
        }
    }

    function sourceLabel(source) {
        const zh = { "user.entry": "手工录入", "device.auto": "设备自动",
                     "device.manual": "设备手动" }
        const en = { "user.entry": "Manual", "device.auto": "Device auto",
                     "device.manual": "Device manual" }
        const table = page.english ? en : zh
        return table[source] || (page.english ? "Unknown" : "来源未知")
    }

    function fieldLabel(field) {
        const zh = { systolic: "收缩压", diastolic: "舒张压", pulse: "脉搏",
                     unit: "单位", device_model: "型号", measured_at: "测量时间" }
        const en = { systolic: "systolic", diastolic: "diastolic", pulse: "pulse",
                     unit: "unit", device_model: "device model", measured_at: "measured at" }
        return (page.english ? en : zh)[field] || field
    }

    function schemaErrorText(code) {
        const raw = String(code || "")
        const sep = raw.indexOf(":")
        const name = sep >= 0 ? raw.substring(0, sep) : raw
        const field = sep >= 0 ? raw.substring(sep + 1) : ""
        const label = field.length > 0 ? page.fieldLabel(field) : ""
        switch (name) {
        case "SCHEMA_UNAVAILABLE":
            return page.english ? "Module data schema unavailable" : "模块数据格式不可用"
        case "SCHEMA_UNKNOWN_RECORD":
            return page.english ? "Record type is not declared in data_schema" : "记录类型未在 data_schema 声明"
        case "SCHEMA_RECORD_TOO_LARGE":
            return page.english ? "Record exceeds the size limit" : "记录超过单条大小限制"
        case "SCHEMA_UNKNOWN_FIELD":
            return page.english ? "Field " + label + " is not declared in data_schema"
                                : "字段 " + label + " 未在 data_schema 声明"
        case "SCHEMA_REQUIRED_MISSING":
            return page.english ? "Missing required field " + label : "缺少必填字段 " + label
        case "SCHEMA_TYPE_MISMATCH":
            return page.english ? "Field " + label + " has the wrong type" : "字段 " + label + " 类型不符"
        case "SCHEMA_OUT_OF_RANGE":
            return page.english ? "Field " + label + " is outside the allowed range" : "字段 " + label + " 超出 schema 范围"
        case "BUSY_BACKUP":
            return page.english ? "Backup in progress; try again shortly" : "正在备份，暂不能保存，请稍后重试"
        case "STORAGE_UNAVAILABLE":
            return page.english ? "Storage unavailable" : "数据存储不可用"
        default:
            return raw.length > 0 ? raw : (page.english ? "Save failed" : "保存失败")
        }
    }

    function invalidReasonText(reasons) {
        const zh = { systolic_out_of_range: "收缩压超出范围",
                     diastolic_out_of_range: "舒张压超出范围",
                     pulse_out_of_range: "脉搏超出范围",
                     systolic_not_above_diastolic: "收缩压不高于舒张压",
                     no_measurement: "没有有效读数" }
        const en = { systolic_out_of_range: "systolic out of range",
                     diastolic_out_of_range: "diastolic out of range",
                     pulse_out_of_range: "pulse out of range",
                     systolic_not_above_diastolic: "systolic not above diastolic",
                     no_measurement: "no measurement" }
        const table = page.english ? en : zh
        return reasons.map(function (reason) { return table[reason] || reason }).join("；")
    }

    function submit() {
        if (typeof appData === "undefined" || !appData) return
        // 至少填一项才允许保存；空表单不造记录。
        const sys = entrySys.trim(), dia = entryDia.trim(), pulse = entryPulse.trim()
        if (sys.length === 0 && dia.length === 0 && pulse.length === 0) {
            message = page.english ? "Enter at least one value" : "至少填写一项"
            return
        }
        // 只把填了的项交给宿主：缺失项保持 undefined，不补 0。
        const payload = { "unit": entryUnit, "source": "user.entry", "valid": true }
        if (sys.length > 0) payload.systolic = Number(sys)
        if (dia.length > 0) payload.diastolic = Number(dia)
        if (pulse.length > 0) payload.pulse = Number(pulse)
        // 收缩压必须高于舒张压：不成立的组合由模块侧判无效，这里先拦一道。
        if (payload.systolic !== undefined && payload.diastolic !== undefined
                && payload.systolic <= payload.diastolic) {
            message = page.english
                      ? "Systolic must be above diastolic" : "收缩压必须高于舒张压"
            return
        }

        // 与 C++ 侧一致的物理范围：越界读数不是"正常数据"，走旧接口保留
        // valid=false + invalid_reason 的审计记录，不交给 schema 拒绝。
        const problems = []
        if (payload.systolic !== undefined && (payload.systolic < 40 || payload.systolic > 300))
            problems.push("systolic_out_of_range")
        if (payload.diastolic !== undefined && (payload.diastolic < 20 || payload.diastolic > 200))
            problems.push("diastolic_out_of_range")
        if (payload.pulse !== undefined && (payload.pulse < 20 || payload.pulse > 250))
            problems.push("pulse_out_of_range")

        if (problems.length > 0) {
            payload.valid = false
            payload.invalid_reason = problems.join(",")
            // 越界读数不能进 data_schema（会被 SCHEMA_OUT_OF_RANGE 拒），
            // 这里走 moduleData 兼容别名保留 valid=false 的审计记录。
            const ok = moduleData.appendMeasurement(payload)
            if (!ok) {
                message = page.schemaErrorText(moduleData.lastError)
                return
            }
            entrySys = ""; entryDia = ""; entryPulse = ""
            message = (page.english ? "Recorded invalid reading: " : "已记录异常读数：")
                      + page.invalidReasonText(problems)
            reload()
            return
        }

        // 有效读数走 v3 API，才能看到 SCHEMA_* 具体原因。
        const result = appData.append("measurement.blood_pressure", payload)
        if (result && result.ok) {
            entrySys = ""; entryDia = ""; entryPulse = ""
            message = page.english ? "Saved" : "已保存"
            reload()
        } else {
            message = page.schemaErrorText(result && result.error ? result.error : appData.lastError)
        }
    }

    Component.onCompleted: reload()

    Connections {
        target: typeof appData !== "undefined" ? appData : null
        function onDataChanged() { page.reload() }
    }

    color: page.background
    Material.theme: Material.Dark
    Material.accent: page.accent
    Material.foreground: page.foreground

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: page.gap
        spacing: page.gap

        Item {
            Layout.fillWidth: true
            implicitHeight: Math.max(titleColumn.implicitHeight, statusBadge.implicitHeight)

            Column {
                id: titleColumn
                width: parent.width - statusBadge.implicitWidth - page.gap
                spacing: 4 * page.uiScale
                Text {
                    text: page.english ? "Blood pressure" : "血压读数"
                    color: page.foreground
                    font.pixelSize: 22 * page.uiScale
                    font.bold: true
                }
                Text {
                    text: page.english ? "Daily reference only; not for diagnosis"
                                      : "家庭日常参考，不作诊断依据"
                    color: page.muted
                    font.pixelSize: 12 * page.uiScale
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

        // ---- 手工录入 ----
        Text {
            text: page.english ? "Manual entry" : "手工录入"
            color: page.foreground
            font.pixelSize: 14 * page.uiScale
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: page.gap / 2
            TextField {
                id: sysField
                Layout.fillWidth: true
                Layout.preferredHeight: page.hit
                placeholderText: page.english ? "Systolic" : "收缩压"
                text: page.entrySys
                inputMethodHints: Qt.ImhDigitsOnly
                onTextChanged: page.entrySys = text
            }
            TextField {
                id: diaField
                Layout.fillWidth: true
                Layout.preferredHeight: page.hit
                placeholderText: page.english ? "Diastolic" : "舒张压"
                text: page.entryDia
                inputMethodHints: Qt.ImhDigitsOnly
                onTextChanged: page.entryDia = text
            }
            TextField {
                id: pulseField
                Layout.fillWidth: true
                Layout.preferredHeight: page.hit
                placeholderText: page.english ? "Pulse" : "脉搏"
                text: page.entryPulse
                inputMethodHints: Qt.ImhDigitsOnly
                onTextChanged: page.entryPulse = text
            }
            Button {
                Layout.preferredHeight: page.hit
                text: page.entryUnit
                onClicked: page.entryUnit = (page.entryUnit === "mmHg") ? "kPa" : "mmHg"
            }
            Button {
                Layout.preferredHeight: page.hit
                text: page.english ? "Save" : "保存"
                enabled: page.entrySys.length > 0 || page.entryDia.length > 0
                         || page.entryPulse.length > 0
                onClicked: page.submit()
            }
        }
        Text {
            Layout.fillWidth: true
            visible: page.message.length > 0
            text: page.message
            color: page.warn
            font.pixelSize: 12 * page.uiScale
            wrapMode: Text.Wrap
        }

        // ---- 读数列表 ----
        Text {
            text: page.english ? "Recent readings" : "最近读数"
            color: page.muted
            font.pixelSize: 14 * page.uiScale
        }
        Text {
            Layout.fillWidth: true
            visible: page.rows.length === 0
            text: page.english ? "No readings yet" : "还没有读数"
            color: page.muted
            font.pixelSize: 12 * page.uiScale
        }
        Repeater {
            model: page.rows
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredHeight: page.hit
                radius: 12 * page.uiScale
                color: page.surface
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: page.gap / 2
                    Text {
                        Layout.fillWidth: true
                        // 每个指标独立判断：缺失显示"—"，不写 0。
                        readonly property string unit: modelData.unit || ""
                        text: (modelData.systolic !== undefined ? String(modelData.systolic) : "—")
                              + "/" + (modelData.diastolic !== undefined ? String(modelData.diastolic) : "—")
                              + (modelData.pulse !== undefined ? "  ♥" + modelData.pulse : "")
                              + (unit.length > 0 ? "  " + unit : "")
                        color: modelData.valid ? page.foreground : page.warn
                        font.pixelSize: 14 * page.uiScale
                    }
                    Text {
                        text: page.sourceLabel(modelData.source)
                        color: page.muted
                        font.pixelSize: 12 * page.uiScale
                    }
                    Text {
                        visible: !modelData.valid
                        text: page.english ? "Invalid" : "无效"
                        color: page.warn
                        font.pixelSize: 12 * page.uiScale
                    }
                }
            }
        }

        // ---- 趋势建议（user-side）----
        Text {
            text: page.english ? "Trend advice" : "趋势建议"
            color: page.muted
            font.pixelSize: 14 * page.uiScale
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: page.gap / 2
            Button {
                Layout.preferredHeight: page.hit
                text: page.adviceBusy
                      ? (page.english ? "Loading…" : "获取中…")
                      : (page.english ? "Get advice" : "获取建议")
                enabled: !page.adviceBusy
                onClicked: page.requestAdvice()
            }
            Text {
                Layout.fillWidth: true
                visible: page.adviceStatus.length > 0
                text: page.adviceStatus
                color: page.warn
                font.pixelSize: 12 * page.uiScale
                wrapMode: Text.Wrap
            }
        }
        Repeater {
            model: page.adviceItems
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: adviceBody.implicitHeight + page.gap
                radius: 12 * page.uiScale
                color: page.surface
                Column {
                    id: adviceBody
                    anchors.fill: parent
                    anchors.margins: page.gap / 2
                    spacing: 4 * page.uiScale
                    Text {
                        width: parent.width
                        text: modelData.text || ""
                        color: page.foreground
                        font.pixelSize: 14 * page.uiScale
                        wrapMode: Text.Wrap
                    }
                    Text {
                        text: (page.english ? "risk " : "风险 ") + String(modelData.risk || "—")
                              + "  ·  " + (page.english ? "confidence " : "置信度 ")
                              + Math.round((modelData.confidence || 0) * 100) + "%"
                        color: page.muted
                        font.pixelSize: 12 * page.uiScale
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
