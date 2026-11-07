#include "files/FileDaemonServer.h"

#include "files/FileProtocol.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QLocalServer>
#include <QLocalSocket>
#include <QPointer>
#include <QSaveFile>
#include <QStandardPaths>

#include <sys/socket.h>
#include <unistd.h>

namespace {

QString canonicalFor(const QString &path)
{
    if (path.isEmpty() || !QDir::isAbsolutePath(path)) return {};
    const QFileInfo info(path);
    if (info.exists()) return info.canonicalFilePath();
    const QFileInfo parent(info.absolutePath());
    if (!parent.exists() || parent.canonicalFilePath().isEmpty()) return {};
    return parent.canonicalFilePath() + QLatin1Char('/') + info.fileName();
}

bool within(const QString &path, const QString &root)
{
    if (path.isEmpty() || root.isEmpty()) return false;
    return path == root || path.startsWith(root + QLatin1Char('/'));
}

bool sensitivePath(const QString &path, const QString &appRoot)
{
    if (within(path, appRoot)) return false;
    const QStringList parts = path.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    if (parts.contains(QStringLiteral(".ssh")) || parts.contains(QStringLiteral(".gnupg"))
        || parts.contains(QStringLiteral(".pki")) || parts.contains(QStringLiteral(".password-store")))
        return true;
    const QString tail = parts.mid(qMax(0, parts.size() - 5)).join(QLatin1Char('/'));
    if (tail.contains(QStringLiteral(".local/share/keyrings")))
        return true;
    const QString relative = tail;
    if (relative.contains(QStringLiteral(".config/orange-pi-terminal")))
        return true;
    if (relative.contains(QStringLiteral(".local/share/ModularTerminal")))
        return true;
    if (relative.contains(QStringLiteral(".local/share/orange-pi-terminal")))
        return true;
    const QString name = parts.isEmpty() ? QString() : parts.last();
    return name == QLatin1String(".netrc") || name == QLatin1String(".git-credentials");
}

QJsonObject fileInfoJson(const QFileInfo &info)
{
    return {{QStringLiteral("name"), info.fileName()},
            {QStringLiteral("path"), info.absoluteFilePath()},
            {QStringLiteral("isDir"), info.isDir()},
            {QStringLiteral("size"), static_cast<double>(info.size())},
            {QStringLiteral("modified"), static_cast<double>(info.lastModified().toMSecsSinceEpoch())}};
}

}  // namespace

FileDaemonServer::FileDaemonServer(QString socketPath, QString token, QObject *parent)
    : QObject(parent), socketPath_(std::move(socketPath)), token_(std::move(token)),
      home_(QFileInfo(QDir::homePath()).canonicalFilePath())
{
}

bool FileDaemonServer::start()
{
    if (token_.isEmpty()) {
        error_ = QStringLiteral("empty token");
        return false;
    }
    QFile::remove(socketPath_);
    server_ = new QLocalServer(this);
    server_->setSocketOptions(QLocalServer::UserAccessOption);
    if (!server_->listen(socketPath_)) {
        error_ = server_->errorString();
        return false;
    }
    connect(server_, &QLocalServer::newConnection, this, &FileDaemonServer::onNewConnection);
    return true;
}

void FileDaemonServer::onNewConnection()
{
    while (server_->hasPendingConnections()) {
        auto *socket = server_->nextPendingConnection();
        ucred credentials{};
        socklen_t size = sizeof(credentials);
        if (getsockopt(socket->socketDescriptor(), SOL_SOCKET, SO_PEERCRED,
                       &credentials, &size) == 0
            && credentials.uid != getuid()) {
            socket->disconnectFromServer();
            socket->deleteLater();
            continue;
        }
        connect(socket, &QLocalSocket::readyRead, this,
                [this, socket] { onReadyRead(socket); });
        connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
    }
}

void FileDaemonServer::onReadyRead(QLocalSocket *socket)
{
    QByteArray buffer = socket->property("buffer").toByteArray();
    buffer += socket->readAll();
    while (buffer.size() >= 4) {
        const quint32 declared = quint32(quint8(buffer[0]))
            | (quint32(quint8(buffer[1])) << 8)
            | (quint32(quint8(buffer[2])) << 16)
            | (quint32(quint8(buffer[3])) << 24);
        if (declared > quint32(FileProtocol::kMaxFrameBytes)) {
            socket->disconnectFromServer();
            delete socket;
            return;
        }
        if (quint32(buffer.size()) < declared + 4) break;
        const QByteArray frame = buffer.left(int(declared) + 4);
        buffer.remove(0, int(declared) + 4);
        dispatch(socket, frame);
    }
    socket->setProperty("buffer", buffer);
}

void FileDaemonServer::dispatch(QLocalSocket *socket, const QByteArray &frame)
{
    const QJsonObject request = FileProtocol::decode(frame);
    const quint64 id = static_cast<quint64>(request.value(QStringLiteral("request_id")).toDouble());
    QJsonObject response;
    if (request.isEmpty()) {
        response = FileProtocol::response(id, false, {}, QStringLiteral("bad frame"));
    } else if (request.value(QStringLiteral("token")).toString() != token_) {
        response = FileProtocol::response(id, false, {}, QStringLiteral("auth failed"));
    } else {
        response = FileProtocol::response(id, true, handle(request));
        if (!response.value(QStringLiteral("ok")).toBool(true))
            response = FileProtocol::response(id, false, response,
                                              response.value(QStringLiteral("error")).toString());
    }
    socket->write(FileProtocol::encode(response));
}

