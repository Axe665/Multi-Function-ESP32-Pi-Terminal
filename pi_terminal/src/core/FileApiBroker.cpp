#include "core/FileApiBroker.h"

#include "files/FileProtocol.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>
#include <QSettings>
#include <QStandardPaths>
#include <QThread>

namespace {
QString runtimeDir()
{
    QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (runtime.isEmpty()) runtime = QDir::tempPath();
    return runtime;
}
}  // namespace

FileApiBroker::FileApiBroker(QObject *parent) : QObject(parent)
{
    socketPath_ = qEnvironmentVariable("ORANGE_PI_FILE_SOCKET");
    if (socketPath_.isEmpty())
        socketPath_ = runtimeDir() + QStringLiteral("/orange-pi-file.sock");
}

FileApiBroker::~FileApiBroker()
{
    if (socket_) socket_->abort();
    if (daemonProcess_ && daemonProcess_->state() != QProcess::NotRunning) {
        daemonProcess_->terminate();
        daemonProcess_->waitForFinished(1000);
    }
}

QString FileApiBroker::tokenPath() const
{
    const QString override = qEnvironmentVariable("ORANGE_PI_FILE_TOKEN");
    if (!override.isEmpty()) return override;
    return runtimeDir() + QStringLiteral("/orange-pi-file.token");
}

QString FileApiBroker::defaultSocketPath() const
{
    return socketPath_;
}

void FileApiBroker::ensureToken()
{
    const QString path = tokenPath();
    QFile file(path);
    if (file.exists() && file.open(QIODevice::ReadOnly)) {
        token_ = QString::fromUtf8(file.readAll()).trimmed();
        if (!token_.isEmpty()) return;
    }
    QByteArray bytes(32, Qt::Uninitialized);
    for (int i = 0; i < bytes.size(); ++i)
        bytes[i] = char(QRandomGenerator::system()->bounded(256));
    token_ = QString::fromLatin1(bytes.toHex());
    QFile out(path);
    if (out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        out.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
        out.write(token_.toUtf8());
    }
}

bool FileApiBroker::connectSocket(int timeoutMs)
{
    if (!socket_) socket_ = new QLocalSocket(this);
    if (socket_->state() == QLocalSocket::ConnectedState) return true;
    if (socket_->state() != QLocalSocket::UnconnectedState) socket_->abort();
    socket_->connectToServer(socketPath_);
    if (socket_->waitForConnected(timeoutMs)) return true;
    socket_->abort();
    return false;
}

bool FileApiBroker::ensureStarted()
{
    if (ready()) return true;
    ensureToken();
    if (connectSocket(200)) return true;

    // 生产：systemd user service；测试/开发可指到构建目录的 daemon。
    QProcess service;
    service.start(QStringLiteral("systemctl"),
                  {QStringLiteral("--user"), QStringLiteral("start"),
                   QStringLiteral("orange-pi-file-daemon.service")});
    service.waitForFinished(800);
    for (int i = 0; i < 8 && !ready(); ++i) {
        QThread::msleep(50);
        connectSocket(100);
    }
    if (ready()) return true;

    QString binary = qEnvironmentVariable("ORANGE_PI_FILE_DAEMON");
    if (binary.isEmpty())
        binary = QCoreApplication::applicationDirPath() + QStringLiteral("/orange-pi-file-daemon");
    if (QFileInfo::exists(binary)) {
        daemonProcess_ = new QProcess(this);
        daemonProcess_->setProgram(binary);
        daemonProcess_->setArguments({QStringLiteral("--socket"), socketPath_,
                                      QStringLiteral("--token-file"), tokenPath()});
        daemonProcess_->setProcessChannelMode(QProcess::MergedChannels);
        daemonProcess_->start();
        for (int i = 0; i < 40 && !ready(); ++i) {
            QThread::msleep(50);
            connectSocket(100);
        }
    }
    if (ready()) return true;
    lastError_ = QStringLiteral("file daemon unavailable: %1").arg(socketPath_);
    return false;
}

QJsonObject FileApiBroker::sendAndWait(const QJsonObject &request, int timeoutMs)
{
    if (!socket_ || socket_->state() != QLocalSocket::ConnectedState) {
        lastError_ = QStringLiteral("file daemon not connected");
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};
    }
    socket_->write(FileProtocol::encode(request));
    if (!socket_->waitForBytesWritten(timeoutMs)) {
        lastError_ = QStringLiteral("file daemon write timeout");
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};
    }
    QByteArray buffer;
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < timeoutMs) {
        if (socket_->bytesAvailable() == 0 && !socket_->waitForReadyRead(100))
            continue;
        buffer += socket_->readAll();
        while (buffer.size() >= 4) {
            const quint32 declared = quint32(quint8(buffer[0]))
                | (quint32(quint8(buffer[1])) << 8)
                | (quint32(quint8(buffer[2])) << 16)
                | (quint32(quint8(buffer[3])) << 24);
            if (declared > quint32(FileProtocol::kMaxFrameBytes)) {
                lastError_ = QStringLiteral("file daemon frame too large");
                return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};
            }
            if (quint32(buffer.size()) < declared + 4) break;
            const QByteArray frame = buffer.left(int(declared) + 4);
            buffer.remove(0, int(declared) + 4);
            const QJsonObject response = FileProtocol::decode(frame);
            if (response.value(QStringLiteral("request_id")).toDouble()
                != request.value(QStringLiteral("request_id")).toDouble())
                continue;
            return response;
        }
    }
    lastError_ = QStringLiteral("file daemon timeout");
    return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};
}

