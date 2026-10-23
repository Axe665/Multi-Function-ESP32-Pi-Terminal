#pragma once

#ifdef TERMINAL_VLC_BACKEND

#include <QQuickPaintedItem>
#include <QImage>
#include <QMutex>

// QML surface that displays the frames delivered by VlcPlayer's libVLC vmem
// callbacks. The last frame is stored under a mutex and painted with a
// PreserveAspectFit layout over a black background; the item works on both
// OpenGL and software render backends.
class VlcVideoOutput : public QQuickPaintedItem {
    Q_OBJECT
public:
    explicit VlcVideoOutput(QQuickItem *parent = nullptr);
    void paint(QPainter *painter) override;

    // Frame delivery from the player (queued onto the GUI thread).
    Q_INVOKABLE void present(const QImage &frame);

private:
    mutable QMutex mutex_;
    QImage frame_;
};

#endif // TERMINAL_VLC_BACKEND
