#include "net/ProxyServer.h"

#include "net/NetChannels.h"
#include "net/PublicNetwork.h"

#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

#include <atomic>
#include <functional>

namespace {

// 被拒的请求要能在日志里核对，又不能刷屏。
std::atomic_int s_denied { 0 };
std::atomic_int s_allowed { 0 };

bool isMusicLocalNode(const QString &channel, const QString &host, quint16 port,
                      bool tunneling)
{
    return channel == QLatin1String(NetChannels::Music) && !tunneling
        && port == 3000 && host == QLatin1String("127.0.0.1");
}

void logDenied(const QString &channel, const QByteArray &line, const QString &why,
               int status)
{
    const int count = ++s_denied;
    if (count == 1 || count % 20 == 0) {
        qInfo("net-proxy: deny #%d channel=%s status=%d why=%s line=%.120s", count,
              qPrintable(channel), status, qPrintable(why), line.constData());
    }
}

QByteArray reasonPhrase(int status)
{
    switch (status) {
    case 400: return QByteArrayLiteral("Bad Request");
    case 403: return QByteArrayLiteral("Forbidden");
    case 502: return QByteArrayLiteral("Bad Gateway");
    default: return QByteArrayLiteral("Error");
    }
}

QByteArray bodyFor(int status)
{
    switch (status) {
    case 400: return QByteArrayLiteral("bad request");
    case 403: return QByteArrayLiteral("network access denied");
    case 502: return QByteArrayLiteral("bad gateway");
    default: return QByteArrayLiteral("proxy error");
    }
}

QByteArray headerName(const QByteArray &line)
{
    const int colon = line.indexOf(':');
    if (colon <= 0) return {};
    return line.left(colon).trimmed().toLower();
}

QByteArray headerValue(const QByteArray &line)
{
    const int colon = line.indexOf(':');
    if (colon <= 0) return {};
    return line.mid(colon + 1).trimmed();
}

QByteArray hostHeaderValue(const QString &host, quint16 port)
{
    QString value = host;
    if (value.contains(QLatin1Char(':')) && !value.startsWith(QLatin1Char('[')))
        value = QLatin1Char('[') + value + QLatin1Char(']');
    if (port != 80) value += QLatin1Char(':') + QString::number(port);
    return value.toUtf8();
}

// 一条客户端连接的完整生命周期：收请求头 → 判通道 → 连上游 → 双向转发。
// 不做 keep-alive 复用（一条客户端连接对应一条上游连接），先求可推理。
class Session : public QObject {
public:
    Session(QString channel, QTcpSocket *client,
            std::function<bool(const QString &)> channelAllowed,
            std::function<bool(const QString &, const QString &, quint16, bool)> targetAllowed)
        : QObject(client), channel_(std::move(channel)), client_(client),
          channelAllowed_(std::move(channelAllowed)), targetAllowed_(std::move(targetAllowed))
    {
        timer_ = new QTimer(this);
        timer_->setSingleShot(true);
        timer_->setInterval(15000);
        QObject::connect(timer_, &QTimer::timeout, this, [this] {
            reject(502, QStringLiteral("upstream-timeout"));
        });
        timer_->start();
        QObject::connect(client_, &QTcpSocket::readyRead, this, &Session::onClientReady);
        QObject::connect(client_, &QTcpSocket::disconnected, this, &Session::close);
    }

private:
    void onClientReady()
    {
        if (tunneling_) {
            if (upstream_) upstream_->write(client_->readAll());
            return;
        }
        buffer_ += client_->readAll();
        const int split = buffer_.indexOf("\r\n\r\n");
        if (split < 0) {
            if (buffer_.size() > 16384) reject(400, QStringLiteral("header-too-large"));
            return;
        }
        const QByteArray head = buffer_.left(split + 4);
        if (head.size() > 16384) {
            reject(400, QStringLiteral("header-too-large"));
            return;
        }
        rest_ = buffer_.mid(split + 4);
        buffer_.clear();
        firstLine_ = head.left(head.indexOf("\r\n"));

        if (!channelAllowed_(channel_)) {
            reject(403, QStringLiteral("channel-off"));
            return;
        }

        const QList<QByteArray> parts = firstLine_.split(' ');
        if (parts.size() != 3 || parts.at(2).isEmpty()) {
            reject(400, QStringLiteral("bad-request-line"));
            return;
        }
        const QByteArray method = parts.at(0).toUpper();
        const QByteArray version = parts.at(2);
        if (!version.startsWith("HTTP/")) {
            reject(400, QStringLiteral("bad-http-version"));
            return;
        }

        QString host;
        quint16 port = 0;
        if (method == "CONNECT") {
            const QString authority = QString::fromLatin1(parts.at(1));
            if (authority.startsWith(QLatin1Char('['))) {
                const int close = authority.indexOf(QLatin1Char(']'));
                if (close <= 0) {
                    reject(400, QStringLiteral("bad-authority"));
                    return;
                }
                host = authority.mid(1, close - 1);
                if (close + 1 >= authority.size() || authority.at(close + 1) != QLatin1Char(':')) {
                    reject(400, QStringLiteral("bad-authority"));
                    return;
                }
                port = static_cast<quint16>(authority.mid(close + 2).toUShort());
            } else {
                const int colon = authority.lastIndexOf(QLatin1Char(':'));
                if (colon <= 0) {
                    reject(400, QStringLiteral("bad-authority"));
                    return;
                }
                host = authority.left(colon);
                port = static_cast<quint16>(authority.mid(colon + 1).toUShort());
            }
            if (host.isEmpty() || port == 0) {
                reject(400, QStringLiteral("bad-target"));
                return;
            }
            if (!targetAllowed_(channel_, host, port, true)) {
                reject(403, QStringLiteral("target-not-public"));
                return;
            }
            startTunnel(host, port, true, {});
            return;
        }

        const QUrl url(QString::fromLatin1(parts.at(1)));
        if (!url.isValid() || url.host().isEmpty()) {
            reject(400, QStringLiteral("bad-absolute-uri"));
            return;
        }
        if (url.scheme().compare(QStringLiteral("http"), Qt::CaseInsensitive) != 0) {
            // HTTPS 必须走 CONNECT；明文代理不能替客户端做 TLS。
            reject(400, QStringLiteral("unsupported-scheme"));
            return;
        }
        host = url.host();
        port = static_cast<quint16>(url.port(80));
        if (host.isEmpty() || port == 0) {
            reject(400, QStringLiteral("bad-target"));
            return;
        }
        if (!targetAllowed_(channel_, host, port, false)) {
            reject(403, QStringLiteral("target-not-public"));
            return;
        }

        QByteArray forwardHead;
        QString why;
        if (!buildForwardHead(head, method, version, url, host, port, &forwardHead, &why)) {
            reject(400, why);
            return;
        }
        startTunnel(host, port, false, forwardHead);
    }

