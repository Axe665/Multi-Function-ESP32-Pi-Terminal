import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 连接管理 → 连接设置（整页二级页）。
//
// 2026-11-01 重做：与「用户与权限」同一套导航——主页是分类卡片，点卡片
// 从右侧滑入二级页；页内只保留最上面一个主标题，分组标题不再重复。
// 三个内容组件（SecurityStatusSection / ModuleAuthPanel / AdminPairingPage）原样复用。
RightSlidePage {
    id: page
    objectName: "connectionSettingsPage"
    signal keyboardRequested()

    // -1 = 主页；0..2 = 分类页。
    property int section: -1

    readonly property var cards: [
        { icon: "verified_user", color: "#4fd4a4", title: I18n.t("安全状态"), desc: I18n.t("信任库、本机身份、UID 索引与槽位") },
        { icon: "extension", color: "#85deff", title: I18n.t("模块认证"), desc: I18n.t("已连接模块的能力与授权状态") },
        { icon: "verified_user", color: "#8f7bff", title: I18n.t("设备配对与授权"), desc: I18n.t("桥板信任、卡片与操作记录") }
    ]

    z: 20
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    // 外层直角底把连接页彻底盖住；圆角交给内层面板画，四角不漏底色。
    Rectangle {
        anchors.fill: parent
        radius: Theme.shapeLarge
        color: Theme.surfaceContainer
        antialiasing: true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.gap
        radius: Theme.shapeLarge
        color: Theme.surface
        border.color: Theme.outlineVariant
        border.width: 1
        clip: true

        // 用 anchors 而不是 ColumnLayout：滑入动画的 240ms 里布局不会重算，
        // 之前用 ColumnLayout 时下半部分会先塌一帧再出现（闪烁）。
        RowLayout {
            id: header
            x: Theme.gap
            y: Theme.gap
            width: Math.max(1, parent.width - Theme.gap * 2)
            height: Math.max(48 * Theme.scaleFactor, Theme.hit)
            spacing: Theme.gap / 2
            CarText {
                Layout.fillWidth: true
                heading: true
                text: I18n.t("连接设置")
            }
            IconButton {
                id: backButton
                objectName: "connectionSettingsBack"
                iconName: "arrow_back"
                label: I18n.t("返回")
                onClicked: page.closeRequested()
            }
        }

        Item {
            id: contentArea
            x: Theme.gap
            y: header.y + header.height + Theme.gap
            width: Math.max(1, parent.width - Theme.gap * 2)
            height: Math.max(0, parent.height - y - Theme.gap)

            // ------------------------------------------------------ 主页卡片
            Flickable {
                anchors.fill: parent
                visible: page.section < 0
                contentWidth: width
                contentHeight: homeColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                ColumnLayout {
                    id: homeColumn
                    width: parent.width
                    spacing: Theme.gap

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        rowSpacing: Theme.gap
                        columnSpacing: Theme.gap

                        Repeater {
                            model: page.cards
                            delegate: Rectangle {
                                id: settingCard
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                Layout.preferredHeight: 112 * Theme.scaleFactor
                                radius: Theme.shapeLarge
                                color: cardMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                                border.width: 1
                                border.color: cardMouse.containsMouse ? Theme.accent : Theme.outlineVariant

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Theme.gap
                                    spacing: Theme.gap
                                    Rectangle {
                                        Layout.preferredWidth: 44 * Theme.scaleFactor
                                        Layout.preferredHeight: width
                                        radius: width / 2
                                        color: Qt.darker(settingCard.modelData.color, 2.1)
                                        border.color: Qt.lighter(settingCard.modelData.color, 1.15)
                                        MaterialIcon {
                                            anchors.centerIn: parent
                                            width: 24 * Theme.scaleFactor
                                            height: width
                                            name: settingCard.modelData.icon
                                            light: true
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        CarText {
                                            Layout.fillWidth: true
                                            text: settingCard.modelData.title
                                            fontPixelSize: Theme.fontStrong
                                            color: Theme.foreground
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }
                                        CarText {
                                            Layout.fillWidth: true
                                            text: settingCard.modelData.desc
                                            fontPixelSize: Theme.fontCaption
                                            color: Theme.outline
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                        }
                                    }
                                    MaterialIcon {
                                        Layout.preferredWidth: Theme.icon
                                        Layout.preferredHeight: Theme.icon
                                        name: "chevron_right"
                                        light: true
                                    }
                                }
                                MouseArea {
                                    id: cardMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: page.section = settingCard.index
                                }
                            }
                        }
                    }
                }
            }

            // ------------------------------------------------------ 分类二级页
            RightSlidePage {
                id: detail
                objectName: "connectionSettingsDetail"
                width: contentArea.width
                height: contentArea.height
                z: 20
                open: page.section >= 0
                onCloseRequested: page.section = -1

                // 内缩半格 + 面板同色：右边缘不压在外层描边上。
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Theme.gap / 2
                    radius: Theme.shapeMedium
                    color: Theme.surface
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap / 2
                    anchors.rightMargin: Theme.gap
                    anchors.topMargin: Theme.gap / 2
                    anchors.bottomMargin: Theme.gap
                    spacing: Theme.gap

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.gap
                        IconButton {
                            objectName: "connectionSettingsDetailBack"
                            iconName: "arrow_back"
                            label: I18n.t("返回")
                            onClicked: page.section = -1
                        }
                        CarText {
                            Layout.fillWidth: true
                            heading: true
                            elide: Text.ElideRight
                            text: page.section >= 0 && page.section < page.cards.length
                                  ? page.cards[page.section].title : ""
                        }
                    }

                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: detailColumn.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick

                        ColumnLayout {
                            id: detailColumn
                            width: parent.width
                            spacing: Theme.gap

                            SecurityStatusSection {
                                Layout.fillWidth: true
                                visible: page.section === 0
                            }
                            ModuleAuthPanel {
                                Layout.fillWidth: true
                                showTitle: false
                                visible: page.section === 1
                            }
                            AdminPairingPage {
                                Layout.fillWidth: true
                                showTitle: false
                                visible: page.section === 2
                                onKeyboardRequested: page.keyboardRequested()
                            }
                        }
                    }
                }
            }
        }
    }
}
