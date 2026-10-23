import QtQuick
import Terminal.Native 1.0

// libVLC backend for VideoPlayer. VlcPlayer drives playback and audio
// (volume/mute mapped to the 0..1 range used by the page), while VlcVideoOutput
// shows the decoded frames. A mirrored videoAudioOutput object keeps the
// DiagnosticRunner ducking audit working exactly as with Qt Multimedia.
Item {
    id: backend
    property url source
    property bool muted: false
    property real volume: 0.8
    readonly property real position: vlc.position
    readonly property real duration: vlc.duration
    readonly property bool playing: vlc.playing
    readonly property bool seekable: vlc.seekable
    readonly property bool loading: vlc.loading
    readonly property bool buffering: vlc.buffering
    readonly property string errorString: vlc.errorString
    signal playingChanged()
    signal errorOccurred()
    function play() { vlc.play() }
    function pause() { vlc.pause() }
    function stop() { vlc.stop() }
    function seek(ms) { vlc.position = ms }

    VlcPlayer {
        id: vlc
        source: backend.source
        muted: backend.muted
        volume: backend.volume
        videoOutput: videoSurface
        onPlayingChanged: backend.playingChanged()
        onErrorOccurred: backend.errorOccurred()
    }
    VlcVideoOutput {
        id: videoSurface
        objectName: "vlcVideoOutput"
        anchors.fill: parent
    }
    QtObject {
        id: audioMirror
        objectName: "videoAudioOutput"
        property real volume: backend.volume
        property bool muted: backend.muted
    }
}
