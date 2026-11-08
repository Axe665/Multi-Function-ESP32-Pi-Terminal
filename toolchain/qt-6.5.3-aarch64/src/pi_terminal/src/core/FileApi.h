#pragma once

#include <QJsonObject>
#include <QObject>
#include <QVariantMap>

class FileApiBroker;
class NetworkGate;

// 模块 QML 的文件 API。只有声明 file_api 且管理员授权的模块能调用；
// 默认写根是本包 app data，家目录读取由 daemon 做敏感目录过滤。
class FileApi : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString appId READ appId CONSTANT)
    Q_PROPERTY(bool allowed READ allowed)
    Q_PROPERTY(QString appRoot READ appRoot CONSTANT)
    Q_PROPERTY(qint64 writeGrantExpiresAt READ writeGrantExpiresAt NOTIFY writeGrantChanged)

public:
    FileApi(FileApiBroker *broker, NetworkGate *gate, QString instance,
            QString packageId, QObject *parent = nullptr);

    QString appId() const { return instance_; }
    bool allowed() const;
    QString appRoot() const { return appRoot_; }
    qint64 writeGrantExpiresAt() const;

    // 通用接口；args 同 daemon：path/offset/length/dataBase64/truncate/target。
    Q_INVOKABLE QVariantMap request(const QString &op, const QVariantMap &args);
    // 模块请求用户选择可写目录；仅宿主弹窗并签发会话 token。
    Q_INVOKABLE void requestWriteAccess();

    // 宿主专用：用户选择后注入能力 token，不暴露为 QML 可调用方法。
    void setWriteGrant(const QString &root, const QString &token);
    void clearWriteGrant();

signals:
    void writeAccessRequested(const QString &instance, const QString &packageId);
    void writeGrantChanged();

private:
    QVariantMap denied(const QString &why) const;

    FileApiBroker *broker_ = nullptr;
    NetworkGate *gate_ = nullptr;
    QString instance_;
    QString packageId_;
    QString appRoot_;
    QString writeRoot_;
    QString writeToken_;
};
