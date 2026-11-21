#include <QtTest>

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "pi_module_api.h"
#include "module_manifest.h"

namespace {
struct Capture {
    int sends = 0;
    QByteArray last;
};

int captureSend(void *context, uint8_t, const uint8_t *payload, uint32_t length) {
    auto *capture = static_cast<Capture *>(context);
    if (!capture || (!payload && length)) return -1;
    capture->sends++;
    capture->last = QByteArray(reinterpret_cast<const char *>(payload), int(length));
    return 0;
}

void ignoreEvent(void *, const char *, const char *) {}
}  // namespace

class ModuleTest : public QObject {
    Q_OBJECT

private slots:
    void apiVersionMatchesHost() {
        QCOMPARE(pi_module_api_version(), PI_MODULE_API_VERSION);
    }

    void manifestDeclaresPlatformContracts() {
        const QJsonObject manifest =
            QJsonDocument::fromJson(QByteArray(pi_module_manifest_json())).object();
        QVERIFY(manifest.value(QStringLiteral("module_id")).isDouble());
        QCOMPARE(manifest.value(QStringLiteral("platform_api")).toInt(), 1);
        const QString network = manifest.value(QStringLiteral("network_api")).toString();
        QVERIFY(network == QStringLiteral("none") || network == QStringLiteral("broker"));
        const QString file = manifest.value(QStringLiteral("file_api")).toString(QStringLiteral("none"));
        QVERIFY(file == QStringLiteral("none") || file == QStringLiteral("home-read"));
        QVERIFY(manifest.value(QStringLiteral("qml_page")).toString().endsWith(
            QStringLiteral("ModulePage.qml")));
    }

    void lifecycleAndAction() {
        Capture capture;
        pi_host_services_t services{};
        services.api_version = PI_MODULE_API_VERSION;
        services.context = &capture;
        services.send_data = captureSend;
        services.emit_event = ignoreEvent;

        pi_module_handle_t *module = pi_module_create(&services);
        QVERIFY(module);
        QCOMPARE(pi_module_on_attach(module, "{\"module_instance\":\"offline-test\"}"), 0);
        pi_module_on_transport_connected(module, PI_TRANSPORT_BLE);
        QCOMPARE(pi_module_action(module, "ping"), 0);
        QVERIFY(capture.sends >= 1);
        QVERIFY(capture.last.contains("ping"));
        QCOMPARE(pi_module_on_data(module, PI_TRANSPORT_BLE,
                                   reinterpret_cast<const uint8_t *>("{}"), 2), 0);
        pi_module_stop(module);
        pi_module_destroy(module);
    }
};

QTEST_GUILESS_MAIN(ModuleTest)
#include "module_test.moc"
