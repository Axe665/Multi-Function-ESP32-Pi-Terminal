#include "core/AppNetworkBroker.h"

#include "net/PublicNetwork.h"

#include <QEventLoop>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSharedPointer>
#include <QSet>
#include <QTimer>

namespace {
constexpr int kMaxBodyBytes = 16 * 1024 * 1024;
constexpr int kTimeoutMs = 30000;
constexpr int kMaxRedirects = 5;
const QSet<QByteArray> kForbiddenHeaders{
    QByteArrayLiteral("host"), QByteArrayLiteral("proxy-authorization"),
    QByteArrayLiteral("connection"), QByteArrayLiteral("content-length"),
    QByteArrayLiteral("transfer-encoding")};

QJsonObject errorResponse(const QString &error)
{
    return {{QStringLiteral("ok"), false},
            {QStringLiteral("status"), 0},
            {QStringLiteral("headers"), QJsonObject{}},
            {QStringLiteral("bodyBase64"), QString()},
            {QStringLiteral("error"), error}};
}
}  // namespace

AppNetworkBroker::AppNetworkBroker(Permission permission, QObject *parent)
    : QObject(parent), permission_(std::move(permission))
{
}

QNetworkAccessManager *AppNetworkBroker::managerFor(const QString &appId)
{
    auto *manager = managers_.value(appId);
    if (manager) return manager;
    manager = new QNetworkAccessManager(this);
    // 独立 cookie jar（每个 QNAM 自带一个）；不跨 app 共享。
    managers_.insert(appId, manager);
    return manager;
}

bool AppNetworkBroker::appAllowed(const QString &appId) const
{
    return permission_ && permission_(appId);
}

bool AppNetworkBroker::permits(const QString &appId, const QUrl &url, QString *why) const
{
    if (!appAllowed(appId)) {
        if (why) *why = QStringLiteral("application network access denied");
        return false;
    }
    const QString scheme = url.scheme().toLower();
    if (scheme != QStringLiteral("http") && scheme != QStringLiteral("https")) {
        if (why) *why = QStringLiteral("only http(s) is supported");
        return false;
    }
    if (!url.isValid() || url.host().isEmpty() || url.port(0) < 0) {
        if (why) *why = QStringLiteral("invalid url");
        return false;
    }
    if (!PublicNetwork::isPublicHost(url.host())) {
        if (why) *why = QStringLiteral("destination is not public");
        return false;
    }
    return true;
}

QJsonObject AppNetworkBroker::requestSync(const QString &appId, const QJsonObject &request)
{
    QEventLoop loop;
    QJsonObject result;
    this->request(appId, request, [&](const QJsonObject &response) {
        result = response;
        loop.quit();
    });
    if (result.isEmpty()) loop.exec();
    return result;
}

void AppNetworkBroker::request(const QString &appId, const QJsonObject &request,
                               Completion done)
{
    const QUrl url(request.value(QStringLiteral("url")).toString());
    QString why;
    if (!permits(appId, url, &why)) {
        done(errorResponse(why));
        return;
    }

    const QString method = request.value(QStringLiteral("method")).toString(QStringLiteral("GET"))
                               .trimmed().toUpper();
    if (method.isEmpty() || method.size() > 16) {
        done(errorResponse(QStringLiteral("invalid method")));
        return;
    }
    const QByteArray body = QByteArray::fromBase64(
        request.value(QStringLiteral("bodyBase64")).toString().toLatin1());
    if (body.size() > kMaxBodyBytes) {
        done(errorResponse(QStringLiteral("request body too large")));
        return;
    }

    QNetworkRequest networkRequest(url);
    networkRequest.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                               QNetworkRequest::NoLessSafeRedirectPolicy);
    networkRequest.setMaximumRedirectsAllowed(kMaxRedirects);
    const int timeout = qBound(1000, request.value(QStringLiteral("timeoutMs")).toInt(kTimeoutMs),
                               kTimeoutMs);
    networkRequest.setTransferTimeout(timeout);

    const QJsonObject headers = request.value(QStringLiteral("headers")).toObject();
    for (auto it = headers.begin(); it != headers.end(); ++it) {
        const QByteArray name = it.key().toLatin1().toLower();
        if (kForbiddenHeaders.contains(name) || !it.value().isString()) continue;
        networkRequest.setRawHeader(it.key().toLatin1(), it.value().toString().toUtf8());
    }

    QNetworkReply *reply = nullptr;
    if (method == QLatin1String("GET") || method == QLatin1String("HEAD"))
        reply = managerFor(appId)->sendCustomRequest(networkRequest, method.toUtf8());
    else
        reply = managerFor(appId)->sendCustomRequest(networkRequest, method.toUtf8(), body);
    if (!reply) {
        done(errorResponse(QStringLiteral("cannot create request")));
        return;
    }

    // 用 shared_ptr 捕获请求缓冲：reply 若在 finished 之前被销毁，
    // 裸指针会泄漏；shared_ptr 随两个 lambda 的销毁自动释放。
    auto buffer = QSharedPointer<QByteArray>::create();
    auto tooLarge = QSharedPointer<bool>::create(false);
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [reply, buffer, tooLarge] {
        if (*tooLarge) return;
        *buffer += reply->readAll();
        if (buffer->size() > kMaxBodyBytes) {
            *tooLarge = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::finished, reply,
                     [reply, buffer, tooLarge, done = std::move(done)]() mutable {
        *buffer += reply->readAll();
        QJsonObject out;
        if (*tooLarge) {
            out = errorResponse(QStringLiteral("response too large"));
        } else if (reply->error() != QNetworkReply::NoError) {
            out = errorResponse(reply->errorString());
        } else {
            QJsonObject headers;
            for (const auto &pair : reply->rawHeaderPairs())
                headers.insert(QString::fromLatin1(pair.first),
                               QString::fromLatin1(pair.second));
            out = {{QStringLiteral("ok"), true},
                   {QStringLiteral("status"),
                    reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()},
                   {QStringLiteral("headers"), headers},
                   {QStringLiteral("bodyBase64"), QString::fromLatin1(buffer->toBase64())},
                   {QStringLiteral("error"), QString()}};
        }
        reply->deleteLater();
        if (done) done(out);
    });
}
