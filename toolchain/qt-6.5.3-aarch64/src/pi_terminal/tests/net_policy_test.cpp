// 策略 v2 契约：默认拒绝、六个通道、只有应用级开关、v1 迁移、v2 拒绝 hosts。
#include <QtTest>
#include <QJsonArray>
#include <QJsonObject>
#include <QTemporaryDir>

#include "core/NetworkGate.h"
#include "net/NetChannels.h"
#include "net/NetPolicy.h"

namespace {
bool enabledOf(const QJsonObject &channels, const char *name)
{
    return channels.value(QString::fromLatin1(name)).toObject()
        .value(QStringLiteral("enabled")).toBool();
}

QJsonObject policyRoot(const QString &schema, int version, const QJsonObject &apps)
{
    return {{QStringLiteral("schema"), schema},
            {QStringLiteral("version"), version},
            {QStringLiteral("apps"), apps}};
}
}  // namespace

class NetPolicyTest : public QObject {
    Q_OBJECT
private slots:
    void versionAndChannelsAreComplete()
    {
        NetworkGate gate;
        const QJsonObject policy = NetPolicy::build(gate);
        QCOMPARE(policy.value(QStringLiteral("version")).toInt(), NetChannels::PolicyVersion);
        const QJsonObject channels = policy.value(QStringLiteral("channels")).toObject();
        QCOMPARE(channels.size(), 6);
        for (const char *name : {NetChannels::Browser, NetChannels::Music, NetChannels::Tv,
                                 NetChannels::Qml, NetChannels::TimeSync, NetChannels::Updates}) {
            QVERIFY2(channels.contains(QString::fromLatin1(name)), name);
            const QJsonObject entry = channels.value(QString::fromLatin1(name)).toObject();
            QCOMPARE(entry.size(), 1);
            QVERIFY(entry.value(QStringLiteral("enabled")).isBool());
        }
    }

    void defaultIsDenyEverywhere()
    {
        NetworkGate gate;
        const QJsonObject channels = NetPolicy::build(gate).value(QStringLiteral("channels")).toObject();
        for (auto it = channels.begin(); it != channels.end(); ++it)
            QCOMPARE(it.value().toObject().value(QStringLiteral("enabled")).toBool(), false);
    }

    void weatherAndTimeSyncDoNotFollowEachOther()
    {
        NetworkGate gate;
        gate.setWeatherAllowed(false);
        gate.setTimeSyncAllowed(true);
        QJsonObject channels = NetPolicy::build(gate).value(QStringLiteral("channels")).toObject();
        QCOMPARE(enabledOf(channels, NetChannels::Qml), false);
        QCOMPARE(enabledOf(channels, NetChannels::TimeSync), true);

        gate.setWeatherAllowed(true);
        gate.setTimeSyncAllowed(false);
        channels = NetPolicy::build(gate).value(QStringLiteral("channels")).toObject();
        QCOMPARE(enabledOf(channels, NetChannels::Qml), true);
        QCOMPARE(enabledOf(channels, NetChannels::TimeSync), false);
    }

    void v1MigratesEnabledAndDropsHosts()
    {
        const QJsonObject apps{
            {QStringLiteral("weather"),
             QJsonObject{{QStringLiteral("enabled"), true},
                         {QStringLiteral("hosts"), QJsonArray{QStringLiteral("api.open-meteo.com")}}}},
            {QStringLiteral("time"),
             QJsonObject{{QStringLiteral("enabled"), true},
                         {QStringLiteral("hosts"), QJsonArray{}}}},
        };
        NetworkPolicy::Policy policy;
        QString error;
        QVERIFY2(NetworkPolicy::parse(policyRoot(QStringLiteral("orpi-net-policy-v1"), 1, apps),
                                      &policy, &error), qPrintable(error));
        for (const NetworkPolicy::AppPolicy &app : policy.apps) {
            if (app.id == QStringLiteral("weather")) QVERIFY(app.enabled);
            if (app.id == QStringLiteral("time")) QVERIFY(app.enabled);
            if (app.id == QStringLiteral("music")) QVERIFY(!app.enabled);
        }
        const QJsonObject migrated = NetworkPolicy::toJson(policy);
        QCOMPARE(migrated.value(QStringLiteral("schema")).toString(),
                 QString::fromLatin1(NetworkPolicy::Schema));
        QVERIFY(!migrated.value(QStringLiteral("apps")).toObject()
                     .value(QStringLiteral("weather")).toObject()
                     .contains(QStringLiteral("hosts")));
    }

