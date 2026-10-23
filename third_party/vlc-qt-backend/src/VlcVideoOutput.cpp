#include "vlc-qt-backend/VlcVideoOutput.h"

#include <QPainter>

VlcVideoOutput::VlcVideoOutput(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setRenderTarget(QQuickPaintedItem::FramebufferObject);
    setAntialiasing(false);
    setOpaquePainting(true);
    setAcceptedMouseButtons(Qt::NoButton);
}

void VlcVideoOutput::present(const QImage &frame) {
    if (frame.isNull()) return;
    {
        QMutexLocker locker(&mutex_);
        frame_ = frame;
    }
    update();
}

void VlcVideoOutput::paint(QPainter *painter) {
    painter->fillRect(QRectF(0, 0, width(), height()), Qt::black);
    QMutexLocker locker(&mutex_);
    if (frame_.isNull()) return;
    const QSizeF scaled = QSizeF(frame_.size()).scaled(QSizeF(width(), height()), Qt::KeepAspectRatio);
    const QRectF target((width() - scaled.width()) / 2.0, (height() - scaled.height()) / 2.0,
                        scaled.width(), scaled.height());
    painter->drawImage(target, frame_);
}