    // 把代理形式的绝对 URI 改写成 origin-form，并清掉 hop-by-hop 头。
    // 不清理 Transfer-Encoding/Content-Length：本代理不拆包，只做字节转发。
    bool buildForwardHead(const QByteArray &head, const QByteArray &method,
                          const QByteArray &version, const QUrl &url,
                          const QString &host, quint16 port, QByteArray *out,
                          QString *why)
    {
        QByteArray target = url.path(QUrl::FullyEncoded).toUtf8();
        if (target.isEmpty()) target = QByteArrayLiteral("/");
        const QByteArray query = url.query(QUrl::FullyEncoded).toUtf8();
        if (!query.isEmpty()) target += '?' + query;

        const QList<QByteArray> rawLines = head.split('\n');
        QList<QByteArray> lines;
        lines.reserve(rawLines.size());
        for (QByteArray line : rawLines) {
            if (line.endsWith('\r')) line.chop(1);
            lines.append(line);
        }

        QSet<QByteArray> connectionTokens;
        for (int i = 1; i < lines.size(); ++i) {
            if (lines.at(i).isEmpty()) continue;
            const QByteArray name = headerName(lines.at(i));
            if (name.isEmpty()) {
                *why = QStringLiteral("bad-header");
                return false;
            }
            if (name == QByteArrayLiteral("connection")) {
                const QList<QByteArray> tokens = headerValue(lines.at(i)).split(',');
                for (const QByteArray &token : tokens) {
                    const QByteArray trimmed = token.trimmed().toLower();
                    if (!trimmed.isEmpty()) connectionTokens.insert(trimmed);
                }
            }
        }

        static const QSet<QByteArray> fixedHopByHop {
            QByteArrayLiteral("proxy-connection"), QByteArrayLiteral("proxy-authorization"),
            QByteArrayLiteral("connection"), QByteArrayLiteral("keep-alive"),
            QByteArrayLiteral("te"), QByteArrayLiteral("trailer"),
            QByteArrayLiteral("upgrade"),
        };

        QByteArray result = method + ' ' + target + ' ' + version + "\r\n";
        bool hostSeen = false;
        for (int i = 1; i < lines.size(); ++i) {
            const QByteArray &line = lines.at(i);
            if (line.isEmpty()) continue;
            const QByteArray name = headerName(line);
            if (name == QByteArrayLiteral("host")) hostSeen = true;
            const bool framing = name == QByteArrayLiteral("content-length")
                || name == QByteArrayLiteral("transfer-encoding");
            if (!framing && (fixedHopByHop.contains(name) || connectionTokens.contains(name)))
                continue;
            result += line + "\r\n";
        }
        if (!hostSeen) result += "Host: " + hostHeaderValue(host, port) + "\r\n";
        result += "\r\n";
        *out = result;
        return true;
    }

