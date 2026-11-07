#include "core/FileApi.h"

#include "core/FileApiBroker.h"
#include "core/NetworkGate.h"

#include <QJsonArray>
#include <QJsonDocument>

FileApi::FileApi(FileApiBroker *broker, NetworkGate *gate, QString instance,
                 QString packageId, QObject *parent)
    : QObject(parent), broker_(broker), gate_(gate), instance_(std::move(instance)),
      packageId_(std::move(packageId))
{
    if (broker_) {
        appRoot_ = broker_->appDataRoot(packageId_);
        const QString restored = broker_->restoreWrite(packageId_);
        if (!restored.isEmpty()) writeToken_ = restored;
    }
}

bool FileApi::allowed() const
{
    return gate_ && gate_->moduleFileAllowed(instance_);
}

QVariantMap FileApi::denied(const QString &why) const
{
    return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), why}};
}

QVariantMap FileApi::request(const QString &op, const QVariantMap &args)
{
    if (!allowed()) return denied(QStringLiteral("file access denied"));
    if (!broker_) return denied(QStringLiteral("file service unavailable"));
    if (appRoot_.isEmpty()) return denied(QStringLiteral("app data root unavailable"));

    QJsonObject body = QJsonObject::fromVariantMap(args);
    body.insert(QStringLiteral("appRoot"), appRoot_);
    body.insert(QStringLiteral("appId"), packageId_);
    const QString path = args.value(QStringLiteral("path")).toString();
    const bool insideApp = path == appRoot_ || path.startsWith(appRoot_ + QLatin1Char('/'));
    const bool useGrant = !writeToken_.isEmpty() && !insideApp;
    if (useGrant) body.insert(QStringLiteral("writeToken"), writeToken_);
    const bool write = op == QLatin1String("write") || op == QLatin1String("mkdir")
        || op == QLatin1String("rename") || op == QLatin1String("remove");
    if (write && !useGrant) body.insert(QStringLiteral("writeRoot"), appRoot_);
    return broker_->requestSync(op, body).toVariantMap();
}

void FileApi::requestWriteAccess()
{
    if (!allowed()) return;
    emit writeAccessRequested(instance_, packageId_);
}

void FileApi::setWriteGrant(const QString &root, const QString &token)
{
    writeRoot_ = root;
    writeToken_ = token;
    emit writeGrantChanged();
}

void FileApi::clearWriteGrant()
{
    writeRoot_.clear();
    writeToken_.clear();
    emit writeGrantChanged();
}

qint64 FileApi::writeGrantExpiresAt() const
{
    return broker_ && !writeToken_.isEmpty() ? broker_->grantExpiresAt(writeToken_) : 0;
}
