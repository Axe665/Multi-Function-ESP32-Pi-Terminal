import QtQuick
import QtMultimedia

// Qt Multimedia fallback backend for VideoPlayer. Extracted verbatim from the
// original inline MediaPlayer/VideoOutput pair so the page can switch backends
// through a single Loader. Keeps the objectName contract used by the
// DiagnosticRunner audio-ducking audit.
Item {
    id: backend
    property url source
    property bool muted: false
    property real volume: 0.8
    readonly property real position: mediaPlayer.position
    readonly property real duration: mediaPlayer.duration
    readonly property bool playing: mediaPlayer.playbackState === MediaPlayer.PlayingState
    readonly property bool seekable: mediaPlayer.seekable
    readonly property bool loading: mediaPlayer.mediaStatus === MediaPlayer.LoadingMedia
    readonly property bool buffering: mediaPlayer.mediaStatus === MediaPlayer.BufferingMedia
    readonly property string errorString: mediaPlayer.errorString
    signal playingChanged()
    signal errorOccurred()
    function play() { mediaPlayer.play() }
    function pause() { mediaPlayer.pause() }
    function stop() { mediaPlayer.stop() }
    function seek(ms) { mediaPlayer.position = ms }

    MediaPlayer {
        id: mediaPlayer
        source: backend.source
        videoOutput: videoSurface
        audioOutput: AudioOutput { objectName: "videoAudioOutput"; muted: backend.muted; volume: backend.volume }
        onPlaybackStateChanged: backend.playingChanged()
        onErrorOccurred: function(error, errorString) {
            if (error !== MediaPlayer.NoError) backend.errorOccurred()
        }
    }
    VideoOutput {
        id: videoSurface
        objectName: "qtMultimediaVideoOutput"
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
    }
}
