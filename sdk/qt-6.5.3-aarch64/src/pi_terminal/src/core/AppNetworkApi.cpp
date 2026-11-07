#include "core/AppNetworkApi.h"

#include "core/AppNetworkBroker.h"

#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQmlNetworkAccessManagerFactory>
#include <QPointer>
#include <QTimer>
#include <QUrl>

namespace {

class BlockedReply final : public QNetworkReply {
public:
    BlockedReply(const QNetworkRequest &request, QObject *parent)
        : QNetworkReply(parent)
    {
        setRequest(request);
        setUrl(request.url());
        setError(QNetworkReply::ContentAccessDenied,
                 QStringLiteral("module network access denied"));
        setFinished(true);
        QTimer::singleShot(0, this, [this] { emit finished(); });
    }

    void abort() override {}
    qint64 readData(char *, qint64) override { return -1; }
    qint64 bytesAvailable() const override { return 0; }
};

class AppNetworkNam final : public QNetworkAccessManager {
public:
    AppNetworkNam(AppNetworkBroker *broker, QString appId, QObject *parent)
        : QNetworkAccessManager(parent), broker_(broker), appId_(std::move(appId)) {}

protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &request,
                                 QIODevice *outgoingData) override
    {
        const QUrl url = request.url();
        // 模块包内资源由 QML 直接加载；NAM 只处理网络请求。
        if (url.scheme() == QStringLiteral("file") || url.scheme() == QStringLiteral("qrc"))
            return QNetworkAccessManager::createRequest(op, request, outgoingData);
        if (!broker_ || !broker_->permits(appId_, url))
            return new BlockedReply(request, this);
        return QNetworkAccessManager::createRequest(op, request, outgoingData);
    }

private:
    AppNetworkBroker *broker_ = nullptr;
    QString appId_;
};

}  // namespace

class ModuleNamFactory final : public QQmlNetworkAccessManagerFactory {
public:
    ModuleNamFactory(AppNetworkBroker *broker, QString appId)
        : broker_(broker), appId_(std::move(appId)) {}

    QNetworkAccessManager *create(QObject *parent) override
    {
        return new AppNetworkNam(broker_, appId_, parent);
    }

private:
    AppNetworkBroker *broker_ = nullptr;
    QString appId_;
};

AppNetworkApi::AppNetworkApi(AppNetworkBroker *broker, QString appId, QObject *parent)
    : QObject(parent), broker_(broker), appId_(std::move(appId))
{
}

bool AppNetworkApi::allowed() const
{
    return broker_ && broker_->appAllowed(appId_);
}

QQmlNetworkAccessManagerFactory *AppNetworkApi::createNamFactory(QObject *parent) const
{
    Q_UNUSED(parent)
    return new ModuleNamFactory(broker_, appId_);
}

int AppNetworkApi::request(const QVariantMap &options)
{
    const int id = nextRequestId_++;
    if (!broker_) {
        lastError_ = QStringLiteral("network broker unavailable");
        emit allowedChanged();
        emit finished(id, {{QStringLiteral("ok"), false},
                           {QStringLiteral("error"), lastError_}});
        return id;
    }
    const QJsonObject request = QJsonObject::fromVariantMap(options);
    QPointer<AppNetworkApi> self(this);
    broker_->request(appId_, request, [self, id](const QJsonObject &response) {
        if (!self) return;
        self->lastError_ = response.value(QStringLiteral("error")).toString();
        emit self->allowedChanged();
        emit self->finished(id, response.toVariantMap());
    });
    return id;
}