QJsonObject FileApiBroker::requestSync(const QString &op, const QJsonObject &input,
                                      int timeoutMs)
{
    ensureToken();
    QJsonObject params = input;
    const QString appId = params.take(QStringLiteral("appId")).toString();
    const QString writeToken = params.take(QStringLiteral("writeToken")).toString();
    const bool writeOp = op == QLatin1String("write") || op == QLatin1String("mkdir")
        || op == QLatin1String("rename") || op == QLatin1String("remove");
    QString selectedRoot = params.take(QStringLiteral("selectedRoot")).toString();
    QString writeRoot = params.take(QStringLiteral("writeRoot")).toString();
    qint64 expiresAt = QDateTime::currentSecsSinceEpoch() + 3600;
    if (!writeToken.isEmpty()) {
        const auto grant = writeGrants_.constFind(writeToken);
        if (grant == writeGrants_.constEnd() || grant->appId != appId
            || grant->expiresAt <= QDateTime::currentSecsSinceEpoch()) {
            lastError_ = QStringLiteral("invalid or expired write grant");
            return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};
        }
        selectedRoot = grant->root;
        if (writeOp) writeRoot = grant->root;
        expiresAt = grant->expiresAt;
    }
    if (!ensureStarted())
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), lastError_}};

    QJsonObject capability{
        {QStringLiteral("appId"), appId.isEmpty() ? QStringLiteral("internal") : appId},
        {QStringLiteral("appRoot"), params.value(QStringLiteral("appRoot")).toString()},
        {QStringLiteral("readRoot"), selectedRoot},
        {QStringLiteral("writeRoot"), writeRoot},
        {QStringLiteral("expires"), expiresAt}};
    QJsonObject body = params;
    body.remove(QStringLiteral("appRoot"));
    body.insert(QStringLiteral("op"), op);
    body.insert(QStringLiteral("token"), token_);
    body.insert(QStringLiteral("capability"), capability);
    body.insert(QStringLiteral("capability_sig"),
                QString::fromLatin1(FileProtocol::signCapability(token_, capability)));
    const quint64 id = nextRequestId_++;
    body.insert(QStringLiteral("request_id"), static_cast<double>(id));
    QJsonObject request = FileProtocol::request(id, op);
    for (auto it = body.begin(); it != body.end(); ++it) request.insert(it.key(), it.value());
    return sendAndWait(request, timeoutMs);
}

QString FileApiBroker::grantKey(const QString &appId) const
{
    return QStringLiteral("files/grants/") + QString::fromLatin1(appId.toUtf8().toHex());
}

void FileApiBroker::persistGrant(const WriteGrant &grant)
{
    QSettings settings;
    settings.setValue(grantKey(grant.appId),
                      QJsonObject{{QStringLiteral("root"), grant.root},
                                  {QStringLiteral("expires"), grant.expiresAt}});
    settings.sync();
}

QString FileApiBroker::grantWrite(const QString &appId, const QString &path, int ttlSeconds)
{
    const QString root = QFileInfo(path).canonicalFilePath();
    if (appId.isEmpty() || root.isEmpty() || ttlSeconds <= 0) return {};
    QByteArray bytes(16, Qt::Uninitialized);
    for (int i = 0; i < bytes.size(); ++i)
        bytes[i] = char(QRandomGenerator::system()->bounded(256));
    const QString token = QString::fromLatin1(bytes.toHex());
    const WriteGrant grant{appId, root,
                           QDateTime::currentSecsSinceEpoch() + ttlSeconds};
    writeGrants_.insert(token, grant);
    persistGrant(grant);
    return token;
}

QString FileApiBroker::restoreWrite(const QString &appId)
{
    if (appId.isEmpty()) return {};
    QSettings settings;
    const QJsonObject stored = settings.value(grantKey(appId)).toJsonObject();
    const QString root = stored.value(QStringLiteral("root")).toString();
    const qint64 expiresAt = stored.value(QStringLiteral("expires")).toInteger();
    if (root.isEmpty() || expiresAt <= QDateTime::currentSecsSinceEpoch()) {
        settings.remove(grantKey(appId));
        return {};
    }
    if (!QFileInfo::exists(root)) {
        settings.remove(grantKey(appId));
        return {};
    }
    QByteArray bytes(16, Qt::Uninitialized);
    for (int i = 0; i < bytes.size(); ++i)
        bytes[i] = char(QRandomGenerator::system()->bounded(256));
    const QString token = QString::fromLatin1(bytes.toHex());
    writeGrants_.insert(token, WriteGrant{appId, root, expiresAt});
    return token;
}

void FileApiBroker::revokeWrites(const QString &appId, bool forget)
{
    for (auto it = writeGrants_.begin(); it != writeGrants_.end();) {
        if (it->appId == appId) it = writeGrants_.erase(it);
        else ++it;
    }
    if (!forget) return;
    QSettings settings;
    settings.remove(grantKey(appId));
}

qint64 FileApiBroker::grantExpiresAt(const QString &token) const
{
    const auto grant = writeGrants_.constFind(token);
    return grant == writeGrants_.constEnd() ? 0 : grant->expiresAt;
}

QString FileApiBroker::appDataRoot(const QString &packageId) const
{
    QString safe = packageId;
    for (int i = 0; i < safe.size(); ++i) {
        const QChar c = safe.at(i);
        if (!(c.isLetterOrNumber() || c == QLatin1Char('.') || c == QLatin1Char('-')
              || c == QLatin1Char('_')))
            safe[i] = QLatin1Char('_');
    }
    if (safe.isEmpty()) safe = QStringLiteral("unknown");
    const QString root = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QStringLiteral("/orange-pi-terminal/apps/") + safe;
    QDir().mkpath(root);
    return root;
}
