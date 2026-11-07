#include "core/NetworkGate.h"
#include "ui/MusicService.h"
#include "net/ProxyServer.h"
#include <QtTest>
#include <QTcpServer>
#include <QTcpSocket>
#include <QElapsedTimer>
#include <QTemporaryDir>
#include <QSignalSpy>
#include <QJsonDocument>
#include <QJsonObject>
#include <memory>

class MusicServiceTest : public QObject {
    Q_OBJECT
private slots:
    void staleSourcesAreDiscarded() {
        QTemporaryDir config;
        qputenv("XDG_CONFIG_HOME", config.path().toUtf8());
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        connect(&server, &QTcpServer::newConnection, this, [&] {
            while (server.hasPendingConnections()) {
                auto *socket = server.nextPendingConnection();
                auto buffer = std::make_shared<QByteArray>();
                connect(socket, &QTcpSocket::readyRead, socket, [socket, buffer] {
                    *buffer += socket->readAll();
                    const auto split = buffer->indexOf("\r\n\r\n");
                    if (split < 0 || socket->property("handled").toBool()) return;
                    int size = 0;
                    for (const auto &line : buffer->left(split).split('\n'))
                        if (line.toLower().startsWith("content-length:")) size = line.mid(15).trimmed().toInt();
                    if (buffer->size() < split + 4 + size) return;
                    socket->setProperty("handled", true);
                    const auto body = buffer->mid(split + 4);
                    const bool old = body.contains("id=old");
                    const auto json = QByteArray("{\"code\":200,\"data\":[{\"url\":\"https://audio.example/") + (old ? "old" : "new") + ".mp3\",\"freeTrialInfo\":null}]}";
                    QTimer::singleShot(old ? 150 : 10, socket, [socket, json] {
                        socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + QByteArray::number(json.size()) + "\r\n\r\n" + json);
                        socket->disconnectFromHost();
                    });
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
        MusicService service;
        service.setEndpoint(QString("http://127.0.0.1:%1").arg(server.serverPort()));
        QSignalSpy sources(&service, &MusicService::sourceReady);
        service.resolve("old");
        service.resolve("new");
        QTRY_COMPARE_WITH_TIMEOUT(sources.count(), 1, 2000);
        QTest::qWait(250);
        QCOMPARE(sources.count(), 1);
        QCOMPARE(sources.at(0).at(0).toString(), QString("new"));
        QCOMPARE(sources.at(0).at(1).toUrl(), QUrl("https://audio.example/new.mp3"));
        service.resolve("old");
        service.cancelPlaybackRequest();
        QTest::qWait(250);
        QCOMPARE(sources.count(), 1);
    }

    // 真实 MusicService -> QNAM -> ProxyServer(34002) -> 本地 fake Node 的链路。
    // 代理必须把绝对 URI 改写成 origin-form，fake Node 才能按路径返回音源。
    void resolveGoesThroughMusicProxy() {
        QTemporaryDir config;
        qputenv("XDG_CONFIG_HOME", config.path().toUtf8());
        QTcpServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        connect(&origin, &QTcpServer::newConnection, this, [&] {
            while (origin.hasPendingConnections()) {
                auto *socket = origin.nextPendingConnection();
                auto buffer = std::make_shared<QByteArray>();
                connect(socket, &QTcpSocket::readyRead, socket, [socket, buffer] {
                    *buffer += socket->readAll();
                    const auto split = buffer->indexOf("\r\n\r\n");
                    if (split < 0 || socket->property("handled").toBool()) return;
                    socket->setProperty("handled", true);
                    const auto json = QByteArrayLiteral(
                        "{\"code\":200,\"data\":[{\"url\":\"https://audio.example/proxy.mp3\","
                        "\"freeTrialInfo\":null}]}");
                    socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                  "Content-Length: " + QByteArray::number(json.size())
                                  + "\r\nConnection: close\r\n\r\n" + json);
                    socket->flush();
                    socket->disconnectFromHost();
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });

        QTemporaryDir policyDir;
        const QString policyPath = policyDir.filePath("policy.json");
        QFile policy(policyPath);
        QVERIFY(policy.open(QIODevice::WriteOnly));
        const QJsonObject channels{{"music", true}};
        policy.write(QJsonDocument(QJsonObject{{"version", 2}, {"channels", channels}})
                         .toJson(QJsonDocument::Compact));
        policy.close();
        ProxyServer proxy({{QStringLiteral("music"), 0}}, policyPath, nullptr, true);
        QVERIFY(proxy.start());
        const quint16 proxyPort = proxy.portFor(QStringLiteral("music"));
        QVERIFY(proxyPort != 0);

        MusicService service;
        service.setEndpoint(QStringLiteral("http://127.0.0.1:%1").arg(origin.serverPort()));
        service.setNetworkProxy(QNetworkProxy(QNetworkProxy::HttpProxy,
                                              QStringLiteral("127.0.0.1"), proxyPort));
        QSignalSpy ready(&service, &MusicService::sourceReady);
        QSignalSpy failed(&service, &MusicService::sourceFailed);
        service.resolve(QStringLiteral("track"));
        QTRY_COMPARE_WITH_TIMEOUT(ready.count(), 1, 3000);
        QCOMPARE(ready.at(0).at(0).toString(), QStringLiteral("track"));
        QCOMPARE(ready.at(0).at(1).toUrl(), QUrl(QStringLiteral("https://audio.example/proxy.mp3")));
        QCOMPARE(failed.count(), 0);
    }

    // 「音乐联网」关闭时：一次请求都不发，直接以「联网已关闭」失败。
    // 用假 endpoint 不会连上，所以能确定性地区分"被门控拦下"和"发出去失败了"。
    void networkOffBlocksResolve() {
        QTemporaryDir config;
        qputenv("XDG_CONFIG_HOME", config.path().toUtf8());
        NetworkGate gate;
        gate.setEnabled(false);
        MusicService service;
        service.setNetworkGate(&gate);
        service.setEndpoint(QStringLiteral("http://127.0.0.1:9"));
        QSignalSpy failed(&service, &MusicService::sourceFailed);
        QSignalSpy ready(&service, &MusicService::sourceReady);
        QElapsedTimer timer;
        timer.start();
        service.resolve("anything");
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, 2000);
        QCOMPARE(failed.at(0).at(1).toString(), QStringLiteral("联网已关闭"));
        QCOMPARE(ready.count(), 0);
        QVERIFY2(timer.elapsed() < 1000, "must fail immediately, not after a network timeout");

        // 只关「音乐联网」也一样拦（总开关仍开着）。
        gate.setEnabled(true);
        gate.setFeatureEnabledFromUi(QStringLiteral("music"), false);
        service.resolve("anything");
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 2, 2000);
        QCOMPARE(failed.at(1).at(1).toString(), QStringLiteral("联网已关闭"));
    }
};
QTEST_GUILESS_MAIN(MusicServiceTest)
#include "music_service_test.moc"
