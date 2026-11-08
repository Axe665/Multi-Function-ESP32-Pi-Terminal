// 开发者选项 Test mode 的发现契约：Phase 1 新增的 ctest 必须出现，
// 且 net_policy_* / network_policy_* 归到 Network 组，不能只在命令行可见。
#include "core/TestRunner.h"

#include <QDir>
#include <QVariantMap>
#include <QtTest>

class TestRunnerDiscoveryTest : public QObject {
    Q_OBJECT
private slots:
    void phase1TestsAreDiscovered()
    {
        qputenv("ORANGE_PI_TEST_ROOT", QByteArray(TEST_SOURCE_ROOT));
        qputenv("ORANGE_PI_TEST_BUILD", QByteArray(TEST_BUILD_DIR));
        TestRunner runner;
        const QVariantList entries = runner.discover();
        QVERIFY2(!entries.isEmpty(), "ctest discovery returned no entries");

        auto find = [&entries](const QString &id) -> QVariantMap {
            for (const QVariant &value : entries) {
                const QVariantMap entry = value.toMap();
                if (entry.value(QStringLiteral("id")).toString() == id) return entry;
            }
            return {};
        };
        for (const char *id : {"ctest:net_policy_contract",
                               "ctest:net_policy_helper_contract",
                               "ctest:network_policy_controller",
                               "ctest:network_policy_qml_page",
                               "ctest:pbr_command_aead"}) {
            const QVariantMap entry = find(QString::fromLatin1(id));
            QVERIFY2(!entry.isEmpty(), id);
            QVERIFY2(entry.value(QStringLiteral("available")).toBool(), id);
        }
        QCOMPARE(find(QStringLiteral("ctest:net_policy_contract"))
                     .value(QStringLiteral("group")).toString(),
                 QStringLiteral("Network"));
        QCOMPARE(find(QStringLiteral("ctest:network_policy_qml_page"))
                     .value(QStringLiteral("group")).toString(),
                 QStringLiteral("Network"));
    }
};

QTEST_GUILESS_MAIN(TestRunnerDiscoveryTest)
#include "test_runner_discovery_test.moc"
