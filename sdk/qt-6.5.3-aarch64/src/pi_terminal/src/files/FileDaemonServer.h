#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QString>

class QLocalServer;
class QLocalSocket;

// 每用户文件 daemon：宿主进程是唯一客户端，模块不能直连。
// token 由宿主在启动前写入 0600 文件；socket 使用 QLocalServer::UserAccessOption。
class FileDaemonServer : public QObject {
    Q_OBJECT
public:
    FileDaemonServer(QString socketPath, QString token, QObject *parent = nullptr);

    bool start();
    QString socketPath() const { return socketPath_; }
    QString errorString() const { return error_; }

private:
    void onNewConnection();
    void onReadyRead(QLocalSocket *socket);
    void dispatch(QLocalSocket *socket, const QByteArray &frame);
    QJsonObject handle(const QJsonObject &request);

    QString socketPath_;
    QString token_;
    QString home_;
    QString error_;
    QLocalServer *server_ = nullptr;
};
