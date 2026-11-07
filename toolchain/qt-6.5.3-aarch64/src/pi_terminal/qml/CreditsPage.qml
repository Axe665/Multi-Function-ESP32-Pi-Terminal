import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 「开发者与感谢」二级页：从「关于本机」里滑入的名单页。
//
// 结构（2026-11-01 与用户确认）：
// - 一次滑入，页内用 M3 分段控件在「开发者 / 感谢」之间切换，不拆第二层导航；
// - 每条是列表行：编号徽章 + 姓名 + 右侧组标签，按组放进一张卡片；
// - 动画沿用 RightSlidePage 的 240ms OutCubic（同开发者选项/关于本机）；
//   页内切换只做一次 180ms 的淡入位移，不逐行入场。
// - 名单先写占位数据（开发人员 1–6、感谢人员 1–6），换真名只改下面两个数组。
RightSlidePage {
    id: root
    objectName: "creditsPage"

    // 占位名单：badge 之后可换成真实姓名的首字，tag 是右侧的组标签。
    property var developers: [
        { name: I18n.t("开发人员 1"), badge: "1", tag: I18n.t("开发") },
        { name: I18n.t("开发人员 2"), badge: "2", tag: I18n.t("开发") },
        { name: I18n.t("开发人员 3"), badge: "3", tag: I18n.t("开发") },
        { name: I18n.t("开发人员 4"), badge: "4", tag: I18n.t("开发") },
        { name: I18n.t("开发人员 5"), badge: "5", tag: I18n.t("开发") },
        { name: I18n.t("开发人员 6"), badge: "6", tag: I18n.t("开发") }
    ]
    property var thanks: [
        { name: I18n.t("感谢人员 1"), badge: "1", tag: I18n.t("致谢") },
        { name: I18n.t("感谢人员 2"), badge: "2", tag: I18n.t("致谢") },
        { name: I18n.t("感谢人员 3"), badge: "3", tag: I18n.t("致谢") },
        { name: I18n.t("感谢人员 4"), badge: "4", tag: I18n.t("致谢") },
        { name: I18n.t("感谢人员 5"), badge: "5", tag: I18n.t("致谢") },
        { name: I18n.t("感谢人员 6"), badge: "6", tag: I18n.t("致谢") }
    ]

    // 0 = 开发者，1 = 感谢。分组各自一个强调色：蓝=工程、紫=致谢，
    // 两者都取自项目现有色板（设备信息卡 / 运行记录卡），不新增颜色。
    property int tab: 0
    readonly property color groupColor: tab === 0 ? "#4c9dff" : "#ad8cff"
    readonly property var rows: tab === 0 ? developers : thanks

    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    // 彩蛋：本页由「关于本机」连点版本号放出；「取消」把入口一起收回，
    // 与只关页面的返回箭头区分开。
    signal cancelRequested()

    onOpenChanged: {
        if (open) {
            tab = 0
            Qt.callLater(function() { pageFlick.contentY = 0 })
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.open
        onActivated: root.closeRequested()
    }

    // 与「关于本机」同一套外壳：外层直角底防漏色，内层圆角面板画边框。
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

        Column {
            id: header
            x: Theme.gap
            y: Theme.gap
            width: Math.max(1, parent.width - Theme.gap * 2)
            spacing: Theme.gap

            Row {
                width: header.width
                height: Math.max(Theme.hit, backButton.height)

                IconButton {
                    id: backButton
                    objectName: "creditsBack"
                    iconName: "arrow_back"
                    label: I18n.t("返回")
                    onClicked: root.closeRequested()
                }
                CarText {
                    width: Math.max(1, header.width - backButton.width - cancelButton.width)
                    height: parent.height
                    leftPadding: Theme.gap / 2
                    verticalAlignment: Text.AlignVCenter
                    heading: true
                    text: I18n.t("开发者与感谢")
                    elide: Text.ElideRight
                }
                CarButton {
                    id: cancelButton
                    objectName: "creditsCancel"
                    text: I18n.t("取消")
                    onClicked: root.cancelRequested()
                }
            }

            // M3 分段控件：一个胶囊底槽 + 两个等宽分段，选中段填充组色。
            Rectangle {
                id: segmented
                width: header.width
                height: 56 * Theme.scaleFactor
                radius: height / 2
                color: Theme.surfaceContainer
                border.width: 1
                border.color: Theme.outlineVariant

                Row {
                    anchors.fill: parent
                    anchors.margins: 5 * Theme.scaleFactor
                    spacing: 5 * Theme.scaleFactor

                    Repeater {
                        model: [I18n.t("开发者"), I18n.t("感谢")]
                        delegate: Rectangle {
                            id: segment
                            required property string modelData
                            required property int index
                            width: (segmented.width - 15 * Theme.scaleFactor) / 2
                            height: parent.height
                            radius: height / 2
                            color: root.tab === index ? root.groupColor : "transparent"
                            Behavior on color {
                                ColorAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }
                            CarText {
                                anchors.centerIn: parent
                                text: segment.modelData
                                fontPixelSize: Theme.fontLabel
                                color: root.tab === index ? Theme.textOn(root.groupColor) : Theme.outline
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.tab = segment.index
                            }
                        }
                    }
                }
            }
        }

        Flickable {
            id: pageFlick
            objectName: "creditsFlick"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.gap
            anchors.topMargin: Theme.gap / 2
            clip: true
            contentWidth: width
            // 内容不足一屏时也不要出现滚动条（AsNeeded 仍会按更大的一边判定）。
            contentHeight: Math.max(pageFlick.height, content.implicitHeight)
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar {
                objectName: "creditsScrollBar"
                policy: ScrollBar.AsNeeded
                // Qt 6.5 的 AsNeeded 在 contentHeight 恰好等于 height 时仍可能
                // 保持可见（size 由 0 变成 1 的那一帧没重新评估）。名单在一屏
                // 内时显式隐藏，超出一屏再交给 policy 显示。
                visible: pageFlick.contentHeight > pageFlick.height + 1
                implicitWidth: 12 * Theme.scaleFactor
                contentItem: Rectangle {
                    implicitWidth: 4 * Theme.scaleFactor
                    radius: Theme.shapeFull
                    color: Theme.outline
                }
            }

            Column {
                id: content
                width: pageFlick.width
                spacing: Theme.gap

                CarText {
                    width: content.width
                    text: root.tab === 0
                          ? I18n.t("COUNT 位开发者").replace("COUNT", String(root.developers.length))
                          : I18n.t("COUNT 位致谢者").replace("COUNT", String(root.thanks.length))
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                }

                // 名单卡片：一组一张，条目之间用发丝线分隔（最后一条不画）。
                Rectangle {
                    id: card
                    width: content.width
                    height: listColumn.implicitHeight + Theme.gap * 2
                    radius: Theme.shapeLarge
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.outlineVariant
                    opacity: 1

                    Column {
                        id: listColumn
                        x: Theme.gap
                        y: Theme.gap
                        width: Math.max(1, card.width - Theme.gap * 2)
                        spacing: 0

                        Repeater {
                            model: root.rows
                            delegate: Item {
                                id: row
                                required property var modelData
                                required property int index
                                width: listColumn.width
                                height: 72 * Theme.scaleFactor

                                Rectangle {
                                    id: badge
                                    width: 44 * Theme.scaleFactor
                                    height: width
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: width / 2
                                    color: Qt.darker(root.groupColor, 2.4)
                                    border.width: 1
                                    border.color: root.groupColor
                                    CarText {
                                        anchors.centerIn: parent
                                        text: row.modelData.badge
                                        fontPixelSize: Theme.fontLabel
                                        color: root.groupColor
                                    }
                                }

                                CarText {
                                    id: personName
                                    anchors.left: badge.right
                                    anchors.leftMargin: Theme.gap
                                    anchors.right: tagText.left
                                    anchors.rightMargin: Theme.gap
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.modelData.name
                                    fontPixelSize: Theme.fontStrong
                                    color: Theme.foreground
                                    elide: Text.ElideRight
                                }

                                CarText {
                                    id: tagText
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.modelData.tag
                                    fontPixelSize: Theme.fontCaption
                                    color: Theme.outline
                                }

                                Rectangle {
                                    visible: row.index < root.rows.length - 1
                                    anchors.left: badge.right
                                    anchors.leftMargin: Theme.gap
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 1
                                    color: Theme.outlineVariant
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
