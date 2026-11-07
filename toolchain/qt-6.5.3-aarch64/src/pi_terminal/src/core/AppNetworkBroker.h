#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QUrl>

#include <functional>

// 第三方应用网络 broker（宿主进程）。
//
// 边界：
// - 只发 HTTP(S)；
// - 目标必须是公网地址（DNS 解析后检查全部地址）；
// - 权限由宿主按 appId 判定，broker 不信任应用自报；
// - 响应缓冲上限 16 MiB，超时 30 s，最大 5 次安全重定向；
// - 每个 appId 独立 QNetworkAccessManager（cookie 不跨应用）。
class AppNetworkBroker : public QObject {
    Q_OBJECT
public:
    using Permission = std::function<bool(const QString &appId)>;
    using Completion = std::function<void(const QJsonObject &response)>;

    explicit AppNetworkBroker(Permission permission, QObject *parent = nullptr);

    // 同步检查权限/协议/公网；失败返回 false 并给出 why。
    bool permits(const QString &appId, const QUrl &url, QString *why = nullptr) const;
    // 仅检查应用级开关；用于 QML allowed 属性。
    bool appAllowed(const QString &appId) const;

    // 异步 HTTP(S) 请求。request:
    // {method, url, headers:{...}, bodyBase64, timeoutMs}
    // response: {ok,status,headers:{...},bodyBase64,error}
    void request(const QString &appId, const QJsonObject &request, Completion done);
    // C 模块的同步封装：内部用局部事件循环等待同一个 broker 请求。
    QJsonObject requestSync(const QString &appId, const QJsonObject &request);

private:
    QNetworkAccessManager *managerFor(const QString &appId);

    Permission permission_;
    QHash<QString, QNetworkAccessManager *> managers_;
};
