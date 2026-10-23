#pragma once

#include <QQuickPaintedItem>
#include <QImage>
#include <QMutex>

// QML surface that displays the frames delivered by VlcPlayer's libVLC vmem
// callbacks. The last frame is stored under a mutex and painted with a
// PreserveAspectFit layout over a black background; the item works on both
// OpenGL and software render backends and has no libVLC dependency itself, so
// it compiles on every platform.
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
