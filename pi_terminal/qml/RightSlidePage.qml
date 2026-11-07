import QtQuick

// 右侧滑入二级页的公共壳：开发者选项、关于本机、联网权限、连接设置、测试模式。
//
// 这些页面都是 appShell 的常驻子项。只用 `visible: x < width` 判定关闭时，
// 窗口/应用缩放会先改 width、后改 x，页面会在一帧里被误判为可见，表现为
// 上一个应用的菜单在右侧滑出位置闪一下。这里的可见性只由 shown 决定：
// - 打开：shown=true，x 从 width 动画到 0（240ms OutCubic，同开发者选项）；
// - 关闭：shown 保持到滑出动画结束，再隐藏；
// - 切换/关闭应用：调用 hideImmediately() 立即隐藏并归位，不把旧菜单带过去。
Item {
    id: root

    property bool open: false
    signal closeRequested()

    property int slideDuration: 240
    // 页面已完成首轮创建。首帧必须停在 width，滑入动画才有起点。
    property bool ready: false
    // 唯一决定是否绘制的状态；不跟随 width/x 的瞬时中间值。
    property bool shown: false
    // true 时即使 open 也为关闭位置；用于首次创建和立即隐藏。
    property bool parked: true

    z: 30
    x: (open && !parked) ? 0 : width
    visible: shown
    Behavior on x { NumberAnimation { duration: root.slideDuration; easing.type: Easing.OutCubic } }

    // 关闭时保留最终一帧直到滑出动画结束。定时器比在 visible 绑定里读
    // x/width 更稳定：窗口缩放导致的 x 变化不会把隐藏页重新显示出来。
    Timer {
        id: hideTimer
        interval: root.slideDuration + 20
        repeat: false
        onTriggered: if (!root.open) root.shown = false
    }

    // 延后一轮事件循环：先让页面以 width 完成首次布局，再启动滑入。
    // 用独立 Timer 而不是 Component.onCompleted，派生页仍可安全使用
    // 自己的 Component.onCompleted（开发者选项和测试模式都有）。
    Timer {
        id: bootTimer
        interval: 0
        running: true
        repeat: false
        onTriggered: {
            root.ready = true
            if (root.open) {
                root.shown = true
                root.parked = false
            }
        }
    }

    Connections {
        target: root
        function onOpenChanged() {
            if (root.open) {
                hideTimer.stop()
                if (root.ready) {
                    root.parked = false
                    root.shown = true
                }
            } else if (root.shown) {
                hideTimer.restart()
            }
        }
    }

    // 切换应用/关闭窗口时使用：无动画立即收起，避免旧二级页盖在新应用上。
    function hideImmediately() {
        hideTimer.stop()
        parked = true
        shown = false
    }
}
