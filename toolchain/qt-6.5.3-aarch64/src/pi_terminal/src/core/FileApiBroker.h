#pragma once

#include <QHash>
#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <QProcess>
#include <QString>

// 宿主侧文件 API：唯一能连接 file daemon 的客户端。
// 模块不能直连 daemon（daemon socket 0600，worker 是 DynamicUser）。
class FileApiBroker : public QObject {
    Q_OBJECT
public:
    explicit FileApiBroker(QObject *parent = nullptr);
    ~FileApiBroker() override;

    // 同步请求（C 模块回调使用）。op: stat/list/read/write/mkdir/rename/remove/ping。
    // params 含 path/appRoot/writeRoot 等；调用方负责权限与 app 数据根。
    QJsonObject requestSync(const QString &op, const QJsonObject &params, int timeoutMs = 5000);
    bool ready() const { return socket_ && socket_->state() == QLocalSocket::ConnectedState; }
    QString lastError() const { return lastError_; }

    // 每包独立可写目录；不存在时创建。
    QString appDataRoot(const QString &packageId) const;

    // 用户选择路径后签发会话级写能力 token；host 不暴露给模块 QML，
    // 模块只能经 FileApi 的 requestWriteAccess 触发用户选择。
    QString grantWrite(const QString &appId, const QString &path, int ttlSeconds = 86400);
    // 跨会话恢复未过期的用户选择；返回新的会话 token。
    QString restoreWrite(const QString &appId);
    void revokeWrites(const QString &appId, bool forget = true);
    qint64 grantExpiresAt(const QString &token) const;

private:
    struct WriteGrant {
        QString appId;
        QString root;
        qint64 expiresAt = 0;
    };

    bool ensureStarted();
    bool connectSocket(int timeoutMs);
    QJsonObject sendAndWait(const QJsonObject &request, int timeoutMs);
    void ensureToken();
    void persistGrant(const WriteGrant &grant);
    QString grantKey(const QString &appId) const;
    QString defaultSocketPath() const;
    QString tokenPath() const;

    QLocalSocket *socket_ = nullptr;
    QProcess *daemonProcess_ = nullptr;
    QString socketPath_;
    QString token_;
    QString lastError_;
    quint64 nextRequestId_ = 1;
    QHash<QString, WriteGrant> writeGrants_;
};
