import QtQuick

// 趋势图：points 为 [{t, v, min, max}]，min/max 可省略。
// 缺测时段保持空白，不插值、不补造数据。
Canvas {
    id: chart
    property var theme: ({})
    property var points: []
    property string unit: ""
    property string emptyText: ""
    property double spanMs: 6 * 3600 * 1000
    property double endTime: NaN

    readonly property real uiScale: (theme.scale > 0) ? theme.scale : 1
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color grid: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)

    onPointsChanged: requestPaint()
    onSpanMsChanged: requestPaint()
    onEndTimeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onThemeChanged: requestPaint()

    onPaint: {
        const c = getContext("2d"); c.reset()
        const left = 52 * uiScale, right = width - 16 * uiScale
        const top = 12 * uiScale, bottom = height - 24 * uiScale
        if (right <= left || bottom <= top) return

        const span = Math.max(60000, spanMs)
        const end = isFinite(endTime) ? endTime : Date.now()
        const start = end - span
        let lo = Infinity, hi = -Infinity
        for (let i = 0; i < points.length; i++) {
            const p = points[i]
            lo = Math.min(lo, Number(p.min === undefined ? p.v : p.min))
            hi = Math.max(hi, Number(p.max === undefined ? p.v : p.max))
        }
        if (!isFinite(lo)) { lo = 0; hi = 1 }
        const pad = Math.max(0.5, (hi - lo) * 0.15); lo -= pad; hi += pad

        if (!points.length) {
            c.fillStyle = chart.muted; c.font = (14 * uiScale) + "px sans-serif"
            c.fillText(emptyText, 16 * uiScale, height / 2)
            return
        }

        function px(t) { return left + Math.max(0, Math.min(1, (Number(t) - start) / span)) * (right - left) }
        function py(v) { return bottom - (Number(v) - lo) / (hi - lo) * (bottom - top) }

        c.font = (11 * uiScale) + "px sans-serif"; c.lineWidth = 1
        for (let j = 0; j <= 3; j++) {
            const y = top + (bottom - top) * j / 3
            c.strokeStyle = chart.grid; c.beginPath(); c.moveTo(left, y); c.lineTo(right, y); c.stroke()
            c.fillStyle = chart.muted
            c.fillText((hi - (hi - lo) * j / 3).toFixed(1), 2, y + 4)
        }
        for (let j = 0; j <= 3; j++) {
            const t = start + span * j / 3, d = new Date(t)
            const label = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
            c.fillStyle = chart.muted
            c.fillText(label, Math.min(width - 36 * uiScale, Math.max(left, px(t) - 14 * uiScale)), height - 8)
        }

        c.save(); c.beginPath(); c.rect(left, top, right - left, bottom - top); c.clip()
        for (let i = 0; i < points.length; i++) {
            const p = points[i], x = px(p.t), y = py(p.v)
            if (p.min !== undefined && p.max !== undefined) {
                c.strokeStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.35); c.lineWidth = 5 * uiScale
                c.beginPath(); c.moveTo(x, py(p.min)); c.lineTo(x, py(p.max)); c.stroke()
            }
            if (i > 0) {
                const prev = points[i - 1]
                const gap = (span / Math.max(1, points.length - 1)) * 2.5
                if (Number(p.t) - Number(prev.t) <= gap) {
                    c.strokeStyle = accent; c.lineWidth = 2 * uiScale
                    c.beginPath(); c.moveTo(px(prev.t), py(prev.v)); c.lineTo(x, y); c.stroke()
                }
            }
            c.fillStyle = accent; c.beginPath(); c.arc(x, y, 2.5 * uiScale, 0, Math.PI * 2); c.fill()
        }
        c.restore()
    }
}
