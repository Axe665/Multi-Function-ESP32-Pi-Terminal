#include "vlc-qt-backend/VlcPlayer.h"
#include "vlc-qt-backend/VlcVideoOutput.h"

#include <QFile>
#include <QMetaObject>
#include <QDebug>
#include <QCoreApplication>

#ifdef VLC_BACKEND_HAVE_LIBVLC

#include <cstring>
#include <mutex>

#include <vlc/vlc.h>

static void postEvent(VlcPlayer *player, int kind, int value) {
    QMetaObject::invokeMethod(player, [player, kind, value] {
        player->handleEvent(kind, value);
    }, Qt::QueuedConnection);
}

static void onPlaying(const libvlc_event_t *, void *opaque) { postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvPlaying, 0); }
static void onPaused(const libvlc_event_t *, void *opaque) { postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvPaused, 0); }
static void onStopped(const libvlc_event_t *, void *opaque) { postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvStopped, 0); }
static void onEndReached(const libvlc_event_t *, void *opaque) { postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvEndReached, 0); }
static void onError(const libvlc_event_t *, void *opaque) { postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvError, 0); }
static void onBuffering(const libvlc_event_t *event, void *opaque) {
    postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvBuffering, int(event->u.media_player_buffering.new_cache * 100.0f));
}
static void onLengthChanged(const libvlc_event_t *event, void *opaque) {
    postEvent(static_cast<VlcPlayer *>(opaque), VlcPlayer::EvLength, int(event->u.media_player_length_changed.new_length));
}

libvlc_instance_t *VlcPlayer::instance() {
    static libvlc_instance_t *inst = nullptr;
    static std::once_flag once;
    std::call_once(once, [] { inst = libvlc_new(0, nullptr); });
    return inst;
}

bool VlcPlayer::runtimeAvailable() {
    return instance() != nullptr;
}

VlcPlayer::VlcPlayer(QObject *parent) : QObject(parent) {
    positionTimer_.setInterval(200);
    positionTimer_.setTimerType(Qt::CoarseTimer);
    connect(&positionTimer_, &QTimer::timeout, this, &VlcPlayer::syncPosition);
}

VlcPlayer::~VlcPlayer() {
    clearPlayer();
}

void VlcPlayer::setSource(const QUrl &source) {
    if (source_ == source) return;
    source_ = source;
    clearPlayer();
    ended_ = false;
    stopping_ = false;
    errorString_.clear();
    position_ = 0;
    duration_ = 0;
    playing_ = false;
    buffering_ = false;
    seekable_ = false;
    emit sourceChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit bufferingChanged();
    emit seekableChanged();
    emit loadingChanged();
    if (source.isEmpty()) return;

    if (!runtimeAvailable()) {
        errorString_ = tr("VLC 运行库不可用，请安装 libvlc（vlc 软件包）");
        emit errorOccurred();
        emit loadingChanged();
        return;
    }
    player_ = libvlc_media_player_new(instance());
    if (!player_) {
        errorString_ = tr("无法创建 VLC 播放器实例");
        emit errorOccurred();
        emit loadingChanged();
        return;
    }
    const QByteArray path = QFile::encodeName(source.isLocalFile() ? source.toLocalFile() : source.toString());
    libvlc_media_t *media = libvlc_media_new_path(instance(), path.constData());
    if (!media) {
        errorString_ = tr("无法解析媒体地址");
        libvlc_media_player_release(player_);
        player_ = nullptr;
        emit errorOccurred();
        emit loadingChanged();
        return;
    }
    libvlc_media_player_set_media(player_, media);
    libvlc_media_release(media); // the player holds its own reference
    attachEvents();
    attachVideoCallbacks();
    applyAudio();
    emit loadingChanged();
}

void VlcPlayer::clearPlayer() {
    positionTimer_.stop();
    if (!player_) return;
    // Detach the vmem callbacks first so libVLC never calls into a dying player.
    libvlc_video_set_callbacks(player_, nullptr, nullptr, nullptr, nullptr);
    libvlc_media_player_stop(player_);
    libvlc_media_player_release(player_);
    player_ = nullptr;
}