    void startTunnel(const QString &host, quint16 port, bool isConnect,
                     const QByteArray &forwardHead)
    {
        forwardHead_ = forwardHead;
        // 放行也要留痕：否则只能证明"被拒了"，证明不了"确实经过了代理"。
        const int count = ++s_allowed;
        if (count == 1 || count % 20 == 0)
            qInfo("net-proxy: allow #%d channel=%s target=%s:%u connect=%d", count,
                  qPrintable(channel_), qPrintable(host), port, isConnect ? 1 : 0);
        upstream_ = new QTcpSocket(this);
        QObject::connect(upstream_, &QTcpSocket::connected, this, [this, isConnect] {
            if (timer_) timer_->stop();
            tunneling_ = true;
            if (isConnect)
                client_->write("HTTP/1.1 200 Connection Established\r\n\r\n");
            if (!forwardHead_.isEmpty()) {
                upstream_->write(forwardHead_);
                forwardHead_.clear();
            }
            // 握手期间客户端可能已经发了数据，先补投。
            if (!rest_.isEmpty()) {
                upstream_->write(rest_);
                rest_.clear();
            }
            QObject::connect(upstream_, &QTcpSocket::readyRead, this,
                             [this] { client_->write(upstream_->readAll()); });
            QObject::connect(upstream_, &QTcpSocket::disconnected, this,
                             [this] { finishClient(); });
        });
        QObject::connect(upstream_, &QTcpSocket::errorOccurred, this,
                         [this](QAbstractSocket::SocketError) {
            if (!tunneling_) reject(502, QStringLiteral("upstream-unreachable"));
            else finishClient();
        });
        upstream_->connectToHost(host, port);
    }

    // 上游正常关闭时不能立刻 abort 客户端：响应还在客户端 socket 的写缓冲里。
    // 先 flush + 优雅断开，再给事件循环一点时间收尾。
    void finishClient()
    {
        if (closing_ || clientFinishing_) return;
        clientFinishing_ = true;
        if (client_) {
            client_->flush();
            client_->disconnectFromHost();
        }
        QTimer::singleShot(200, this, [this] { close(); });
    }

    void reject(int status, const QString &why)
    {
        logDenied(channel_, firstLine_, why, status);
        if (client_ && client_->state() == QAbstractSocket::ConnectedState) {
            const QByteArray body = bodyFor(status);
            client_->write("HTTP/1.1 " + QByteArray::number(status) + ' '
                           + reasonPhrase(status) + "\r\n"
                           "Content-Type: text/plain; charset=utf-8\r\n"
                           "Content-Length: " + QByteArray::number(body.size()) + "\r\n"
                           "Connection: close\r\n\r\n" + body);
            client_->flush();
            client_->disconnectFromHost();
            // 给内核一点时间把响应发出去；close() 会 abort 客户端 socket。
            QTimer::singleShot(200, this, [this] { close(); });
            return;
        }
        close();
    }

    void close()
    {
        if (closing_) return;
        closing_ = true;
        if (timer_) timer_->stop();
        if (upstream_) {
            upstream_->disconnect(this);
            upstream_->abort();
            upstream_->deleteLater();
            upstream_ = nullptr;
        }
        if (client_) {
            client_->disconnect(this);
            client_->abort();
            client_->deleteLater();
            client_ = nullptr;
        }
        deleteLater();
    }

    QString channel_;
    QTcpSocket *client_ = nullptr;
    QTcpSocket *upstream_ = nullptr;
    QTimer *timer_ = nullptr;
    QByteArray buffer_;
    QByteArray rest_;
    QByteArray firstLine_;
    QByteArray forwardHead_;
    bool tunneling_ = false;
    bool closing_ = false;
    bool clientFinishing_ = false;
    std::function<bool(const QString &)> channelAllowed_;
    std::function<bool(const QString &, const QString &, quint16, bool)> targetAllowed_;
};

}  // namespace

ProxyServer::ProxyServer(const QList<Channel> &channels, QString policyPath,
                         QObject *parent, bool allowLoopbackForTests)
    : QObject(parent), channels_(channels), policyPath_(std::move(policyPath)),
      allowLoopbackForTests_(allowLoopbackForTests)
{
    if (!policyPath_.isEmpty()) {
        QObject::connect(&watcher_, &QFileSystemWatcher::fileChanged, this,
                         [this] { reloadPolicy(); });
        QObject::connect(&watcher_, &QFileSystemWatcher::directoryChanged, this,
                         [this] { reloadPolicy(); });
    }
    reloadPolicy();
}

