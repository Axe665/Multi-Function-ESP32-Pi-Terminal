import QtQuick

// 趋势图：points 为 [{t,v,min,max}]；颜色来自宿主 hostTheme。
Canvas {
    id: chart
    property var theme: ({})
    property var points: []
    property bool weekView: false
    property double endTime: NaN

    readonly property real u: (theme.scale > 0) ? theme.scale : 1
    readonly property color foreground: theme.foreground || "#ffffff"
    readonly property color accent: theme.accent || "#85deff"
    readonly property color grid: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)

    onPointsChanged: requestPaint()
    onWeekViewChanged: requestPaint()
    onEndTimeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onThemeChanged: requestPaint()

    onPaint: {
        const c = getContext("2d"); c.reset()
        const left = 42 * u, right = width - 16 * u, top = 16 * u, bottom = height - 28 * u
        const span = (weekView ? 7 : 1) * 86400000, step = (weekView ? 120 : 15) * 60000
        const end = isFinite(endTime) ? endTime : Date.now(), start = end - span
        let lo = Infinity, hi = -Infinity
        for (let i = 0; i < points.length; i++) { lo = Math.min(lo, Number(points[i].min)); hi = Math.max(hi, Number(points[i].max)) }
        if (!isFinite(lo)) { lo = 15; hi = 35 }
        const pad = Math.max(1, (hi - lo) * 0.15); lo -= pad; hi += pad
        function px(t) { return left + Math.max(0, Math.min(1, (t - start) / span)) * (right - left) }
        function py(v) { return bottom - (v - lo) / (hi - lo) * (bottom - top) }
        c.font = (11 * u) + "px sans-serif"; c.lineWidth = u
        for (let j = 0; j <= 3; j++) {
            const y = top + (bottom - top) * j / 3
            c.strokeStyle = chart.grid; c.beginPath(); c.moveTo(left, y); c.lineTo(right, y); c.stroke()
            c.fillStyle = chart.muted; c.fillText((hi - (hi - lo) * j / 3).toFixed(1) + "°", 0, y + 4)
        }
        for (let j = 0; j <= 4; j++) {
            const t = start + span * j / 4, d = new Date(t)
            const label = weekView ? ((d.getMonth() + 1) + "/" + d.getDate()) : (String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"))
            c.fillStyle = chart.muted; c.fillText(label, Math.min(width - 40 * u, Math.max(left, px(t) - 14 * u)), height - 7 * u)
        }
        c.save(); c.beginPath(); c.rect(left, top, right - left, bottom - top); c.clip()
        for (let i = 0; i < points.length; i++) {
            const p = points[i], x = px(Number(p.t)), y = py(Number(p.v))
            c.strokeStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.35); c.lineWidth = 5 * u
            c.beginPath(); c.moveTo(x, py(Number(p.min))); c.lineTo(x, py(Number(p.max))); c.stroke()
            if (i > 0 && Number(p.t) - Number(points[i - 1].t) <= step * 1.5) {
                c.strokeStyle = accent; c.lineWidth = 2.5 * u
                c.beginPath(); c.moveTo(px(Number(points[i - 1].t)), py(Number(points[i - 1].v))); c.lineTo(x, y); c.stroke()
            }
            c.fillStyle = accent; c.beginPath(); c.arc(x, y, 3 * u, 0, Math.PI * 2); c.fill()
        }
        c.restore()
        if (!points.length) { c.fillStyle = chart.muted; c.font = (15 * u) + "px sans-serif"; c.fillText("开始积累真实温度，缺测时段保持空白", left + 12 * u, (top + bottom) / 2) }
    }
}
