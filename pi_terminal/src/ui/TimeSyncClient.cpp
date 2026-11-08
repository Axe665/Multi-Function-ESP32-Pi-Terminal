#include "ui/TimeSyncClient.h"

#include "core/NetworkGate.h"

#include <QNetworkProxy>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>
#include <QUrl>

TimeSyncClient::TimeSyncClient(NetworkGate *gate, quint16 proxyPort, QObject *parent,
                               int timeoutMs)
    : QObject(parent), gate_(gate), timeoutMs_(timeoutMs > 0 ? timeoutMs : 8000)
{
    if (proxyPort != 0) {
        network_.setProxy(QNetworkProxy(QNetworkProxy::HttpProxy,
                                        QStringLiteral("127.0.0.1"), proxyPort));
    }
}

void TimeSyncClient::fetch(const QString &url, int requestId)
{
    if (gate_ && !gate_->allow(NetworkGate::Purpose::TimeSync)) {
        // 和 QML 的 allow() 检查重复，但网络层不能依赖界面记得判定。
        QTimer::singleShot(0, this, [this, requestId] { emit failed(requestId, QStringLiteral("blocked")); });
        return;
    }
    abort(requestId);

    const QUrl target(url);
    if (!target.isValid() || target.host().isEmpty()
        || (target.scheme() != QLatin1String("http")
            && target.scheme() != QLatin1String("https"))) {
        QTimer::singleShot(0, this, [this, requestId] { emit failed(requestId, QStringLiteral("network")); });
        return;
    }

    QNetworkRequest request(target);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = network_.get(request);
    replies_.insert(requestId, reply);

    auto *timer = new QTimer(reply);
    timer->setSingleShot(true);
    timer->setInterval(timeoutMs_);
    QObject::connect(timer, &QTimer::timeout, reply, [this, reply, requestId] {
        if (!replies_.contains(requestId)) return;
        reply->setProperty("timeSyncTimedOut", true);
        emit failed(requestId, QStringLiteral("timeout"));
        reply->abort();
    });
    timer->start();

    QObject::connect(reply, &QNetworkReply::finished, this,
                     [this, reply, requestId] { finish(reply, requestId); });
}

void TimeSyncClient::abort(int requestId)
{
    QNetworkReply *reply = replies_.take(requestId);
    if (!reply) return;
    reply->abort();
    reply->deleteLater();
}

void TimeSyncClient::finish(QNetworkReply *reply, int requestId)
{
    if (!replies_.contains(requestId)) {
        reply->deleteLater();
        return;
    }
    replies_.remove(requestId);
    if (reply->property("timeSyncTimedOut").toBool()) {
        reply->deleteLater();
        return;
    }
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status <= 0) {
        if (reply->error() != QNetworkReply::OperationCanceledError)
            emit failed(requestId, QStringLiteral("network"));
        reply->deleteLater();
        return;
    }
    const QByteArray body = reply->readAll();
    if (body.size() > 1024 * 1024) {
        emit failed(requestId, QStringLiteral("network"));
        reply->deleteLater();
        return;
    }
    emit finished(requestId, status, QString::fromUtf8(body));
    reply->deleteLater();
}
