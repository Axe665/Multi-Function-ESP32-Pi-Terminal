import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// 「用户与权限」独立功能页（section 15）。
//
// 2026-11-01 重做：主页是五张分类卡片（账户/安全/其他用户/数据/高级），
// 点卡片后整页从右侧滑入二级页，动画与生命周期复用开发者选项的 RightSlidePage
// （240ms OutCubic）。页面只负责导航；身份、PIN、恢复码的判定仍在 SessionManager。
Item {
    id: view
    objectName: "userSecurityView"

    property bool active: false
    property real uiScale: 1
    // -1 = 主页；0..4 = 二级页分区。
    property int section: -1

    signal keyboardRequested()
    signal keyboardDismissed()
    // 账户删掉了：往上抛给 Main，由它拉起等待层（至少 4 秒）再切下一个界面。
    signal accountDeleted(bool lastAdmin)

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: home.implicitHeight + Theme.margin * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        UserSecurityHome {
            id: home
            x: Theme.margin
            y: Theme.margin
            width: Math.max(240, view.width - Theme.margin * 2)
            onSectionRequested: function(index) {
                view.section = index
                detail.open = true
            }
        }
    }

    // 二级页：右侧滑入、滑出；关闭时把宿主键盘一并收回。
    RightSlidePage {
        id: detail
        width: view.width
        height: view.height
        z: 40
        onCloseRequested: {
            detail.open = false
            view.keyboardDismissed()
        }
        onOpenChanged: if (!detail.open) view.section = -1

        // 整页不透明背景：RightSlidePage 只负责位移，不画底；
        // 少了这一层，主页卡片会从二级页下面透出来。
        Rectangle {
            anchors.fill: parent
            color: Theme.background
        }

        Loader {
            anchors.fill: parent
            // 没进过二级页时完全不创建：本页所在的 StackLayout 槽位在未选中时
            // 宽度是 0，页面只能被钳到 240/320 这种测量宽度，内容在窄宽下换行
            // 极多，Qt 6.5 的 ColumnLayout 两轮迭代算不出稳定高度（polish loop）。
            // section 回到 -1 后靠 shown 撑到滑出动画结束再卸载。
            active: view.section >= 0 || detail.shown
            sourceComponent: Component {
            Flickable {
            anchors.fill: parent
            contentWidth: width
            contentHeight: pageContent.implicitHeight + Theme.margin * 2
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            UserSecurityPage {
                id: pageContent
                x: Theme.margin
                y: Theme.margin
                width: Math.max(240, detail.width - Theme.margin * 2)
                section: view.section
                onKeyboardRequested: view.keyboardRequested()
                onKeyboardDismissed: view.keyboardDismissed()
                onCloseRequested: detail.closeRequested()
                onAccountDeleted: function(lastAdmin) { view.accountDeleted(lastAdmin) }
            }
            }
            }
        }
    }
}
