// TimeSyncClient 契约：门控、HTTP 响应、8s（测试用更短）超时、取消。
#include <QtTest>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>

#include "core/NetworkGate.h"
#include "ui/TimeSyncClient.h"

namespace {

class OriginServer : public QTcpServer {
public:
    QByteArray body = QByteArrayLiteral("{\"ok\":true}");
    int status = 200;

protected:
    void incomingConnection(qintptr descriptor) override
    {
        auto *socket = new QTcpSocket(this);
        socket->setSocketDescriptor(descriptor);
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
            if (!socket->property("answered").toBool()) {
                socket->setProperty("answered", true);
                socket->readAll();
                socket->write("HTTP/1.1 " + QByteArray::number(status)
                              + " OK\r\nContent-Type: application/json\r\nContent-Length: "
                              + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n"
                              + body);
                socket->flush();
                socket->disconnectFromHost();
            }
        });
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
    }
};

class SilentServer : public QTcpServer {
protected:
    void incomingConnection(qintptr descriptor) override
    {
        auto *socket = new QTcpSocket(this);
        socket->setSocketDescriptor(descriptor);
        connect(socket, &QTcpSocket::readyRead, socket, [socket] { socket->readAll(); });
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
    }
};

}  // namespace

class TimeSyncClientTest : public QObject {
    Q_OBJECT
private slots:
    void fetchesHttpAndCarriesStatusAndBody()
    {
        OriginServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        TimeSyncClient client(&gate, 0, nullptr, 500);
        QSignalSpy finished(&client, &TimeSyncClient::finished);
        QSignalSpy failed(&client, &TimeSyncClient::failed);
        client.fetch(QStringLiteral("http://127.0.0.1:%1/api").arg(origin.serverPort()), 7);
        QTRY_COMPARE_WITH_TIMEOUT(finished.count(), 1, 3000);
        QCOMPARE(finished.at(0).at(0).toInt(), 7);
        QCOMPARE(finished.at(0).at(1).toInt(), 200);
        QCOMPARE(finished.at(0).at(2).toString(), QStringLiteral("{\"ok\":true}"));
        QCOMPARE(failed.count(), 0);
    }

    void blockedByGateDoesNotTouchNetwork()
    {
        NetworkGate gate;
        gate.setEnabled(false);
        TimeSyncClient client(&gate, 0, nullptr, 500);
        QSignalSpy finished(&client, &TimeSyncClient::finished);
        QSignalSpy failed(&client, &TimeSyncClient::failed);
        client.fetch(QStringLiteral("http://127.0.0.1:1/api"), 3);
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, 1000);
        QCOMPARE(failed.at(0).at(0).toInt(), 3);
        QCOMPARE(failed.at(0).at(1).toString(), QStringLiteral("blocked"));
        QCOMPARE(finished.count(), 0);
    }

    void timeoutIsReportedOnce()
    {
        SilentServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        TimeSyncClient client(&gate, 0, nullptr, 150);
        QSignalSpy finished(&client, &TimeSyncClient::finished);
        QSignalSpy failed(&client, &TimeSyncClient::failed);
        client.fetch(QStringLiteral("http://127.0.0.1:%1/api").arg(origin.serverPort()), 9);
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, 3000);
        QCOMPARE(failed.at(0).at(1).toString(), QStringLiteral("timeout"));
        QTest::qWait(200);
        QCOMPARE(finished.count(), 0);
        QCOMPARE(failed.count(), 1);
    }

    void abortSilencesCallbacks()
    {
        SilentServer origin;
        QVERIFY(origin.listen(QHostAddress::LocalHost, 0));
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        TimeSyncClient client(&gate, 0, nullptr, 500);
        QSignalSpy finished(&client, &TimeSyncClient::finished);
        QSignalSpy failed(&client, &TimeSyncClient::failed);
        client.fetch(QStringLiteral("http://127.0.0.1:%1/api").arg(origin.serverPort()), 11);
        client.abort(11);
        QTest::qWait(300);
        QCOMPARE(finished.count(), 0);
        QCOMPARE(failed.count(), 0);
    }

    void invalidUrlFailsClosed()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        TimeSyncClient client(&gate, 0, nullptr, 500);
        QSignalSpy failed(&client, &TimeSyncClient::failed);
        client.fetch(QStringLiteral("ftp://example.com/x"), 12);
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, 1000);
        QCOMPARE(failed.at(0).at(1).toString(), QStringLiteral("network"));
    }
};

QTEST_GUILESS_MAIN(TimeSyncClientTest)
#include "time_sync_client_test.moc"
