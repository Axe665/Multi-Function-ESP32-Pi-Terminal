import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 开发者选项面板（仅管理员；全英文；运行结果原样输出）。
//
// 交互与版式参考天气设置 / 连接设置：整页从右侧滑入（240ms OutCubic），
// 内容为各分区的原始 JSON / 日志文本，不做翻译、不做脱敏、不做格式化美化。
RightSlidePage {
    id: page

    property string runtimeText: ""
    property string policyText: ""
    property string sessionText: ""
    property string securityText: ""
    property string connectionText: ""
    property string sandboxText: ""
    property string networkText: ""
    property string interfacesText: ""
    property string powerText: ""
    property string hotspotText: ""
    property string cacheText: ""
    property string logsText: ""
    property string statusText: ""
    property string bridgeId: ""
    property string bridgeKey: ""
    property string pairMessage: ""

    // 面板里的输入框要能叫出项目内置键盘（本机多半没插物理键盘）。
    signal keyboardRequested()

    z: 15000
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    function dump(value) {
        try { return JSON.stringify(value, null, 2) } catch (e) { return String(value) }
    }

    function allText() {
        return "=== RUNTIME ===\n" + runtimeText
             + "\n\n=== SESSION ===\n" + sessionText
             + "\n\n=== SECURITY ===\n" + securityText
             + "\n\n=== CONNECTION ===\n" + connectionText
             + "\n\n=== SANDBOX / WORKER ===\n" + sandboxText
             + "\n\n=== NETWORK ===\n" + networkText
             + "\n\n=== STORAGE & CACHE ===\n" + cacheText
             + "\n\n=== NET POLICY / HELPER ===\n" + policyText
             + "\n\n=== LOGS ===\n" + logsText
    }

    function reload() {
        runtimeText = developerProbe.runtimeJson
        sessionText = dump({
            activeUserId: sessionManager.activeUserId,
            activeDisplayName: sessionManager.activeDisplayName,
            isAdmin: sessionManager.isAdmin,
            guestSession: sessionManager.guestSession,
            loggedIn: sessionManager.loggedIn,
            locked: sessionManager.locked,
            hasUsers: sessionManager.hasUsers,
            usersCount: sessionManager.users.length,
            authStage: sessionManager.authStage,
            autoLockSeconds: sessionManager.autoLockSeconds,
            ownLockTimeoutMinutes: sessionManager.ownLockTimeoutMinutes
        })
        securityText = dump({
            securityStatus: {
                trustStoreHealthy: securityStatus.trustStoreHealthy,
                trustStorePath: securityStatus.trustStorePath,
                trustRecords: securityStatus.trustRecords,
                identityFingerprint: securityStatus.identityFingerprint,
                identityKeyId: securityStatus.identityKeyId,
                identityState: securityStatus.identityState,
                identityPath: securityStatus.identityPath,
                uidKeyReady: securityStatus.uidKeyReady,
                slotStats: securityStatus.slotStats(),
                slotSnapshot: securityStatus.slotSnapshot()
            },
            securityService: {
                ready: securityService.ready,
                healthy: securityService.healthy(),
                lastMessage: securityService.lastMessage,
                trustedBridges: securityService.trustedBridges(),
                boundCards: securityService.boundCards(),
                readings: securityService.readings(10)
            }
        })
        connectionText = dump({
            status: connectionManager.status,
            bridgeConnected: connectionManager.bridgeConnected,
            bridgeMonitoring: connectionManager.bridgeMonitoring,
            cards: connectionManager.cards,
            slotStatus: connectionManager.slotStatus(),
            slotStats: connectionManager.slotStats()
        })
        sandboxText = dump({
            moduleRoot: connectionManager.moduleRoot(),
            worker: connectionManager.workerInfo()
        })
        // 设置页「网络与连接」里原来那几行（供电 / 热点 / 接口地址）搬到开发者面板，
        // 拆成 INTERFACES / POWER / HOTSPOT 三块，和上面各栏同一套只读代码框。
        networkText = dump({
            networkGate: networkGate.snapshot(),
            network: systemTools.network
        })
        interfacesText = dump({
            interfaces: machineInfo.snapshot().nics,
            raw: systemTools.network
        })
        powerText = dump({
            powerStatus: {
                known: powerStatus.known,
                source: powerStatus.source,
                charge: powerStatus.charge,
                percent: powerStatus.percent
            },
            deviceStatus: {
                externalPower: systemTools.deviceStatus.externalPower,
                externalPowerType: systemTools.deviceStatus.externalPowerType,
                powerMode: systemTools.deviceStatus.powerMode,
                batteryPresent: systemTools.deviceStatus.batteryPresent,
                batteryPercent: systemTools.deviceStatus.batteryPercent,
                batteryState: systemTools.deviceStatus.batteryState
            }
        })
        hotspotText = dump({
            active: systemTools.deviceStatus.hotspotActive,
            known: systemTools.deviceStatus.hotspotKnown,
            busy: systemTools.hotspotBusy,
            networkLabel: systemTools.deviceStatus.networkLabel,
            networkOnline: systemTools.deviceStatus.networkOnline,
            wifiConnected: systemTools.deviceStatus.wifiConnected
        })
        cacheText = dump({
            moduleRoot: connectionManager.moduleRoot(),
            entries: developerProbe.moduleCache(connectionManager.moduleRoot())
        })
        policyText = dump({
            policyPath: networkPolicy.policyPath,
            loaded: networkPolicy.loaded,
            lastError: networkPolicy.lastError,
            helperPath: networkPolicy.helperPath,
            helperInstalled: networkPolicy.helperInstalled,
            gateEnabled: networkGate.enabled
        })
        logsText = systemTools.logs.join("\n")
        statusText = ""
        securityStatus.refresh()
    }

    function pairBridge() {
        const id = bridgeId.trim()
        const key = bridgeKey.trim()
        if (id.length === 0 || !/^[0-9a-fA-F]{130}$/.test(key)) {
            pairMessage = "Invalid input: Bridge ID required; public key must be 130 hex chars."
            return
        }
        const ok = securityService.pairBridge(id, key)
        pairMessage = ok ? "Paired." : (securityService.lastMessage || "Pairing failed.")
        if (ok) { bridgeId = ""; bridgeKey = ""; securityStatus.refresh(); reload() }
    }

    Component.onCompleted: reload()
    onOpenChanged: if (open) reload()

    Shortcut { sequence: "Escape"; enabled: page.open; onActivated: page.closeRequested() }

    Rectangle { anchors.fill: parent; radius: Theme.shapeLarge; color: Theme.surfaceContainer; antialiasing: true }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.gap
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outlineVariant
        border.width: 1
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.gap
            spacing: Theme.gap

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText { Layout.fillWidth: true; heading: true; text: "Developer options" }
                IconButton { objectName: "developerRefresh"; iconName: "refresh"; label: "Refresh"; onClicked: page.reload() }
                IconButton { objectName: "developerCopy"; iconName: "description"; label: "Copy all"
                    onClicked: { if (developerProbe.copyText(page.allText())) page.statusText = "Copied to clipboard" } }
                IconButton { objectName: "developerExport"; iconName: "save"; label: "Export"
                    onClicked: page.statusText = developerProbe.exportText(page.allText()) }
                IconButton { objectName: "developerBack"; iconName: "arrow_back"; label: "Back"; onClicked: page.closeRequested() }
            }

            CarText { Layout.fillWidth: true; visible: page.statusText.length > 0; text: page.statusText; subdued: true; elide: Text.ElideMiddle }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: column.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                clip: true

                ColumnLayout {
                    id: column
                    width: flick.width
                    spacing: Theme.gap

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: controlsColumn.implicitHeight + Theme.gap * 2
                        color: Theme.surfaceContainer
                        radius: Theme.shapeLarge
                        border.color: Theme.outlineVariant
                        border.width: 1

                        ColumnLayout {
                            id: controlsColumn
                            anchors.fill: parent
                            anchors.margins: Theme.gap
                            spacing: Theme.gap / 2

                            CarText { text: "PERFORMANCE"; heading: true; Layout.fillWidth: true }
                            RowLayout {
                                Layout.fillWidth: true
                                CarText { Layout.fillWidth: true; text: "Energy saving (simplified rendering)" }
                                Switch {
                                    objectName: "energySwitch"
                                    checked: systemTools.energySaving
                                    onClicked: systemTools.setEnergySaving(!systemTools.energySaving)
                                }
                            }

                            CarText { text: "MANUAL BRIDGE ENROLLMENT"; heading: true; Layout.fillWidth: true }
                            CarText { Layout.fillWidth: true; subdued: true; wrapMode: Text.Wrap
                                text: "Bridge ID and 65-byte uncompressed public key (130 hex chars)."
                            }
                            CarField { id: devBridgeId; plainHint: true; Layout.fillWidth: true
                                placeholderText: "Bridge ID"; text: page.bridgeId
                                onKeyboardRequested: page.keyboardRequested()
                                onTextChanged: page.bridgeId = text }
                            CarField { id: devBridgeKey; plainHint: true; Layout.fillWidth: true
                                placeholderText: "Public key (130 hex chars)"; text: page.bridgeKey
                                onKeyboardRequested: page.keyboardRequested()
                                onTextChanged: page.bridgeKey = text }
                            RowLayout {
                                Layout.fillWidth: true
                                CarButton { objectName: "developerPairBridge"; text: "Pair"; accent: true; onClicked: page.pairBridge() }
                                CarText { Layout.fillWidth: true; text: page.pairMessage; color: Theme.warning; elide: Text.ElideRight }
                            }

                            CarText { text: "TEST MODE"; heading: true; Layout.fillWidth: true }
                            CarButton { objectName: "developerOpenTestMode"; text: "Open test mode"
                                onClicked: win.testModeOpen = true }
                        }
                    }

                    Repeater {
                        model: [
                            { title: "RUNTIME", text: page.runtimeText, height: 190 },
                            { title: "SESSION", text: page.sessionText, height: 190 },
                            { title: "SECURITY", text: page.securityText, height: 240 },
                            { title: "CONNECTION", text: page.connectionText, height: 220 },
                            { title: "SANDBOX / WORKER", text: page.sandboxText, height: 220 },
                            { title: "NETWORK", text: page.networkText, height: 170 },
                            { title: "INTERFACES", text: page.interfacesText, height: 220 },
                            { title: "POWER", text: page.powerText, height: 200 },
                            { title: "HOTSPOT", text: page.hotspotText, height: 170 },
                            { title: "STORAGE & CACHE", text: page.cacheText, height: 200 },
                            { title: "NET POLICY / HELPER", text: page.policyText, height: 200 },
                            { title: "LOGS", text: page.logsText, height: 260 }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: sectionColumn.implicitHeight + Theme.gap * 2
                            color: Theme.surfaceContainer
                            radius: Theme.shapeLarge
                            border.color: Theme.outlineVariant
                            border.width: 1

                            ColumnLayout {
                                id: sectionColumn
                                anchors.fill: parent
                                anchors.margins: Theme.gap
                                spacing: Theme.gap / 2

                                CarText { text: modelData.title; heading: true; Layout.fillWidth: true }
                                // 完全只读：不能改、不能选中；按住拖动或滚轮浏览被裁切的内容。
                                // 要拿完整内容仍用顶部 Copy all / Export。
                                ReadOnlyTextView {
                                    objectName: "developerTextView"
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: modelData.height
                                    text: modelData.text
                                    fontPixelSize: Math.max(11, 12 * Theme.scaleFactor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
