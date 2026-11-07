// 锁屏服务端边界 + 恢复码登录/强制改 PIN。
#include "core/ModuleDataApi.h"
#include "core/SecurityService.h"
#include "security/AuthService.h"
#include "security/RecoveryCode.h"
#include "security/SessionManager.h"
#include "security/UserService.h"

#include <QDir>
#include <QTemporaryDir>
#include <QtTest>

using namespace security;

class SecurityLockTest : public QObject {
    Q_OBJECT
private:
    QTemporaryDir dir_;
    QString registry_() const { return dir_.filePath("users.json"); }
    QString locks_() const { return dir_.filePath("locks.json"); }

private slots:
    void lockedSessionDeniesDataApisAndRecoveryForcesPinChange()
    {
        qputenv("XDG_CONFIG_HOME", dir_.filePath("config").toUtf8());
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString code = RecoveryCode::generate();
        QVERIFY(!code.isEmpty());
        const QString id = users.createInitialAdmin(QStringLiteral("Owner"),
                                                    QStringLiteral("246810"), code);
        QVERIFY(!id.isEmpty());
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());
        QVERIFY(session.database() != nullptr);
        SecurityService service;
        service.setSessionManager(&session);
        service.setUserDatabase(session.database());

        QVERIFY(service.addManualReading(120, QStringLiteral("mmHg"), QStringLiteral("test")));
        ModuleDataApi moduleData(80, QStringLiteral("m-1"));
        moduleData.setSessionManager(&session);
        moduleData.setDatabase(session.database());
        QVERIFY(moduleData.ready());
        session.lock();
        QVERIFY(!moduleData.ready());
        QVERIFY(!moduleData.appendSample({{QStringLiteral("sample_seq"), 1}}));
        QVERIFY(!service.addManualReading(121, QStringLiteral("mmHg"), QStringLiteral("test")));
        QCOMPARE(service.lastMessage(), QString::fromLatin1(AuthResult::SessionLocked));

        QTest::qWait(1100);   // 终端级 1 次/秒
        QCOMPARE(session.unlockWithPin(QStringLiteral("246810")), QString());
        QVERIFY(service.addManualReading(122, QStringLiteral("mmHg"), QStringLiteral("test")));

        // 撤销身份必须发信号，宿主据此断 PBR 会话。
        QByteArray publicKey(65, '\x11');
        publicKey[0] = '\x04';
        QVERIFY(service.pairBridge(QStringLiteral("bridge-1"), QString::fromLatin1(publicKey.toHex())));
        const QVariantList trusted = service.trustedBridges();
        QVERIFY(!trusted.isEmpty());
        const QString fingerprint = trusted.first().toMap().value(QStringLiteral("fingerprint")).toString();
        QVERIFY(!fingerprint.isEmpty());
        QSignalSpy revoked(&service, &SecurityService::bridgeRevoked);
        QVERIFY(service.revokeBridge(fingerprint));
        QCOMPARE(revoked.count(), 1);
        QCOMPARE(revoked.at(0).at(0).toString(), QStringLiteral("bridge-1"));

        session.signOut();
        QTest::qWait(1100);
        QCOMPARE(session.loginWithRecoveryCode(id, code), QString());
        QVERIFY(session.mustChangePin());
        service.setUserDatabase(session.database());
        QVERIFY(!service.addManualReading(123, QStringLiteral("mmHg"), QStringLiteral("test")));
        QCOMPARE(service.lastMessage(),
                 QString::fromLatin1(AuthResult::PinChangeRequired));

        QVERIFY(!session.setRecoveryPin(QStringLiteral("123")));   // 太短
        QVERIFY(session.setRecoveryPin(QStringLiteral("654321")));
        QVERIFY(!session.mustChangePin());
        QVERIFY(service.addManualReading(124, QStringLiteral("mmHg"), QStringLiteral("test")));

        const QString newCode = session.beginRecoveryRotation();
        QCOMPARE(newCode.size(), 29);   // 24 位 + 5 个分隔符
        QVERIFY(session.commitRecoveryRotation());
        session.cancelRecoveryRotation();
    }
};

QTEST_GUILESS_MAIN(SecurityLockTest)
#include "security_lock_test.moc"
