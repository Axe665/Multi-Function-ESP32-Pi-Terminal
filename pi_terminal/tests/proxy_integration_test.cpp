// 代理出站契约：CONNECT 隧道、非 CONNECT 的 origin-form 改写、hop-by-hop
// 头清理、403/400/502 状态码，以及一次真实 network_proxy 子进程冒烟。
#include <QtTest>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>

#include "net/NetChannels.h"
#include "net/ProxyServer.h"

namespace {

class OriginServer : public QTcpServer {
public:
    QStringList requests;
    QByteArray body = QByteArrayLiteral("origin-ok");

protected:
    void incomingConnection(qintptr descriptor) override
    {
        auto *socket = new QTcpSocket(this);
        socket->setSocketDescriptor(descriptor);
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
            QByteArray buffer = socket->property("buffer").toByteArray();
            buffer += socket->readAll();
            socket->setProperty("buffer", buffer);
            const int split = buffer.indexOf("\r\n\r\n");
            if (split < 0) return;
            requests << QString::fromUtf8(buffer.left(split + 4));
            socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "
                          + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n"
                          + body);
            socket->flush();
            socket->disconnectFromHost();
        });
    }
};

QByteArray policyFor(const QStringList &allowed)
{
    QJsonObject channels;
    for (const char *name : {NetChannels::Browser, NetChannels::Music, NetChannels::Tv,
                             NetChannels::Qml, NetChannels::TimeSync, NetChannels::Updates}) {
        channels.insert(QString::fromLatin1(name),
                        allowed.contains(QString::fromLatin1(name)));
    }
    const QJsonObject root{{QStringLiteral("version"), NetChannels::PolicyVersion},
                           {QStringLiteral("channels"), channels}};
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

QString writePolicy(QTemporaryDir &dir, const QStringList &allowed)
{
    const QString path = dir.filePath(QStringLiteral("policy.json"));
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return {};
    file.write(policyFor(allowed));
    file.close();
    return path;
}

QList<ProxyServer::Channel> ephemeralChannels()
{
    return {{QString::fromLatin1(NetChannels::Browser), 0},
            {QString::fromLatin1(NetChannels::Music), 0},
            {QString::fromLatin1(NetChannels::Tv), 0},
            {QString::fromLatin1(NetChannels::Qml), 0},
            {QString::fromLatin1(NetChannels::TimeSync), 0},
            {QString::fromLatin1(NetChannels::Updates), 0}};
}

bool waitForBytes(QTcpSocket &socket, int timeoutMs)
{
    QElapsedTimer timer;
    timer.start();
    while (socket.bytesAvailable() == 0 && timer.elapsed() < timeoutMs)
        QTest::qWait(10);
    return socket.bytesAvailable() > 0;
}

QByteArray getThrough(const QString &channel, quint16 port, quint16 originPort,
                      const QByteArray &extraHeaders = {})
{
    QTcpSocket client;
    client.connectToHost(QHostAddress::LocalHost, port);
    if (!client.waitForConnected(3000)) return {};
    const QByteArray request =
        "GET http://127.0.0.1:" + QByteArray::number(originPort)
        + "/weather?city=zh HTTP/1.1\r\nHost: 127.0.0.1:"
        + QByteArray::number(originPort)
        + "\r\nProxy-Connection: keep-alive\r\nConnection: X-Hop\r\nX-Hop: drop\r\n"
          "X-Keep: keep\r\nUser-Agent: proxy-test\r\n" + extraHeaders + "\r\n";
    client.write(request);
    if (!waitForBytes(client, 5000)) return {};
    QTest::qWait(30);
    QByteArray response;
    while (client.bytesAvailable() > 0) response += client.readAll();
    Q_UNUSED(channel);
    return response;
}

}  // namespace

