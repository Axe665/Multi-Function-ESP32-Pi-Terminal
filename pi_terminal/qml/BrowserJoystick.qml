import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// On-screen joystick for browsing: a draggable cluster with an analog stick,
// click/back/reload buttons, and a high-visibility cursor that moves over the
// web view. When the cursor approaches the viewport edge the page auto-scrolls
// through injected JavaScript, and the click button activates whatever element
// sits under the cursor (elementFromPoint + el.click()). Works with any
// WebEngineView-like target exposing runJavaScript/goBack/reload/canGoBack.
Item {
    id: root
    objectName: "browserJoystick"
    property var targetView: null
    property bool expanded: false
    property real uiScale: 1
    property real cursorX: 0.5
    property real cursorY: 0.5
    property real stickX: 0
    property real stickY: 0
    readonly property bool active: expanded && targetView !== null

    readonly property real viewX: targetView ? targetView.mapToItem(root, 0, 0).x : 0
    readonly property real viewY: targetView ? targetView.mapToItem(root, 0, 0).y : 0
    readonly property real viewW: targetView ? Math.max(1, targetView.width) : 1
    readonly property real viewH: targetView ? Math.max(1, targetView.height) : 1
    property int scrollSkip: 0

    function toggle() { expanded = !expanded }
    function open() { if (!expanded) { expanded = true; cursorX = 0.5; cursorY = 0.5 } }
    function close() { expanded = false }
    function setStick(dx, dy) {
        stickX = Math.max(-1, Math.min(1, dx))
        stickY = Math.max(-1, Math.min(1, dy))
    }
    function injectJs(code) {
        if (!targetView) return
        targetView.runJavaScript(code, function(result) {})
    }
    function injectClick() {
        if (!active) return
        const x = Math.round(cursorX * viewW)
        const y = Math.round(cursorY * viewH)
        const zoom = (targetView.zoomFactor !== undefined) ? targetView.zoomFactor : 1
        injectJs("(function(x,y,zoom){var d=(window.devicePixelRatio||1)*zoom;"+
                 "x=Math.round(x/d);y=Math.round(y/d);"+
                 "var el=document.elementFromPoint(x,y);if(!el)return false;"+
                 "try{el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y,button:0}));"+
                 "el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y,button:0}));"+
                 "el.click();return true;}catch(e){return false;}})(" + x + "," + y + "," + zoom + ")")
    }
    function goBack() { if (active && targetView && targetView.canGoBack) targetView.goBack() }
    function reload() { if (active && targetView) targetView.reload() }

    // ---- cursor driven by the stick ----
    Rectangle {
        id: cursorRing
        objectName: "joystickCursor"
        visible: root.active
        z: 2
        x: viewX + root.cursorX * viewW - width / 2
        y: viewY + root.cursorY * viewH - height / 2
        width: 46 * uiScale; height: width; radius: width / 2
        color: "#33ffd54f"
        border.color: "#ffb300"; border.width: 3 * uiScale
        Rectangle {
            anchors.centerIn: parent
            width: 6 * uiScale; height: width; radius: width / 2
            color: "#ffb300"
        }
    }

    Timer {
        id: cursorTimer
        interval: 16; repeat: true; running: root.expanded
        onTriggered: {
            if (!root.active) return
            const speed = 15 * uiScale
            if (root.stickX !== 0 || root.stickY !== 0) {
                root.cursorX = Math.max(0, Math.min(1, root.cursorX + root.stickX * speed / viewW))
                root.cursorY = Math.max(0, Math.min(1, root.cursorY + root.stickY * speed / viewH))
            }
            edgeScrollTick()
        }
    }
    function edgeScrollTick() {
        const margin = 0.07
        let dx = 0, dy = 0
        if (cursorX < margin) dx = -(margin - cursorX) / margin
        else if (cursorX > 1 - margin) dx = (cursorX - (1 - margin)) / margin
        if (cursorY < margin) dy = -(margin - cursorY) / margin
        else if (cursorY > 1 - margin) dy = (cursorY - (1 - margin)) / margin
        if (dx === 0 && dy === 0) { scrollSkip = 0; return }
        scrollSkip++
        if (scrollSkip % 3 !== 0) return
        const px = Math.round(dx * 30 * uiScale)
        const py = Math.round(dy * 30 * uiScale)
        if (px === 0 && py === 0) return
        injectJs("window.scrollBy(" + px + "," + py + "); true;")
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
                    id: clickButton
                    objectName: "joystickClickButton"
                    iconName: "check_circle"
                    label: I18n.t("点击")
                    implicitWidth: 56 * uiScale; implicitHeight: 56 * uiScale
                    onClicked: root.injectClick()
                }
                IconButton {
                    id: backButton
                    objectName: "joystickBackButton"
                    iconName: "arrow_back"
                    label: I18n.t("后退")
                    implicitWidth: 56 * uiScale; implicitHeight: 56 * uiScale
                    enabled: root.active && targetView && targetView.canGoBack
                    onClicked: root.goBack()
                }
                IconButton {
                    id: reloadButton
                    objectName: "joystickReloadButton"
                    iconName: "refresh"
                    label: I18n.t("刷新")
                    implicitWidth: 56 * uiScale; implicitHeight: 56 * uiScale
                    enabled: root.active
                    onClicked: root.reload()
                }
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