void VlcPlayer::attachEvents() {
    if (!player_) return;
    auto *manager = libvlc_media_player_event_manager(player_);
    libvlc_event_attach(manager, libvlc_MediaPlayerPlaying, onPlaying, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerPaused, onPaused, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerStopped, onStopped, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerEndReached, onEndReached, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerEncounteredError, onError, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerBuffering, onBuffering, this);
    libvlc_event_attach(manager, libvlc_MediaPlayerLengthChanged, onLengthChanged, this);
}

void VlcPlayer::play() {
    if (!player_) {
        if (!source_.isEmpty()) setSource(source_);
        if (!player_) return;
    }
    stopping_ = false;
    ended_ = false;
    libvlc_media_player_play(player_);
    emit loadingChanged();
}

void VlcPlayer::pause() {
    if (player_) libvlc_media_player_pause(player_);
}

void VlcPlayer::stop() {
    stopping_ = true;
    positionTimer_.stop();
    if (player_) libvlc_media_player_stop(player_);
    position_ = 0;
    buffering_ = false;
    if (playing_) { playing_ = false; emit playingChanged(); }
    emit positionChanged();
    emit bufferingChanged();
    emit loadingChanged();
}

void VlcPlayer::setPosition(qint64 ms) {
    if (player_ && ms >= 0) {
        libvlc_media_player_set_time(player_, ms);
        position_ = ms;
        emit positionChanged();
    }
}

bool VlcPlayer::loading() const {
    return !source_.isEmpty() && !playing_ && !ended_ && !stopping_ && errorString_.isEmpty();
}

void VlcPlayer::setVolume(qreal volume) {
    volume_ = qBound(0.0, volume, 1.25);
    applyAudio();
    emit volumeChanged();
}

void VlcPlayer::setMuted(bool muted) {
    if (muted_ == muted) return;
    muted_ = muted;
    applyAudio();
    emit mutedChanged();
}

void VlcPlayer::applyAudio() {
    if (!player_) return;
    libvlc_audio_set_mute(player_, muted_ ? 1 : 0);
    libvlc_audio_set_volume(player_, int(qRound(volume_ * 100.0)));
}

void VlcPlayer::setVideoOutput(QQuickItem *item) {
    if (videoOutput_ == item) return;
    videoOutput_ = item;
    emit videoOutputChanged();
    attachVideoCallbacks();
}

void VlcPlayer::attachVideoCallbacks() {
    if (!player_ || !videoOutput_) return;
    libvlc_video_set_callbacks(player_, lockCallback, unlockCallback, displayCallback, this);
    libvlc_video_set_format(player_, "RV32", 0, 0, 0);
}

void VlcPlayer::syncPosition() {
    if (!player_) { position_ = 0; return; }
    const qint64 time = libvlc_media_player_get_time(player_);
    if (time >= 0 && time != position_) {
        position_ = time;
        emit positionChanged();
    }
    const bool seek = libvlc_media_player_is_seekable(player_) != 0;
    if (seek != seekable_) {
        seekable_ = seek;
        emit seekableChanged();
    }
}

void VlcPlayer::handleEvent(int kind, int value) {
    switch (kind) {
    case EvPlaying:
        playing_ = true;
        ended_ = false;
        stopping_ = false;
        errorString_.clear();
        positionTimer_.start();
        emit playingChanged();
        emit loadingChanged();
        syncPosition();
        break;
    case EvPaused:
        positionTimer_.stop();
        if (playing_) { playing_ = false; emit playingChanged(); }
        syncPosition();
        break;
    case EvStopped:
        positionTimer_.stop();
        if (playing_) { playing_ = false; emit playingChanged(); }
        if (!stopping_) emit loadingChanged();
        syncPosition();
        break;
    case EvEndReached:
        ended_ = true;
        positionTimer_.stop();
        if (playing_) { playing_ = false; emit playingChanged(); }
        position_ = duration_;
        emit positionChanged();
        emit loadingChanged();
        emit endReached();
        break;
    case EvError:
        errorString_ = QString::fromUtf8(libvlc_errmsg());
        if (errorString_.isEmpty()) errorString_ = tr("视频播放出错");
        emit errorOccurred();
        emit loadingChanged();
        break;
    case EvBuffering:
        buffering_ = value < 100;
        emit bufferingChanged();
        break;
    case EvLength:
        duration_ = value > 0 ? value : duration_;
        emit durationChanged();
        emit seekableChanged();
        break;
    default:
        break;
    }
}

