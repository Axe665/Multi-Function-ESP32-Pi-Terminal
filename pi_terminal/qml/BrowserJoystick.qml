import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// On-screen joystick for browsing. Scope: scrolling the current web page ONLY —
// no cursor, no click injection, no navigation. Pushing the stick scrolls the
// page content (window.scrollBy) at a speed proportional to the deflection
// past a small dead zone; releasing the stick stops the scroll immediately.
// The panel can be dragged to any position and collapses to a badge.
Item {
    id: root
    objectName: "browserJoystick"
    property var targetView: null
    property bool expanded: false
    property real uiScale: 1
    property real stickX: 0   // -1..1, right = positive
    property real stickY: 0   // -1..1, down = positive (up scrolls the page up)
    readonly property bool active: expanded && targetView !== null

    function toggle() { expanded = !expanded }
    function open() { expanded = true }
    function close() { expanded = false }
    function setStick(dx, dy) {
        stickX = Math.max(-1, Math.min(1, dx))
        stickY = Math.max(-1, Math.min(1, dy))
    }
    function injectJs(code) {
        if (!targetView) return
        targetView.runJavaScript(code, function(result) {})
    }

    // ~20 Hz scroll injection (every 3rd 16 ms tick). Dead zone avoids jitter
    // while resting the thumb; scroll magnitude scales with deflection.
    Timer {
        id: scrollTimer
        interval: 16; repeat: true; running: root.expanded
        property int tick: 0
        onTriggered: {
            if (!root.active) return
            tick++
            if (tick % 3 !== 0) return
            const deadZone = 0.12
            let dx = 0, dy = 0
            if (Math.abs(root.stickX) > deadZone)
                dx = (root.stickX - Math.sign(root.stickX) * deadZone) / (1 - deadZone)
            if (Math.abs(root.stickY) > deadZone)
                dy = (root.stickY - Math.sign(root.stickY) * deadZone) / (1 - deadZone)
            const px = Math.round(dx * 36 * uiScale)
            const py = Math.round(dy * 36 * uiScale)
            if (px === 0 && py === 0) return
            injectJs("window.scrollBy(" + px + "," + py + "); true;")
        }
    }

    // ---- collapsed badge ----
    IconButton {
        id: badge
        objectName: "joystickBadge"
        visible: !root.expanded
        z: 3
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: 16 * uiScale; anchors.bottomMargin: 16 * uiScale
        iconName: "chevron_right"
        label: I18n.t("摇杆")
        implicitWidth: Theme.hit; implicitHeight: Theme.hit
        onClicked: root.open()
    }

    // ---- expanded cluster ----
    Rectangle {
        id: cluster
        objectName: "joystickCluster"
        visible: root.expanded
        z: 3
        width: 244 * uiScale
        height: contentColumn.implicitHeight + 2 * pad
        property real pad: Theme.gap
        property real dragStartX: 0
        property real dragStartY: 0
        radius: Theme.shapeLarge
        color: Theme.surfaceContainerHigh
        border.color: Theme.outlineVariant; border.width: 1
        Component.onCompleted: {
            x = Math.max(8, root.width - width - 16)
            y = 16
        }
        ColumnLayout {
            id: contentColumn
            x: cluster.pad; y: cluster.pad
            width: Math.max(0, parent.width - 2 * cluster.pad)
            spacing: 6
            Rectangle {
                id: dragHandle
                objectName: "joystickDragHandle"
                Layout.fillWidth: true
                implicitHeight: 30 * uiScale
                color: "transparent"
                property real startX: 0
                property real startY: 0
                DragHandler {
                    id: clusterDrag
                    target: null
                    onActiveChanged: if (active) { dragHandle.startX = cluster.x; dragHandle.startY = cluster.y }
                    onTranslationChanged: if (active) {
                        cluster.x = Math.max(8, Math.min(root.width - cluster.width - 8, dragHandle.startX + translation.x))
                        cluster.y = Math.max(8, Math.min(root.height - cluster.height - 8, dragHandle.startY + translation.y))
                    }
                }
                CarText { anchors.centerIn: parent; text: I18n.t("摇杆（可拖动）"); subdued: true }
            }
            Rectangle {
                id: stickBase
                objectName: "joystickStick"
                Layout.preferredWidth: 172 * uiScale; Layout.preferredHeight: 172 * uiScale
                Layout.alignment: Qt.AlignHCenter
                radius: width / 2
                color: "#1a000000"
                border.color: Theme.outline; border.width: 1
                Rectangle {
                    anchors.centerIn: parent; width: parent.width / 2; height: width; radius: width / 2
                    color: "transparent"; border.color: Theme.outlineVariant; border.width: 1
                }
                Rectangle {
                    id: stickThumb
                    objectName: "joystickStickThumb"
                    width: 66 * uiScale; height: width; radius: width / 2
                    color: Theme.accent
                    x: stickBase.width / 2 - width / 2 + root.stickX * (stickBase.width - width) / 2
                    y: stickBase.height / 2 - height / 2 + root.stickY * (stickBase.height - height) / 2
                    Behavior on x { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }
                    Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }
                }
                MultiPointTouchArea {
                    id: stickArea
                    anchors.fill: parent
                    function applyStick(p) {
                        const dx = (p.x - stickBase.width / 2) / (stickBase.width / 2)
                        const dy = (p.y - stickBase.height / 2) / (stickBase.height / 2)
                        const len = Math.sqrt(dx * dx + dy * dy)
                        root.stickX = len > 1 ? dx / len : dx
                        root.stickY = len > 1 ? dy / len : dy
                    }
                    onPressed: applyStick(touchPoints[0])
                    onUpdated: applyStick(touchPoints[0])
                    onReleased: { root.stickX = 0; root.stickY = 0 }
                    onCanceled: { root.stickX = 0; root.stickY = 0 }
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter; spacing: 8
                IconButton {
                    id: hideButton
                    objectName: "joystickHideButton"
                    iconName: "close"
                    label: I18n.t("收起")
                    implicitWidth: 56 * uiScale; implicitHeight: 56 * uiScale
                    onClicked: root.close()
                }
            }
        }
    }
}
