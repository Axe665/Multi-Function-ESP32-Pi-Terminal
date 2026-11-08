// PBR 控制面命令方向：握手后的命令必须是 Pi→桥 AEAD（kind=2/dir=0），
// 且序号从 1 递增；未认证时禁止发命令。
#include "protocol/pbr_aead.h"
#include "protocol/pibridge_protocol.h"
#include "transport/PogoControlTransport.h"

#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

#include <fcntl.h>
#include <pty.h>
#include <unistd.h>

class PogoControlTest : public QObject {
    Q_OBJECT
private slots:
    void authenticatedCommandsAreEncryptedWithPiToBridgeKey()
    {
        int master = -1;
        int slave = -1;
        char name[128] = {};
        QVERIFY2(openpty(&master, &slave, name, nullptr, nullptr) == 0, "openpty failed");
        QVERIFY(name[0] != '\0');
        fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK);
        const QByteArray piKey(32, '\x11');
        const QByteArray noncePrefix(4, '\x22');
        const QByteArray bridgeKey(32, '\x33');
        PogoControlTransport transport;
        QVERIFY(transport.open(QString::fromLocal8Bit(name), 115200));
        transport.setSessionKeys(bridgeKey, piKey, noncePrefix, QByteArray(1, '\x09'));
        transport.setAuthenticated(true);
        QVERIFY(transport.sendCommand({{QStringLiteral("command"), 1}}));

        QByteArray wire;
        QElapsedTimer timer;
        timer.start();
        while (wire.size() < 4 && timer.elapsed() < 2000) {
            char buffer[256];
            const ssize_t got = ::read(master, buffer, sizeof(buffer));
            if (got > 0) wire.append(buffer, int(got));
            else QTest::qWait(5);
        }
        quint8 direction = 0;
        PiBridge::Kind kind = PiBridge::ControlEvent;
        quint32 sequence = 0;
        QByteArray payload;
        QVERIFY2(PiBridge::decode(wire, direction, kind, sequence, payload), "no PBR1 frame");
        QCOMPARE(kind, PiBridge::ControlCommand);
        PbrAead::Envelope envelope;
        PbrAead::Aad aad;
        quint8 envVersion = 0;
        PbrAead::Result result = PbrAead::Result::Malformed;
        QVERIFY(PbrAead::parseEnvelope(payload, &envelope, &envVersion, &aad, &result));
        QCOMPARE(result, PbrAead::Result::Ok);
        aad.kind = quint8(PiBridge::ControlCommand);
        aad.dir = 0;
        QCOMPARE(int(aad.kind), int(PiBridge::ControlCommand));
        QCOMPARE(int(aad.dir), 0);
        QCOMPARE(envelope.authSeq, quint64(1));
        const QByteArray plaintext = PbrAead::open(payload, piKey, aad, &result);
        QCOMPARE(result, PbrAead::Result::Ok);
        const QJsonObject object = QJsonDocument::fromJson(plaintext).object();
        QCOMPARE(object.value(QStringLiteral("command")).toInt(), 1);

        // 第二条命令序号必须递增到 2，且不能复用 nonce。
        QVERIFY(transport.sendCommand({{QStringLiteral("command"), 2}}));
        wire.clear();
        timer.restart();
        while (wire.size() < 4 && timer.elapsed() < 2000) {
            char buffer[256];
            const ssize_t got = ::read(master, buffer, sizeof(buffer));
            if (got > 0) wire.append(buffer, int(got));
            else QTest::qWait(5);
        }
        QVERIFY2(PiBridge::decode(wire, direction, kind, sequence, payload), "second PBR1 frame");
        QVERIFY(PbrAead::parseEnvelope(payload, &envelope, &envVersion, &aad, &result));
        aad.kind = quint8(PiBridge::ControlCommand);
        aad.dir = 0;
        QCOMPARE(envelope.authSeq, quint64(2));
        const QByteArray second = PbrAead::open(payload, piKey, aad, &result);
        QCOMPARE(result, PbrAead::Result::Ok);
        QCOMPARE(QJsonDocument::fromJson(second).object()
                     .value(QStringLiteral("command")).toInt(), 2);

        transport.close();
        ::close(master);
        ::close(slave);
    }

    void unauthenticatedCommandsAreRefused()
    {
        int master = -1;
        int slave = -1;
        char name[128] = {};
        QVERIFY(openpty(&master, &slave, name, nullptr, nullptr) == 0);
        fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK);
        PogoControlTransport transport;
        QVERIFY(transport.open(QString::fromLocal8Bit(name), 115200));
        QVERIFY(!transport.sendCommand({{QStringLiteral("command"), 1}}));
        transport.close();
        ::close(master);
        ::close(slave);
    }
};

QTEST_GUILESS_MAIN(PogoControlTest)
#include "pogo_control_test.moc"
