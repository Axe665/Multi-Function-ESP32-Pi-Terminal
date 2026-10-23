#pragma once

#ifdef TERMINAL_VLC_BACKEND

#include <QObject>
#include <QUrl>
#include <QImage>
#include <QSize>
#include <QTimer>
#include <QByteArray>
#include <QPointer>

class QQuickItem;
class VlcVideoOutput;

struct libvlc_instance_t;
struct libvlc_media_player_t;

// QML-facing libVLC playback controller. The video surface is delivered to a
// VlcVideoOutput item through libVLC's vmem callbacks (RV32 frames copied into
// a QImage and presented on the GUI thread); audio stays inside libVLC and is
// controlled with setVolume/setMuted. All properties are GUI-thread only;
// libVLC events and vmem callbacks are marshalled with queued invocations.
class VlcPlayer : public QObject {
    Q_OBJECT
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(qint64 position READ position WRITE setPosition NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool seekable READ seekable NOTIFY seekableChanged)
    Q_PROPERTY(qreal volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorOccurred)
    Q_PROPERTY(QQuickItem *videoOutput READ videoOutput WRITE setVideoOutput NOTIFY videoOutputChanged)
public:
    explicit VlcPlayer(QObject *parent = nullptr);
    ~VlcPlayer() override;

    QUrl source() const { return source_; }
    void setSource(const QUrl &source);

    qint64 position() const { return position_; }
    void setPosition(qint64 ms);

    qint64 duration() const { return duration_; }
    bool playing() const { return playing_; }
    bool buffering() const { return buffering_; }
    bool loading() const;
    bool seekable() const { return seekable_; }

    qreal volume() const { return volume_; }
    void setVolume(qreal volume);

    bool muted() const { return muted_; }
    void setMuted(bool muted);

    QString errorString() const { return errorString_; }

    QQuickItem *videoOutput() const { return videoOutput_; }
    void setVideoOutput(QQuickItem *item);

    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();

    // True when a usable libVLC runtime could be loaded at startup.
    static bool runtimeAvailable();

    // Event kinds forwarded from libVLC event callbacks (public so the static
    // C shims can reference them).
    enum EventKind {
        EvPlaying = 0,
        EvPaused,
        EvStopped,
        EvEndReached,
        EvError,
        EvBuffering,
        EvLength
    };

    // GUI-thread event dispatch; public so the free postEvent shim can call it.
    void handleEvent(int kind, int value);

signals:
    void sourceChanged();
    void positionChanged();
    void durationChanged();
    void playingChanged();
    void bufferingChanged();
    void loadingChanged();
    void seekableChanged();
    void volumeChanged();
    void mutedChanged();
    void videoOutputChanged();
    void errorOccurred();
    void endReached();

private:
    void syncPosition();
    void clearPlayer();
    void applyAudio();
    void attachEvents();
    void attachVideoCallbacks();

    static libvlc_instance_t *instance();
    static void *lockCallback(void *opaque, void **planes);
    static void unlockCallback(void *opaque, void *picture, void *const *planes);
    static void displayCallback(void *opaque, void *picture);
    static unsigned formatCallback(void **opaque, char *chroma, unsigned *width,
                                   unsigned *height, unsigned *pitches, unsigned *lines);

    QUrl source_;
    libvlc_media_player_t *player_ = nullptr;
    QPointer<VlcVideoOutput> videoOutput_;
    QTimer positionTimer_;
    qint64 position_ = 0;
    qint64 duration_ = 0;
    bool playing_ = false;
    bool buffering_ = false;
    bool ended_ = false;
    bool stopping_ = false;
    bool seekable_ = false;
    qreal volume_ = 0.8;
    bool muted_ = false;
    QString errorString_;
    QByteArray frameBuffer_;
    QSize frameSize_;
};

#endif // TERMINAL_VLC_BACKEND
