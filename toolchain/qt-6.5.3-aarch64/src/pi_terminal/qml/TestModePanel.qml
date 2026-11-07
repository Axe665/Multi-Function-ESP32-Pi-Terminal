import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 测试模式：pi_terminal/tests 的分类视图（ctest / python / node）。
// 交互与版式参考天气设置 / 连接设置：整页从右侧滑入，240ms OutCubic。
// 刻意不用 Qt Quick Layouts：之前 ColumnLayout + 动态文本在 DPR2 下会触发
// polish loop（曾导致卡死），这里全部用 anchors/Row/Column 手工布局。
RightSlidePage {
    id: page

    property var rows: []
    property string outputText: ""
    property string statusText: "Ready"
    property var pendingIds: []
    property string pendingConfirmId: ""
    property string pendingConfirmLabel: ""
    property bool pendingConfirmGroup: false

    z: 16000
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    function reload() {
        const tests = testRunner.discover()
        const built = []
        let currentGroup = ""
        for (let i = 0; i < tests.length; ++i) {
            const t = tests[i]
            if (t.group !== currentGroup) {
                currentGroup = t.group
                let groupHeavy = false
                for (let j = 0; j < tests.length; ++j)
                    if (tests[j].group === currentGroup && tests[j].heavy) groupHeavy = true
                built.push({type: "group", group: currentGroup, heavy: groupHeavy})
            }
            built.push({type: "test", id: t.id, group: t.group, label: t.label, kind: t.kind,
                        heavy: t.heavy, available: t.available, reason: t.reason})
        }
        rows = built
        if (tests.length === 0) statusText = testRunner.discoveryError
    }

    function idsForGroup(group, includeHeavy) {
        const ids = []
        for (let i = 0; i < rows.length; ++i)
            if (rows[i].type === "test" && rows[i].group === group && rows[i].available
                    && (includeHeavy || !rows[i].heavy))
                ids.push(rows[i].id)
        return ids
    }

    function requestRun(id, label) {
        pendingConfirmId = id
        pendingConfirmLabel = label
        pendingConfirmGroup = false
        confirmDialog.open()
    }

    function requestGroup(group) {
        pendingConfirmId = ""
        pendingConfirmLabel = group
        pendingConfirmGroup = true
        let heavy = false
        for (let i = 0; i < rows.length; ++i)
            if (rows[i].type === "test" && rows[i].group === group && rows[i].heavy) heavy = true
        if (heavy) { confirmDialog.open(); return }
        outputText = ""
        pendingIds = idsForGroup(group, false)
        runNext()
    }

    function confirmRun() {
        confirmDialog.close()
        if (pendingConfirmGroup) {
            pendingIds = idsForGroup(pendingConfirmLabel, true)
            runNext()
        } else {
            pendingIds = []
            outputText = ""
            statusText = "Running: " + pendingConfirmLabel
            testRunner.run(pendingConfirmId)
        }
    }

    function runNext() {
        if (testRunner.running) return
        if (pendingIds.length === 0) { statusText = "Done"; return }
        const id = pendingIds.shift()
        let label = id
        for (let i = 0; i < rows.length; ++i)
            if (rows[i].type === "test" && rows[i].id === id) label = rows[i].label
        outputText = ""
        statusText = "Running: " + label
        testRunner.run(id)
    }

    Component.onCompleted: reload()
    onOpenChanged: if (open) { outputText = ""; statusText = "Ready"; reload() }

    Shortcut { sequence: "Escape"; enabled: page.open; onActivated: page.closeRequested() }

    Connections {
        target: testRunner
        function onOutput(chunk) {
            page.outputText += chunk
        }
        function onFinished(ok, summary) {
            page.outputText += "\n=== " + summary + " ===\n"
            if (page.pendingIds.length > 0) Qt.callLater(page.runNext)
            else page.statusText = ok ? "PASS" : "FAIL (" + summary + ")"
        }
    }

    Rectangle { anchors.fill: parent; radius: Theme.shapeLarge; color: Theme.surfaceContainer; antialiasing: true }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.gap
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outlineVariant
        border.width: 1
        clip: true

        Item {
            anchors.fill: parent
            anchors.margins: Theme.gap

            Item {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Theme.hit

                CarText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    heading: true
                    text: "Test mode"
                }
                CarText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.statusText
                    subdued: true
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap / 2
                    IconButton { objectName: "testModeReload"; iconName: "refresh"; label: "Reload"; onClicked: page.reload() }
                    IconButton { objectName: "testModeCancel"; iconName: "close"; label: "Cancel"
                        visible: testRunner.running; onClicked: testRunner.cancel() }
                    IconButton { objectName: "testModeBack"; iconName: "arrow_back"; label: "Back"; onClicked: page.closeRequested() }
                }
            }

            Item {
                id: content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.topMargin: Theme.gap

                Flickable {
                    id: list
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.floor(parent.width * 0.48)
                    contentWidth: width
                    contentHeight: rowsColumn.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick

                    Column {
                        id: rowsColumn
                        width: list.width
                        spacing: 0

                        Repeater {
                            model: page.rows
                            delegate: Item {
                                required property var modelData
                                width: rowsColumn.width
                                height: 48

                                Row {
                                    anchors.left: parent.left
                                    anchors.right: runRow.left
                                    anchors.rightMargin: Theme.gap
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.gap / 2
                                    visible: modelData.type === "test"
                                    CarText {
                                        text: modelData.type === "test" ? modelData.label : ""
                                        fontPixelSize: Theme.fontLabel
                                    }
                                    CarText {
                                        text: modelData.type === "test" ? modelData.kind : ""
                                        subdued: true
                                    }
                                    CarText {
                                        visible: modelData.type === "test" && !modelData.available
                                        text: modelData.type === "test" ? modelData.reason : ""
                                        color: Theme.warning
                                    }
                                }
                                Row {
                                    anchors.left: parent.left
                                    anchors.right: runRow.left
                                    anchors.rightMargin: Theme.gap
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: modelData.type === "group"
                                    CarText {
                                        text: modelData.type === "group" ? modelData.group : ""
                                        heading: true
                                    }
                                }
                                Row {
                                    id: runRow
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.gap / 2
                                    CarButton {
                                        text: "Run all"
                                        visible: modelData.type === "group"
                                        onClicked: page.requestGroup(modelData.group)
                                    }
                                    CarButton {
                                        text: "Run"
                                        visible: modelData.type === "test"
                                        enabled: modelData.type === "test" && modelData.available && !testRunner.running
                                        onClicked: {
                                            if (modelData.type !== "test") return
                                            if (modelData.heavy) { page.requestRun(modelData.id, modelData.label); return }
                                            page.outputText = ""
                                            page.statusText = "Running: " + modelData.label
                                            testRunner.run(modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    id: outputPane
                    anchors.left: list.right
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.gap

                    ReadOnlyTextView {
                        id: outputArea
                        objectName: "testModeOutput"
                        anchors.fill: parent
                        text: page.outputText
                        fontPixelSize: Math.max(11, 12 * Theme.scaleFactor)
                        followEnd: true
                    }
                    CarText {
                        anchors.fill: parent
                        anchors.margins: Theme.gap
                        visible: page.outputText === ""
                        text: "Test output appears here"
                        subdued: true
                    }
                }
            }
        }
    }

    Dialog {
        id: confirmDialog
        parent: Overlay.overlay
        z: 20000
        modal: true
        anchors.centerIn: parent
        width: Math.min(460 * Theme.scaleFactor, page.width - Theme.gap * 4)
        height: 210 * Theme.scaleFactor
        padding: Theme.shapeExtraLarge
        background: Rectangle { color: Theme.surface; radius: Theme.shapeExtraLarge; border.color: Theme.outline; border.width: 1 }
        contentItem: Item {
            Column {
                anchors.fill: parent
                spacing: Theme.gap
                CarText { width: parent.width; heading: true; text: "Heavy test" }
                CarText {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: (page.pendingConfirmGroup ? "Run all tests in " : "Run ") + page.pendingConfirmLabel
                          + (page.pendingConfirmGroup ? "?" : "?  This may start UI windows or control services.")
                }
                Item { width: parent.width; height: Theme.hit }
            }
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: Theme.gap / 2
                CarButton { text: "Cancel"; onClicked: confirmDialog.close() }
                CarButton { text: "Run"; accent: true; onClicked: page.confirmRun() }
            }
        }
    }
}
