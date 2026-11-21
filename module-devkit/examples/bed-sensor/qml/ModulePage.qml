import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

Rectangle {
    id: page
    implicitHeight: content.implicitHeight + 40
    color: "#eef2f5"
    radius: 20
    Material.theme: Material.Light
    Material.accent: "#3f6f9f"

    property var d: sessionModel ? sessionModel.data : ({})
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

    Component.onCompleted: page.capture()

    Connections {
        target: typeof sessionModel !== "undefined" ? sessionModel : null
        function onChanged() { page.capture() }
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
                width: parent.width - 220
                spacing: 6
                Text {
                    text: "BED GUARDIAN / 床边守护"
                    color: "#5b7487"
                    font.pixelSize: 12
                    font.letterSpacing: 1
                }
                Text {
                    text: "四点称重，看得见起身与离床"
                    color: "#1d3446"
                    font.pixelSize: 22
                    font.bold: true
                }
                Text {
                    text: "只输出重量、重心和事件；不测睡姿、不装摄像头。"
                    color: "#5b7487"
                    font.pixelSize: 13
                }
            }

            Rectangle {
                width: 200
                height: 44
                radius: 22
                color: page.fresh ? (page.d.night ? "#dbe6f4" : "#d9ecdf") : "#f4e1c8"
                Text {
                    anchors.centerIn: parent
                    text: page.fresh ? (page.d.night ? "夜间 · 实时" : "实时监测") : "等待数据"
                    color: "#26465c"
                    font.pixelSize: 14
                }
            }
        }

        Text {
            width: parent.width
            visible: Number(page.d.fault || 0) !== 0
            text: "有称重通道读数异常，重量和重心可能不准，请检查 HX711 接线。"
            color: "#a33a2c"
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
                color: "#dfe8ee"
                border.color: "#b9c8d3"

                property real marginX: page.edgeCm / page.bw * width
                property real marginY: page.edgeCm / page.bl * height

                Rectangle {
                    x: 0; y: 0; width: parent.marginX; height: parent.height
                    color: "#8fa9bb"; opacity: 0.18
                }
                Rectangle {
                    x: parent.width - parent.marginX; y: 0; width: parent.marginX; height: parent.height
                    color: "#8fa9bb"; opacity: 0.18
                }
                Rectangle {
                    x: 0; y: 0; width: parent.width; height: parent.marginY
                    color: "#8fa9bb"; opacity: 0.12
                }
                Rectangle {
                    x: 0; y: parent.height - parent.marginY; width: parent.width; height: parent.marginY
                    color: "#8fa9bb"; opacity: 0.12
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 8
                    text: "床头"
                    color: "#4c6475"
                    font.pixelSize: 12
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: "床尾"
                    color: "#4c6475"
                    font.pixelSize: 12
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 8
                    text: "左"
                    color: "#4c6475"
                    font.pixelSize: 12
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    text: "右"
                    color: "#4c6475"
                    font.pixelSize: 12
                }

                Rectangle {
                    visible: page.weight > 0.5 && page.cx >= 0 && page.cy >= 0
                    width: 22
                    height: 22
                    radius: 11
                    color: "#e07a3f"
                    border.color: "#ffffff"
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
                    color: "#7b929f"
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
                        color: "#ffffff"
                        border.color: "#dbe4ea"
                        Text {
                            x: 14; y: 10
                            text: "床上重量 · kg"
                            color: "#6b8192"
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 30
                            text: page.weight.toFixed(1)
                            color: "#1d3446"
                            font.pixelSize: 34
                            font.bold: true
                        }
                    }

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 92
                        radius: 14
                        color: page.st === "out" ? "#fff1e3" : page.st === "edge" ? "#fff6d9" : "#e6f2ea"
                        border.color: "#dbe4ea"
                        Text {
                            x: 14; y: 10
                            text: "状态"
                            color: "#6b8192"
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 34
                            text: page.stateLabel(page.st)
                            color: "#1d3446"
                            font.pixelSize: 26
                            font.bold: true
                        }
                        Text {
                            x: 14; y: 66
                            text: page.st === "out" ? "离床 " + page.duration(page.d.out_ms)
                                                    : "在床 " + page.duration(page.d.in_ms)
                            color: "#6b8192"
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
                        color: "#ffffff"
                        border.color: "#dbe4ea"
                        Text {
                            x: 14; y: 8
                            text: "重心位置"
                            color: "#6b8192"
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 28
                            text: page.weight > 0.5 && page.cx >= 0
                                  ? "左右 " + page.cx.toFixed(0) + " · 头脚 " + page.cy.toFixed(0) + " cm"
                                  : "--"
                            color: "#1d3446"
                            font.pixelSize: 15
                        }
                        Text {
                            x: 14; y: 52
                            text: "床宽 " + page.bw.toFixed(0) + " × 床长 " + page.bl.toFixed(0) + " cm"
                            color: "#8598a6"
                            font.pixelSize: 11
                        }
                    }

                    Rectangle {
                        width: (parent.width - 10) / 2
                        height: 78
                        radius: 14
                        color: "#ffffff"
                        border.color: "#dbe4ea"
                        Text {
                            x: 14; y: 8
                            text: "体动强度"
                            color: "#6b8192"
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14; y: 28
                            text: Number(page.d.mov || 0).toFixed(2) + " kg RMS"
                            color: "#1d3446"
                            font.pixelSize: 15
                        }
                        Rectangle {
                            x: 14; y: 54
                            width: parent.width - 28
                            height: 8
                            radius: 4
                            color: "#e4ebf0"
                            Rectangle {
                                width: parent.width * Math.min(1, Number(page.d.mov || 0) / 2)
                                height: parent.height
                                radius: 4
                                color: "#e0a24a"
                            }
                        }
                    }
                }

                Rectangle {
                    visible: page.cal !== "idle" && page.cal !== ""
                    width: parent.width
                    height: 46
                    radius: 12
                    color: page.cal === "error" ? "#fde7e4" : "#fff4de"
                    Text {
                        anchors.fill: parent
                        anchors.margins: 10
                        verticalAlignment: Text.AlignVCenter
                        text: page.calHint(page.cal)
                        color: "#6b4a1d"
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 176
                    radius: 14
                    color: "#ffffff"
                    border.color: "#dbe4ea"

                    Text {
                        x: 14; y: 10
                        text: "最近事件"
                        color: "#6b8192"
                        font.pixelSize: 12
                    }
                    Text {
                        x: 14; y: 30
                        visible: eventModel.count === 0
                        text: "暂无事件"
                        color: "#9aabb7"
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
                                    color: "#8598a6"
                                    font.pixelSize: 12
                                }
                                Text {
                                    text: page.eventLabel(name)
                                    color: "#1d3446"
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }
                }
            }
        }

        Text {
            width: parent.width
            text: "去皮 / 四点标定 / 复位校准：在功能页的模块动作里点击 tare、calibrate 或 reset。标定时按页面提示依次放砝码；标定和去皮都要求床面空载。"
            color: "#6b8192"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }
}
}