void ProxyServer::reloadPolicy()
{
    // 策略文件不存在 = 还没人告诉过我们谁能出网 → 全拒（fail-closed）。
    QHash<QString, ChannelPolicy> next;
    QFile file(policyPath_);
    if (policyPath_.isEmpty() || !file.open(QIODevice::ReadOnly)) {
        for (const Channel &channel : channels_)
            next.insert(channel.name, ChannelPolicy{});
        policy_ = next;
        qWarning("net-proxy: policy missing (%s), denying every channel",
                 qPrintable(policyPath_));
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const QJsonObject channels = root.value(QStringLiteral("channels")).toObject();
    for (const Channel &channel : channels_) {
        ChannelPolicy parsed;
        const QJsonValue value = channels.value(channel.name);
        if (value.isBool()) {
            // 兼容旧测试/旧策略；生产宿主已写对象。
            parsed.enabled = value.toBool();
        } else if (value.isObject()) {
            const QJsonObject entry = value.toObject();
            // v4 只有 enabled；旧文件里残留的 restricted/hosts 一律忽略。
            parsed.enabled = entry.value(QStringLiteral("enabled")).toBool(false);
        }
        // 缺键按禁用：宁可拒绝，也不因为一个拼写错误就静默放行。
        next.insert(channel.name, parsed);
    }
    policy_ = next;

    // 文件被原子替换（rename）后监听句柄会失效，重新挂一次。
    if (QFileInfo::exists(policyPath_) && !watcher_.files().contains(policyPath_))
        watcher_.addPath(policyPath_);
    const QString directory = QFileInfo(policyPath_).absolutePath();
    if (!directory.isEmpty() && !watcher_.directories().contains(directory))
        watcher_.addPath(directory);

    QStringList allowed;
    for (auto it = policy_.cbegin(); it != policy_.cend(); ++it)
        if (it.value().enabled) allowed << it.key();
    qInfo("net-proxy: policy loaded, allowed=[%s]", qPrintable(allowed.join(QLatin1Char(','))));
}

bool ProxyServer::channelAllowed(const QString &channel) const
{
    return policy_.contains(channel) && policy_.value(channel).enabled;
}

bool ProxyServer::targetAllowed(const QString &channel, const QString &host, quint16 port,
                                bool tunneling) const
{
    if (!channelAllowed(channel)) return false;
    // 应用级开关打开后仍只允许公网；音乐本机 Node 是唯一明文/内网例外。
    if (isMusicLocalNode(channel, host, port, tunneling)) return true;
    if (allowLoopbackForTests_) {
        QHostAddress literal;
        if (literal.setAddress(host) && literal.isLoopback()) return true;
    }
    return PublicNetwork::isPublicHost(host);
}

quint16 ProxyServer::portFor(const QString &channel) const
{
    QTcpServer *server = servers_.value(channel);
    return server && server->isListening() ? server->serverPort() : 0;
}

bool ProxyServer::start()
{
    for (const Channel &channel : channels_) {
        auto *server = new QTcpServer(this);
        if (!server->listen(QHostAddress::LocalHost, channel.port)) {
            qWarning("net-proxy: channel %s cannot listen on 127.0.0.1:%u (%s)",
                     qPrintable(channel.name), channel.port, qPrintable(server->errorString()));
            server->deleteLater();
            return false;
        }
        servers_.insert(channel.name, server);
        QObject::connect(server, &QTcpServer::newConnection, this, [this, channel, server] {
            while (server->hasPendingConnections()) {
                QTcpSocket *client = server->nextPendingConnection();
                if (!client) continue;
                const QString name = channel.name;
                new Session(name, client,
                            [this](const QString &which) { return channelAllowed(which); },
                            [this](const QString &which, const QString &host, quint16 port,
                                   bool tunneling) {
                                return targetAllowed(which, host, port, tunneling);
                            });
            }
        });
        qInfo("net-proxy: channel %s listening on 127.0.0.1:%u", qPrintable(channel.name),
              server->serverPort());
    }
    return true;
}

QStringList ProxyServer::listeningPorts() const
{
    QStringList out;
    for (const Channel &channel : channels_) {
        QTcpServer *server = servers_.value(channel.name);
        if (server && server->isListening())
            out << QStringLiteral("%1=%2").arg(channel.name).arg(server->serverPort());
    }
    return out;
}