    void v2RejectsHostsAndUnknownApps()
    {
        NetworkPolicy::Policy policy;
        QString error;
        const QJsonObject valid = policyRoot(
            QString::fromLatin1(NetworkPolicy::Schema), NetworkPolicy::Version,
            QJsonObject{{QStringLiteral("weather"),
                         QJsonObject{{QStringLiteral("enabled"), true}}}});
        QVERIFY2(NetworkPolicy::parse(valid, &policy, &error), qPrintable(error));

        QJsonObject withHosts = valid;
        withHosts.insert(QStringLiteral("apps"),
                         QJsonObject{{QStringLiteral("weather"),
                                      QJsonObject{{QStringLiteral("enabled"), true},
                                                  {QStringLiteral("hosts"),
                                                   QJsonArray{QStringLiteral("example.com")}}}}});
        QVERIFY(!NetworkPolicy::parse(withHosts, &policy, &error));

        QJsonObject withUnknown = valid;
        withUnknown.insert(QStringLiteral("apps"),
                           QJsonObject{{QStringLiteral("mail"),
                                        QJsonObject{{QStringLiteral("enabled"), true}}}});
        QVERIFY(!NetworkPolicy::parse(withUnknown, &policy, &error));

        QJsonObject withModules = valid;
        withModules.insert(QStringLiteral("modules"),
                           QJsonObject{{QStringLiteral("example.device"),
                                        QJsonObject{{QStringLiteral("network"), true},
                                                    {QStringLiteral("file"), true}}}});
        QVERIFY2(NetworkPolicy::parse(withModules, &policy, &error), qPrintable(error));
        QCOMPARE(policy.modules.size(), 1);
        QVERIFY(policy.modules.first().network);
        QVERIFY(policy.modules.first().file);

        QJsonObject badModuleId = valid;
        badModuleId.insert(QStringLiteral("modules"),
                           QJsonObject{{QStringLiteral("../escape"),
                                        QJsonObject{{QStringLiteral("network"), true}}}});
        QVERIFY(!NetworkPolicy::parse(badModuleId, &policy, &error));
    }

    void policyFileRoundTripsAndMissingFileIsDeny()
    {
        NetworkPolicy::Policy policy = NetworkPolicy::defaults();
        for (NetworkPolicy::AppPolicy &app : policy.apps)
            if (app.id == QStringLiteral("time")) app.enabled = true;
        policy.modules.append(NetworkPolicy::ModulePolicy{
            QStringLiteral("example.device"), true, true});
        const QJsonObject root = NetworkPolicy::toJson(policy);
        QTemporaryDir tmp;
        const QString path = tmp.filePath("network-policy.json");
        QString error;
        QVERIFY2(NetworkPolicy::writeFile(path, root, &error), qPrintable(error));
        const NetworkPolicy::Policy loaded = NetworkPolicy::loadFile(path, &error);
        QVERIFY(error.isEmpty());
        QCOMPARE(loaded.apps.size(), 6);
        for (const NetworkPolicy::AppPolicy &app : loaded.apps)
            if (app.id == QStringLiteral("time")) QVERIFY(app.enabled);
        QCOMPARE(loaded.modules.size(), 1);
        QCOMPARE(loaded.modules.first().id, QStringLiteral("example.device"));
        QVERIFY(loaded.modules.first().network);
        QVERIFY(loaded.modules.first().file);

        const NetworkPolicy::Policy missing = NetworkPolicy::loadFile(
            tmp.filePath("does-not-exist.json"), &error);
        QVERIFY(!error.isEmpty());
        for (const NetworkPolicy::AppPolicy &app : missing.apps) QVERIFY(!app.enabled);
    }

    void masterSwitchDeniesEveryChannel()
    {
        NetworkGate gate;
        gate.setEnabled(false);
        gate.setWeatherAllowed(true);
        const QJsonObject channels = NetPolicy::build(gate).value(QStringLiteral("channels")).toObject();
        for (auto it = channels.begin(); it != channels.end(); ++it)
            QCOMPARE(it.value().toObject().value(QStringLiteral("enabled")).toBool(), false);
    }
};

QTEST_GUILESS_MAIN(NetPolicyTest)
#include "net_policy_test.moc"