class ProxyIntegrationTest : public QObject {
    Q_OBJECT
private slots:
    void plainHttpIsRewrittenToOriginForm()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("music"), QStringLiteral("tv"),
                                                 QStringLiteral("qml"), QStringLiteral("timesync")});
        ProxyServer proxy(ephemeralChannels(), policy, nullptr, true);
        QVERIFY(proxy.start());

        for (const char *name : {NetChannels::Music, NetChannels::Tv, NetChannels::Qml,
                                 NetChannels::TimeSync}) {
            origin.requests.clear();
            const QByteArray response = getThrough(QString::fromLatin1(name),
                                                   proxy.portFor(QString::fromLatin1(name)),
                                                   origin.serverPort());
            QVERIFY2(response.startsWith("HTTP/1.1 200"), response.constData());
            QVERIFY(response.contains("origin-ok"));
            QTRY_COMPARE(origin.requests.size(), 1);
            const QString request = origin.requests.first();
            QVERIFY2(request.startsWith(QStringLiteral("GET /weather?city=zh HTTP/1.1")),
                     qPrintable(request));
            QVERIFY2(request.contains(QStringLiteral("Host: 127.0.0.1:")), qPrintable(request));
            QVERIFY2(!request.contains(QStringLiteral("Proxy-Connection"), Qt::CaseInsensitive),
                     qPrintable(request));
            QVERIFY2(!request.contains(QStringLiteral("X-Hop:")), qPrintable(request));
            QVERIFY2(request.contains(QStringLiteral("X-Keep: keep")), qPrintable(request));
        }
    }

    void privateDestinationsAreDeniedByDefault()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("qml")});
        ProxyServer proxy(ephemeralChannels(), policy);
        QVERIFY(proxy.start());
        const quint16 qmlPort = proxy.portFor(QString::fromLatin1(NetChannels::Qml));
        // v2 没有 allowlist；应用开关打开也不代表可以访问本机/局域网。
        const QByteArray plain = getThrough(QString::fromLatin1(NetChannels::Qml), qmlPort,
                                            origin.serverPort());
        QVERIFY2(plain.startsWith("HTTP/1.1 403"), plain.constData());
        QCOMPARE(origin.requests.size(), 0);

        QTcpSocket client;
        client.connectToHost(QHostAddress::LocalHost, qmlPort);
        QVERIFY(client.waitForConnected(3000));
        client.write("CONNECT 127.0.0.1:" + QByteArray::number(origin.serverPort())
                     + " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
        QVERIFY(waitForBytes(client, 3000));
        QVERIFY(client.readAll().startsWith("HTTP/1.1 403"));
        QCOMPARE(origin.requests.size(), 0);
    }

    void localNodeHttpIsTheOnlyPlaintextException()
    {
        OriginServer origin;
        if (!origin.listen(QHostAddress::LocalHost, 3000)) QSKIP("port 3000 is busy");
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("music")});

        ProxyServer proxy(ephemeralChannels(), policy);
        QVERIFY(proxy.start());
        const QByteArray response = getThrough(QString::fromLatin1(NetChannels::Music),
                                               proxy.portFor(QString::fromLatin1(NetChannels::Music)),
                                               3000);
        QVERIFY2(response.startsWith("HTTP/1.1 200"), response.constData());
        QCOMPARE(origin.requests.size(), 1);
    }

    void deniedChannelReturns403()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {});
        ProxyServer proxy(ephemeralChannels(), policy);
        QVERIFY(proxy.start());
        const QByteArray response = getThrough(QString::fromLatin1(NetChannels::Music),
                                               proxy.portFor(QString::fromLatin1(NetChannels::Music)),
                                               origin.serverPort());
        QVERIFY2(response.startsWith("HTTP/1.1 403"), response.constData());
        QCOMPARE(origin.requests.size(), 0);
    }

    void timesyncChannelIsIndependentFromQml()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("timesync")});
        ProxyServer proxy(ephemeralChannels(), policy, nullptr, true);
        QVERIFY(proxy.start());
        const QByteArray ok = getThrough(QString::fromLatin1(NetChannels::TimeSync),
                                         proxy.portFor(QString::fromLatin1(NetChannels::TimeSync)),
                                         origin.serverPort());
        QVERIFY2(ok.startsWith("HTTP/1.1 200"), ok.constData());
        const QByteArray blocked = getThrough(QString::fromLatin1(NetChannels::Qml),
                                              proxy.portFor(QString::fromLatin1(NetChannels::Qml)),
                                              origin.serverPort());
        QVERIFY2(blocked.startsWith("HTTP/1.1 403"), blocked.constData());
    }

    void malformedAbsoluteUriReturns400()
    {
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("qml")});
        ProxyServer proxy(ephemeralChannels(), policy);
        QVERIFY(proxy.start());
        QTcpSocket client;
        client.connectToHost(QHostAddress::LocalHost,
                             proxy.portFor(QString::fromLatin1(NetChannels::Qml)));
        QVERIFY(client.waitForConnected(3000));
        client.write("GET /relative HTTP/1.1\r\nHost: localhost\r\n\r\n");
        QVERIFY(waitForBytes(client, 3000));
        QVERIFY(client.readAll().startsWith("HTTP/1.1 400"));
    }

    void upstreamFailureReturns502()
    {
        QTcpServer closed;
        QVERIFY(closed.listen(QHostAddress::LocalHost, 0));
        const quint16 deadPort = closed.serverPort();
        closed.close();
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("qml")});
        ProxyServer proxy(ephemeralChannels(), policy, nullptr, true);
        QVERIFY(proxy.start());
        const QByteArray response = getThrough(QString::fromLatin1(NetChannels::Qml),
                                               proxy.portFor(QString::fromLatin1(NetChannels::Qml)),
                                               deadPort);
        QVERIFY2(response.startsWith("HTTP/1.1 502"), response.constData());
    }

    void connectTunnelStillWorks()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("browser")});
        ProxyServer proxy(ephemeralChannels(), policy, nullptr, true);
        QVERIFY(proxy.start());
        QTcpSocket client;
        client.connectToHost(QHostAddress::LocalHost,
                             proxy.portFor(QString::fromLatin1(NetChannels::Browser)));
        QVERIFY(client.waitForConnected(3000));
        client.write("CONNECT 127.0.0.1:" + QByteArray::number(origin.serverPort())
                     + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
        QVERIFY(waitForBytes(client, 3000));
        const QByteArray response = client.readAll();
        QVERIFY2(response.startsWith("HTTP/1.1 200"), response.constData());
        client.write("GET /tunnel HTTP/1.1\r\nHost: localhost\r\n\r\n");
        QTRY_COMPARE(origin.requests.size(), 1);
        QVERIFY(origin.requests.first().startsWith(QStringLiteral("GET /tunnel HTTP/1.1")));
    }

    void networkProxyProcessSmoke()
    {
#ifdef PROXY_BINARY
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        QTemporaryDir dir;
        const QString policy = writePolicy(dir, {QStringLiteral("browser")});
        const quint16 base = 34900;   // 固定高位端口；被占用时跳过
        QProcess process;
        process.setProgram(QStringLiteral(PROXY_BINARY));
        process.setArguments({QStringLiteral("--policy"), policy,
                              QStringLiteral("--base-port"), QString::number(base),
                              QStringLiteral("--allow-loopback-for-tests")});
        process.setProcessChannelMode(QProcess::MergedChannels);
        process.start();
        if (!process.waitForStarted(3000)) QSKIP("network_proxy binary unavailable");
        QByteArray ready;
        QTRY_VERIFY_WITH_TIMEOUT((ready += process.readAllStandardOutput())
                                     .contains("ready"), 5000);
        if (ready.contains("cannot listen")) QSKIP("fixed smoke port already in use");
        const QByteArray response = getThrough(QString::fromLatin1(NetChannels::Browser), base,
                                               origin.serverPort());
        QVERIFY2(response.startsWith("HTTP/1.1 200"), response.constData());
        process.terminate();
        QVERIFY(process.waitForFinished(3000));
#else
        QSKIP("PROXY_BINARY not defined");
#endif
    }
};

QTEST_GUILESS_MAIN(ProxyIntegrationTest)
#include "proxy_integration_test.moc"
