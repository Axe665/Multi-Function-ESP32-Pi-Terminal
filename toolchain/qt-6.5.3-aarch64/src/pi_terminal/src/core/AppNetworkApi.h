#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QQmlNetworkAccessManagerFactory>
#include <QVariantMap>

class AppNetworkBroker;
class QQmlEngine;

// 模块 QML 的显式网络 API；同时提供宿主 QML 引擎的 NAM 工厂，
// 让 XMLHttpRequest / 网络 Image 也只能访问同一套权限边界。
class AppNetworkApi : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString appId READ appId CONSTANT)
    Q_PROPERTY(bool allowed READ allowed NOTIFY allowedChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY allowedChanged)

public:
    AppNetworkApi(AppNetworkBroker *broker, QString appId, QObject *parent = nullptr);

    QString appId() const { return appId_; }
    bool allowed() const;
    QString lastError() const { return lastError_; }

    // options: {method,url,headers:{},bodyBase64,timeoutMs}
    // 结果通过 finished(requestId, response) 发出。
    Q_INVOKABLE int request(const QVariantMap &options);

    // 供 ModulePageHost 在加载模块页前安装到独立 QQmlEngine。
    QQmlNetworkAccessManagerFactory *createNamFactory(QObject *parent) const;

signals:
    void finished(int requestId, const QVariantMap &response);
    void allowedChanged();

private:
    AppNetworkBroker *broker_ = nullptr;
    QString appId_;
    QString lastError_;
    int nextRequestId_ = 1;
};