void *VlcPlayer::lockCallback(void *opaque, void **planes) {
    auto *self = static_cast<VlcPlayer *>(opaque);
    if (self->frameBuffer_.isEmpty()) return nullptr;
    planes[0] = self->frameBuffer_.data();
    return nullptr;
}

void VlcPlayer::unlockCallback(void *opaque, void *picture, void *const *planes) {
    Q_UNUSED(picture);
    auto *self = static_cast<VlcPlayer *>(opaque);
    if (!self->frameSize_.isValid() || self->frameSize_.isEmpty() || !planes[0]) return;
    QImage frame(self->frameSize_, QImage::Format_RGB32);
    if (frame.isNull()) return;
    std::memcpy(frame.bits(), planes[0], size_t(frame.sizeInBytes()));
    QMetaObject::invokeMethod(self, [self, frame] {
        if (auto *output = qobject_cast<VlcVideoOutput *>(self->videoOutput_.data()))
            output->present(frame);
    }, Qt::QueuedConnection);
}

void VlcPlayer::displayCallback(void *opaque, void *picture) {
    Q_UNUSED(opaque);
    Q_UNUSED(picture);
}

unsigned VlcPlayer::formatCallback(void **opaque, char *chroma, unsigned *width, unsigned *height,
                                   unsigned *pitches, unsigned *lines) {
    std::strcpy(chroma, "RV32");
    pitches[0] = *width * 4;
    lines[0] = *height;
    auto *self = static_cast<VlcPlayer *>(*opaque);
    self->frameSize_ = QSize(int(*width), int(*height));
    const int size = int(pitches[0] * lines[0]);
    if (self->frameBuffer_.size() != size) self->frameBuffer_.resize(size);
    return 1;
}

#else // !VLC_BACKEND_HAVE_LIBVLC — portable stub with the identical QML surface

VlcPlayer::VlcPlayer(QObject *parent) : QObject(parent) {}
VlcPlayer::~VlcPlayer() = default;

bool VlcPlayer::runtimeAvailable() { return false; }

void VlcPlayer::setSource(const QUrl &source) {
    if (source_ == source) return;
    source_ = source;
    clearPlayer();
    ended_ = false;
    stopping_ = false;
    errorString_.clear();
    position_ = 0;
    duration_ = 0;
    playing_ = false;
    buffering_ = false;
    seekable_ = false;
    emit sourceChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit bufferingChanged();
    emit seekableChanged();
    emit loadingChanged();
    if (!source.isEmpty()) {
        errorString_ = tr("VLC 运行库不可用：本构建未包含 libVLC，请安装后重新编译");
        emit errorOccurred();
        emit loadingChanged();
    }
}

void VlcPlayer::clearPlayer() {}
void VlcPlayer::attachEvents() {}
void VlcPlayer::attachVideoCallbacks() {}
void VlcPlayer::syncPosition() {}
void VlcPlayer::applyAudio() {}
void VlcPlayer::handleEvent(int, int) {}

void VlcPlayer::play() {
    if (!source_.isEmpty() && errorString_.isEmpty()) {
        errorString_ = tr("VLC 运行库不可用");
        emit errorOccurred();
        emit loadingChanged();
    }
}

void VlcPlayer::pause() {}

void VlcPlayer::stop() {
    stopping_ = true;
    position_ = 0;
    buffering_ = false;
    if (playing_) { playing_ = false; emit playingChanged(); }
    emit positionChanged();
    emit bufferingChanged();
    emit loadingChanged();
}

void VlcPlayer::setPosition(qint64 ms) {
    position_ = ms;
    emit positionChanged();
}

bool VlcPlayer::loading() const {
    return !source_.isEmpty() && !playing_ && !ended_ && !stopping_ && errorString_.isEmpty();
}

void VlcPlayer::setVolume(qreal volume) {
    volume_ = qBound(0.0, volume, 1.25);
    emit volumeChanged();
}

void VlcPlayer::setMuted(bool muted) {
    if (muted_ == muted) return;
    muted_ = muted;
    emit mutedChanged();
}

void VlcPlayer::setVideoOutput(QQuickItem *item) {
    if (videoOutput_ == item) return;
    videoOutput_ = item;
    emit videoOutputChanged();
}

#endif // VLC_BACKEND_HAVE_LIBVLC
