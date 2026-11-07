#pragma once

#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QString>

class QNetworkReply;
class NetworkGate;

// 校时网络的 C++ 传输层。
//
// 为什么单独搬出 QML：校时和天气原先共用 34004 端口，关天气会连坐校时。
// 现在校时用自己的 QNAM + 34005 通道，天气继续用 QML 的 34004。
//
// 边界：只做 HTTP 传输 + 门控 + 8s 超时；URL 构造、线路回退、响应解析、
// 自动校时调度仍在 TimeSync.qml，行为与迁移前一致。
class TimeSyncClient final : public QObject {
    Q_OBJECT
public:
    explicit TimeSyncClient(NetworkGate *gate, quint16 proxyPort,
                            QObject *parent = nullptr, int timeoutMs = 8000);

    // requestId 由 QML 的 syncToken 提供；回调原样带回。
    Q_INVOKABLE void fetch(const QString &url, int requestId);
    Q_INVOKABLE void abort(int requestId);

signals:
    // 收到 HTTP 响应（含 4xx/5xx；status 为 0 表示网络错误）。
    void finished(int requestId, int status, const QString &body);
    // blocked / timeout / network
    void failed(int requestId, const QString &reason);

private:
    void finish(QNetworkReply *reply, int requestId);

    NetworkGate *gate_ = nullptr;
    QNetworkAccessManager network_;
    QHash<int, QNetworkReply *> replies_;
    int timeoutMs_ = 8000;
};
