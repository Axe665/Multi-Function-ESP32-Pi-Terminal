import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: page
    property var backend: null
    // A host can also inject the data-only model used by the existing devkit.
    // Its controller must supply the actions; QML never talks to the bridge.
    property var sessionModel: null
    readonly property var latest: backend ? backend.data : sessionModel ? sessionModel.data : ({})
    readonly property var layout: backend ? backend.placement : ({name: "实验室入口", x: 0.5, y: 0.5, angle: 0, length: 0.45})
    readonly property bool online: backend ? backend.online : false
    readonly property bool monitoringEnabled: latest.enabled === true
    readonly property bool wired: latest.pogo !== undefined && latest.pogo.wired === true
    readonly property string phase: !online ? "offline" : !monitoringEnabled ? "standby" : latest.state || "unknown"
    readonly property string phaseText: phase === "clear" ? "光束畅通" : phase === "blocked" ? "光束被遮挡" : phase === "standby" ? "待机 · 尚未启用" : phase === "offline" ? "设备离线 · 状态未知" : "正在读取光路"
    readonly property color tint: phase === "clear" ? "#43d9a0" : phase === "blocked" ? "#ff786a" : phase === "standby" ? "#e8bd69" : "#8a9aaf"
    color: "#101b29"

    function savePlacement(name, x, y, angle, length) {
        if (backend) backend.setPlacement(name, x, y, angle, length)
    }

    ColumnLayout {
        anchors.fill: parent; anchors.margins: 22; spacing: 12
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 4
                Label { text: "XIAOTIAN  /  空间感知"; color: "#78cdbd"; font.pixelSize: 12; font.letterSpacing: 1.4 }
                Label { text: "红外栏杆 · 场地视图"; color: "#f1f6fb"; font.pixelSize: 26; font.bold: true }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                visible: backend && backend.demo
                implicitWidth: 112; implicitHeight: 30; radius: 15; color: "#5a4725"
                Label { anchors.centerIn: parent; text: "演示 · 非真机"; color: "#ffda8c"; font.pixelSize: 12 }
            }
            Rectangle {
                implicitWidth: 126; implicitHeight: 34; radius: 17; color: "#203343"; border.color: page.tint
                Label { anchors.centerIn: parent; text: page.online ? "●  设备在线" : "○  设备离线"; color: page.tint; font.pixelSize: 13 }
            }
        }

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 14
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 340
                color: "#172738"; radius: 18; border.color: "#293e52"; clip: true
                Label { x: 18; y: 14; text: "实验室俯视示意"; color: "#cfdae7"; font.pixelSize: 15; font.bold: true }
                Label { x: 18; y: 38; text: "拖动栏杆放置位置；用右侧滑条设置朝向"; color: "#849bb2"; font.pixelSize: 11 }
                Item {
                    id: scene
                    anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                    anchors.topMargin: 76; anchors.bottomMargin: 44
                    Rectangle { anchors.fill: parent; color: "#142231"; border.width: 3; border.color: "#456078"; radius: 7 }
                    Repeater {
                        model: 9
                        Rectangle { required property int index; x: (index + 1) * scene.width / 10; width: 1; height: scene.height; color: "#203346" }
                    }
                    Repeater {
                        model: 6
                        Rectangle { required property int index; y: (index + 1) * scene.height / 7; height: 1; width: scene.width; color: "#203346" }
                    }
                    Rectangle {
                        x: 18; y: 18; width: scene.width * 0.28; height: scene.height * 0.22
                        radius: 8; color: "#263b4d"; border.color: "#39536a"
                        Label { anchors.centerIn: parent; text: "实验台 A"; color: "#8ea8bd"; font.pixelSize: 13 }
                    }
                    Rectangle {
                        x: scene.width * 0.57; y: 18; width: scene.width * 0.34; height: scene.height * 0.22
                        radius: 8; color: "#263b4d"; border.color: "#39536a"
                        Label { anchors.centerIn: parent; text: "实验台 B"; color: "#8ea8bd"; font.pixelSize: 13 }
                    }
                    Label { x: 15; y: scene.height - 28; text: "入口 / 通道"; color: "#67869d"; font.pixelSize: 12 }
                    Column {
                        x: scene.width - 32; y: 10; spacing: 2
                        Label { text: "N"; color: "#ccdde8"; anchors.horizontalCenter: parent.horizontalCenter; font.bold: true }
                        Label { text: "↑"; color: "#78cdbd"; font.pixelSize: 26 }
                    }

                    Item {
                        id: barrier
                        x: Number(page.layout.x) * scene.width
                        y: Number(page.layout.y) * scene.height
                        width: 0; height: 0
                        rotation: Number(page.layout.angle)
                        readonly property real span: Math.min(scene.width, scene.height) * Number(page.layout.length)
                        Rectangle {
                            x: -barrier.span / 2; y: -8; width: barrier.span; height: 16; radius: 8
                            color: page.tint; opacity: page.phase === "blocked" ? 0.20 : 0.09
                        }
                        Rectangle { x: -barrier.span / 2; y: -2; width: barrier.span; height: 4; color: page.tint; radius: 2; opacity: page.online && page.monitoringEnabled ? 1 : 0.35 }
                        Repeater {
                            model: 2
                            Rectangle {
                                required property int index
                                x: (index === 0 ? -barrier.span / 2 : barrier.span / 2) - 12
                                y: -22; width: 24; height: 44; radius: 7
                                color: "#233e50"; border.width: 2; border.color: page.tint
                                Rectangle { anchors.centerIn: parent; width: 8; height: 14; radius: 4; color: page.tint }
                            }
                        }
                        Label { x: -barrier.span / 2 - 12; y: 30; text: "发射端"; color: "#a4bdcf"; font.pixelSize: 11 }
                        Label { x: barrier.span / 2 - 16; y: 30; text: "接收端"; color: "#a4bdcf"; font.pixelSize: 11 }
                        Rectangle {
                            x: -82; y: -62; width: 164; height: 27; radius: 13; color: "#21394b"; border.color: "#456078"
                            Label { anchors.centerIn: parent; text: page.layout.name; color: "#e9f2f8"; font.pixelSize: 12; width: 144; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                        }
                        MouseArea {
                            x: -barrier.span / 2 - 24; y: -25; width: barrier.span + 48; height: 50
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            onPositionChanged: function(mouse) {
                                if (!pressed) return
                                const p = mapToItem(scene, mouse.x, mouse.y)
                                page.savePlacement(page.layout.name, p.x / scene.width, p.y / scene.height, page.layout.angle, page.layout.length)
                            }
                        }
                    }
                }
                Row {
                    x: 18; anchors.bottom: parent.bottom; anchors.bottomMargin: 16; spacing: 16
                    Repeater {
                        model: [{label:"通光",c:"#43d9a0"},{label:"遮挡",c:"#ff786a"},{label:"待机",c:"#e8bd69"},{label:"离线",c:"#8a9aaf"}]
                        Row {
                            required property var modelData
                            spacing: 5
                            Rectangle { width: 8; height: 8; radius: 4; color: parent.modelData.c; anchors.verticalCenter: parent.verticalCenter }
                            Label { text: parent.modelData.label; color: "#adc0d1"; font.pixelSize: 11 }
                        }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 282; Layout.fillHeight: true; color: "#1a2b3d"; radius: 18; border.color: "#293e52"
                ScrollView {
                    anchors.fill: parent; anchors.margins: 16; contentWidth: availableWidth
                    ColumnLayout {
                        width: parent.width; spacing: 9
                        Label { text: "设备与控制"; color: "#eaf3fb"; font.pixelSize: 17; font.bold: true }
                        Label { text: page.phaseText; color: page.tint; font.pixelSize: 20; font.bold: true; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Label { text: "触点：" + (page.wired ? "已握手" : "未连接 / 已分离") + "  ·  Wi-Fi 监测独立"; color: "#a3b8cb"; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Label { text: page.latest.device_id || "等待设备身份"; color: "#7694ac"; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideMiddle }
                        RowLayout {
                            Layout.fillWidth: true
                            Button { objectName: "enableButton"; text: page.monitoringEnabled ? "监测已启用" : "连接 / 启用"; Layout.fillWidth: true; enabled: page.backend && page.online && !page.backend.busy && !page.monitoringEnabled; onClicked: page.backend.setEnabled(true) }
                            Button { text: "停用"; enabled: page.backend && !page.backend.busy && page.monitoringEnabled; onClicked: page.backend.setEnabled(false) }
                        }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#344a60" }
                        Label { text: "位置与朝向"; color: "#d0e1ed"; font.pixelSize: 14; font.bold: true }
                        TextField {
                            Layout.fillWidth: true; text: page.layout.name; placeholderText: "位置名称"; maximumLength: 64
                            onEditingFinished: page.savePlacement(text, page.layout.x, page.layout.y, page.layout.angle, page.layout.length)
                        }
                        Label { text: "朝向  " + Math.round(Number(page.layout.angle)) + "°"; color: "#a3b8cb"; font.pixelSize: 12 }
                        Slider {
                            Layout.fillWidth: true; from: -180; to: 180; value: Number(page.layout.angle); stepSize: 5
                            onMoved: page.savePlacement(page.layout.name, page.layout.x, page.layout.y, value, page.layout.length)
                        }
                        Label { text: "图上长度（示意，无实际测距）"; color: "#a3b8cb"; font.pixelSize: 11 }
                        Slider {
                            Layout.fillWidth: true; from: 0.15; to: 0.7; value: Number(page.layout.length)
                            onMoved: page.savePlacement(page.layout.name, page.layout.x, page.layout.y, page.layout.angle, value)
                        }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#344a60" }
                        Label { text: "个人记录"; color: "#d0e1ed"; font.pixelSize: 14; font.bold: true }
                        Label {
                            text: page.backend && page.backend.authenticated ? "已接收终端登录态" : "访客 · 只显示实时状态"
                            color: "#a3b8cb"; font.pixelSize: 12
                        }
                        Button {
                            Layout.fillWidth: true; text: page.latest.recording === true ? "结束记录 · 继续监测" : "开始个人记录"
                            enabled: page.backend && page.backend.authenticated && page.online && page.monitoringEnabled && !page.backend.busy
                            onClicked: page.backend.setRecording(page.latest.recording !== true)
                        }
                        Label { text: page.latest.recording === true ? "● 正在记录当前用户" : "不保存个人事件"; color: page.latest.recording === true ? "#43d9a0" : "#819bb0"; font.pixelSize: 11 }
                        Flow {
                            visible: page.backend && page.backend.demo
                            Layout.fillWidth: true; spacing: 4
                            Button { text: "模拟遮挡"; onClicked: page.backend.demoToggleBeam() }
                            Button { text: "模拟拔触点"; onClicked: page.backend.demoTogglePogo() }
                            Button { text: "模拟登录/退出"; onClicked: page.backend.setAuthenticatedUser(page.backend.authenticated ? "" : "demo-user") }
                        }
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true; text: page.backend ? page.backend.message : "请由终端提供数据模型和操作适配器"
            color: "#9eb5ca"; font.pixelSize: 12; elide: Text.ElideRight
        }
        Label {
            Layout.fillWidth: true; text: "位置与朝向由人工设置 · 单路红外仅识别遮挡，不能判断人数或通行方向"
            color: "#67859c"; font.pixelSize: 11; wrapMode: Text.Wrap
        }
    }
}