QJsonObject FileDaemonServer::handle(const QJsonObject &request)
{
    const QString op = request.value(QStringLiteral("op")).toString();
    if (op == QLatin1String("ping")) return {};
    const QString path = canonicalFor(request.value(QStringLiteral("path")).toString());
    auto error = [](const QString &text) { return QJsonObject{{QStringLiteral("ok"), false},
                                                              {QStringLiteral("error"), text}}; };

    // 能力令牌由宿主用 daemon 会话 token 做 HMAC；模块无法伪造 appRoot/
    // writeRoot/readRoot。root 只从签名后的 capability 读取。
    const QJsonObject capability = request.value(QStringLiteral("capability")).toObject();
    const QString signature = request.value(QStringLiteral("capability_sig")).toString();
    if (op != QLatin1String("ping")) {
        if (capability.isEmpty()) return error(QStringLiteral("capability required"));
        if (signature != QString::fromLatin1(FileProtocol::signCapability(token_, capability)))
            return error(QStringLiteral("capability signature invalid"));
        if (capability.value(QStringLiteral("expires")).toInteger()
            <= QDateTime::currentSecsSinceEpoch())
            return error(QStringLiteral("capability expired"));
        if (capability.value(QStringLiteral("appId")).toString().isEmpty())
            return error(QStringLiteral("capability appId missing"));
    }

    const QString appRoot = canonicalFor(
        capability.value(QStringLiteral("appRoot")).toString());
    const QString selectedRoot = canonicalFor(
        capability.value(QStringLiteral("readRoot")).toString());
    const QString writeRoot = canonicalFor(
        capability.value(QStringLiteral("writeRoot")).toString());

    if (path.isEmpty()) return error(QStringLiteral("invalid path"));
    const bool inHome = within(path, home_);
    const bool inSelected = !selectedRoot.isEmpty() && within(path, selectedRoot);
    if (!inHome && !inSelected) return error(QStringLiteral("path outside allowed roots"));
    if (inHome && sensitivePath(path, appRoot))
        return error(QStringLiteral("sensitive path denied"));
    const bool write = op == QLatin1String("write") || op == QLatin1String("mkdir")
        || op == QLatin1String("rename") || op == QLatin1String("remove");
    if (write && (writeRoot.isEmpty() || !within(path, writeRoot))) {
        return error(QStringLiteral("write root denied"));
    }

    if (op == QLatin1String("stat")) {
        const QFileInfo info(path);
        if (!info.exists()) return error(QStringLiteral("not found"));
        return fileInfoJson(info);
    }
    if (op == QLatin1String("list")) {
        QDir dir(path);
        if (!dir.exists()) return error(QStringLiteral("not found"));
        QJsonArray entries;
        const auto list = dir.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot);
        for (const QFileInfo &entry : list) entries.append(fileInfoJson(entry));
        return {{QStringLiteral("entries"), entries}};
    }
    if (op == QLatin1String("read")) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) return error(file.errorString());
        const qint64 offset = qMax<qint64>(0, request.value(QStringLiteral("offset")).toInteger());
        const qint64 length = qBound<qint64>(qint64(1),
            request.value(QStringLiteral("length")).toInteger(256 * 1024),
            qint64(FileProtocol::kMaxChunkBytes));
        if (!file.seek(offset)) return error(QStringLiteral("seek failed"));
        const QByteArray data = file.read(length);
        return {{QStringLiteral("dataBase64"), QString::fromLatin1(data.toBase64())},
                {QStringLiteral("eof"), file.atEnd()}};
    }
    if (op == QLatin1String("write")) {
        const QByteArray data = QByteArray::fromBase64(
            request.value(QStringLiteral("dataBase64")).toString().toLatin1());
        if (data.size() > FileProtocol::kMaxChunkBytes) return error(QStringLiteral("chunk too large"));
        QFile file(path);
        QIODevice::OpenMode mode = QIODevice::ReadWrite;
        if (request.value(QStringLiteral("truncate")).toBool()) mode |= QIODevice::Truncate;
        if (!file.open(mode)) return error(file.errorString());
        qint64 offset = request.value(QStringLiteral("offset")).toInteger(-1);
        if (offset < 0) offset = file.size();
        if (!file.seek(offset)) return error(QStringLiteral("seek failed"));
        if (file.write(data) != data.size()) return error(file.errorString());
        file.flush();
        return {{QStringLiteral("written"), data.size()}};
    }
    if (op == QLatin1String("mkdir")) {
        if (!QDir().mkpath(path)) return error(QStringLiteral("mkdir failed"));
        return {};
    }
    if (op == QLatin1String("rename")) {
        const QString target = canonicalFor(request.value(QStringLiteral("target")).toString());
        if (target.isEmpty() || !within(target, writeRoot))
            return error(QStringLiteral("rename target denied"));
        if (!QFile::rename(path, target)) return error(QStringLiteral("rename failed"));
        return {};
    }
    if (op == QLatin1String("remove")) {
        if (path == writeRoot || path == home_) return error(QStringLiteral("refuse root removal"));
        const bool recursive = request.value(QStringLiteral("recursive")).toBool();
        QFileInfo info(path);
        bool ok = false;
        if (info.isDir()) ok = recursive ? QDir(path).removeRecursively() : QDir().rmdir(path);
        else ok = QFile::remove(path);
        if (!ok) return error(QStringLiteral("remove failed"));
        return {};
    }
    if (op == QLatin1String("ping")) return {};
    return error(QStringLiteral("unknown op"));
}
