pragma Singleton
import QtQuick

// 全局语音入口（只提供 API，不主动播报）。
//
// 目的：以后任何页面要播报时，统一走这里，不要各自去碰 SystemTools、
// 更不要直接起 flite 进程或读声库。
//
// 约束：
// - 本文件**不发起任何播报**；调用方必须自己有明确的播报理由。
// - 彩蛋音色仍由 SystemTools 的测试模式控制（五连击解锁），本入口不做额外解锁，
//   未触发时角色音色既不展示也不可用。
// - 就绪状态是全局可绑定的；不可用时调用 say() 返回 false，由调用方决定怎么提示。
Item {
    id: speech

    // 总开关 + 引擎/词典/声库是否可用。
    readonly property bool enabled: systemTools.speechEnabled
    property bool _ready: false
    readonly property bool ready: _ready

    visible: false

    Component.onCompleted: refresh()

    Connections {
        target: systemTools
        function onVoiceChanged() { speech.refresh() }
        function onChanged() { speech.refresh() }
    }

    function refresh() {
        _ready = systemTools.speechReady()
    }

    // 返回 false 表示没有播（空文本 / 引擎不可用 / 总开关关闭）。
    function say(text) {
        if (!text || !enabled || !ready) return false
        systemTools.speak(String(text))
        return true
    }

    function sayWithVoice(text, id) {
        if (!text || !enabled || !ready) return false
        systemTools.speakWithVoice(String(text), String(id))
        return true
    }

    // 试听固定句，仅供音色页/后续设置界面使用。
    function preview(id) {
        if (!enabled || !ready) return false
        systemTools.previewVoice(String(id))
        return true
    }
}
