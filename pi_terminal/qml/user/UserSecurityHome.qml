import QtQuick
import QtQuick.Layouts

// 「用户与权限」主页：五张分类卡片，点进右侧滑入的二级页（同开发者选项）。
// 视觉沿用 Theme 深色 token 与 M3 的列表/分区语义，不引入第二套色板。
Item {
    id: home
    signal sectionRequested(int index)

    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Theme.gap

        // 标题交给窗口标题栏，页内只留一句说明。
        CarText {
            Layout.fillWidth: true
            text: I18n.t("管理这台终端上的账户、安全与数据。")
            color: Theme.outline
            fontPixelSize: Theme.fontCaption
            wrapMode: Text.WordWrap
        }

        GridLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.gap
            columns: 2
            rowSpacing: Theme.gap
            columnSpacing: Theme.gap

            Repeater {
                model: [
                    { icon: "verified_user", title: I18n.t("我的账户"), desc: I18n.t("头像、显示名与角色") },
                    { icon: "lock", title: I18n.t("安全"), desc: I18n.t("PIN、恢复码与重置") },
                    { icon: "person_add", title: I18n.t("其他用户"), desc: I18n.t("添加、禁用与删除") },
                    { icon: "folder", title: I18n.t("数据"), desc: I18n.t("导出、备份、恢复与清空") },
                    { icon: "tune", title: I18n.t("高级"), desc: I18n.t("安全状态与删除账户") }
                ]
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    // 卡片内的 RowLayout 有图标 + 文本 + 箭头，最小宽度约 200。
                    // 隐藏页初始化时网格可能只有几十像素宽，宽度不够时 Qt 6.5 的
                    // RowLayout 会反复 polish（visible 挡不住，不可见项照样算几何）。
                    Layout.minimumWidth: 200 * Theme.scaleFactor
                    Layout.preferredHeight: 132 * Theme.scaleFactor
                    radius: Theme.shapeLarge
                    color: cardMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                    border.width: 1
                    border.color: cardMouse.containsMouse ? Theme.accent : Theme.outlineVariant

                    // 用普通 Row 而不是 RowLayout：卡片宽度会随窗口从几十像素一路
                    // 变到上千，RowLayout 在这个区间里会反复 polish（Qt 6.5 对
                    // 「子项最小宽度之和 > 行宽」会在两次迭代后报 loop）。这里的
                    // 内容全是固定顺序的一行，手工算宽度就够，也彻底避开该问题。
                    Row {
                        anchors.fill: parent
                        anchors.margins: Theme.gap
                        spacing: Theme.gap

                        MaterialIcon {
                            width: 32 * Theme.scaleFactor
                            height: width
                            anchors.verticalCenter: parent.verticalCenter
                            name: card.modelData.icon
                            light: true
                        }
                        Column {
                            id: textColumn
                            width: Math.max(1, parent.width - 32 * Theme.scaleFactor
                                            - Theme.icon - parent.spacing * 2)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4
                            CarText {
                                width: parent.width
                                text: card.modelData.title
                                fontPixelSize: Theme.fontStrong
                                color: Theme.foreground
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            CarText {
                                width: parent.width
                                text: card.modelData.desc
                                fontPixelSize: Theme.fontCaption
                                color: Theme.outline
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }
                        MaterialIcon {
                            width: Theme.icon
                            height: width
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron_right"
                            light: true
                        }
                    }

                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: home.sectionRequested(card.index)
                    }
                }
            }
        }
    }
}
