// 策略控制器：缺失文件=默认拒绝；错误 PIN 不写盘；正确 PIN 经 helper 落盘并更新 gate。
#include "core/NetworkGate.h"
#include "net/NetworkPolicyController.h"
#include "security/AuthService.h"
#include "security/SessionManager.h"
#include "security/UserService.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

using namespace security;

class NetworkPolicyControllerTest : public QObject {
    Q_OBJECT
private:
    QTemporaryDir dir_;
    QString registry_() const { return dir_.filePath("users.json"); }
    QString locks_() const { return dir_.filePath("locks.json"); }
    QString policy_() const { return dir_.filePath("network-policy.json"); }

private slots:
    void initTestCase()
    {
        QVERIFY(dir_.isValid());
        qputenv("XDG_CONFIG_HOME", dir_.filePath("config").toUtf8());
        qputenv("ORANGE_PI_NETWORK_POLICY", policy_().toUtf8());
        qputenv("ORANGE_PI_NET_POLICY_HELPER", QByteArray(NET_POLICY_HELPER));
    }

    void missingFileDeniesEverythingThenAdminSaveApplies()
    {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Admin"),
                                                    QStringLiteral("246810"), QString());
        QVERIFY(!id.isEmpty());
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());
        QVERIFY(session.isAdmin());

        NetworkGate gate;
        NetworkPolicyController controller(policy_());
        controller.setSessionManager(&session);
        controller.setGate(&gate);
        QVERIFY(!controller.loaded());
        QVERIFY(!gate.browserAllowed());
        QVERIFY(!gate.weatherAllowed());

        // 错误 PIN 不能写盘。
        QVariantList apps = controller.apps();
        QVariantMap wrongResult = controller.save(apps, {}, QStringLiteral("000000"));
        QVERIFY(!wrongResult.value(QStringLiteral("ok")).toBool());
        QVERIFY(!QFile::exists(policy_()));
        QTest::qWait(1100);

        // 打开天气；正确 PIN 经 helper 写入 v2 策略。
        for (int i = 0; i < apps.size(); ++i) {
            QVariantMap app = apps.at(i).toMap();
            if (app.value(QStringLiteral("id")).toString() != QStringLiteral("weather")) continue;
            app.insert(QStringLiteral("enabled"), true);
            apps[i] = app;
        }
        const QVariantList modules{
            QVariantMap{{QStringLiteral("id"), QStringLiteral("example.device")},
                        {QStringLiteral("network"), true},
                        {QStringLiteral("file"), true}}};
        const QVariantMap saved = controller.save(apps, modules, QStringLiteral("246810"));
        QVERIFY2(saved.value(QStringLiteral("ok")).toBool(),
                 qPrintable(saved.value(QStringLiteral("error")).toString()));
        QVERIFY(QFile::exists(policy_()));
        QVERIFY(controller.loaded());
        QVERIFY(gate.weatherAllowed());
        QVERIFY(!gate.musicAllowed());

        QVERIFY(controller.moduleNetworkEnabled(QStringLiteral("example.device")));
        QVERIFY(controller.moduleFileEnabled(QStringLiteral("example.device")));
        QFile file(policy_());
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
        const QJsonObject weather = root.value(QStringLiteral("apps")).toObject()
            .value(QStringLiteral("weather")).toObject();
        QVERIFY(weather.value(QStringLiteral("enabled")).toBool());
        QVERIFY(!weather.contains(QStringLiteral("hosts")));
        QCOMPARE(root.value(QStringLiteral("schema")).toString(),
                 QString::fromLatin1(NetworkPolicy::Schema));
    }
};

QTEST_GUILESS_MAIN(NetworkPolicyControllerTest)
#include "network_policy_controller_test.moc"
