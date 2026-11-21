#include "pi_module_api.h"

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QVector>
#include <QtTest>

namespace {
QVector<QString> g_types;
QVector<QJsonObject> g_events;
QTemporaryDir *g_dir = nullptr;

extern "C" void captureEvent(void *, const char *type, const char *json) {
    g_types.append(QString::fromUtf8(type));
    g_events.append(QJsonDocument::fromJson(QByteArray(json)).object());
}
extern "C" int noopSend(void *, uint8_t, const uint8_t *, uint32_t) { return 0; }
extern "C" void noopAction(const char *, const char *) {}
extern "C" void noopPublish(const char *, const char *) {}
extern "C" const char *dataDir() {
    static QByteArray path;
    path = g_dir ? g_dir->path().toUtf8() : QByteArray("/tmp");
    return path.constData();
}
extern "C" void noopLog(int, const char *) {}
}  // namespace

extern "C" uint32_t pi_module_api_version();
extern "C" const char *pi_module_manifest_json();
extern "C" pi_module_handle_t *pi_module_create(const pi_host_services_t *);
extern "C" int pi_module_on_attach(pi_module_handle_t *, const char *);
extern "C" int pi_module_on_data(pi_module_handle_t *, uint8_t, const uint8_t *, uint32_t);
extern "C" int pi_module_action(pi_module_handle_t *, const char *);
extern "C" void pi_module_destroy(pi_module_handle_t *);

class PlanterFakeTest : public QObject {
    Q_OBJECT
private:
    pi_host_services_t services_{};
    QTemporaryDir dir_;

private slots:
    void init() {
        g_types.clear();
        g_events.clear();
        g_dir = &dir_;
        services_ = {};
        services_.api_version = PI_MODULE_API_VERSION;
        services_.emit_event = captureEvent;
        services_.send_data = noopSend;
        services_.publish_action = noopAction;
        services_.publish_event = noopPublish;
        services_.data_directory = dataDir;
        services_.log = noopLog;
    }

    void manifestIsV3() {
        const QJsonObject manifest =
            QJsonDocument::fromJson(QByteArray(pi_module_manifest_json())).object();
        QCOMPARE(manifest.value(QStringLiteral("platform_api")).toInt(), 2);
        QVERIFY(manifest.value(QStringLiteral("data_schema")).toObject()
                    .value(QStringLiteral("records")).toObject()
                    .contains(QStringLiteral("sample.environment")));
    }

    void sampleEventIsForwarded() {
        pi_module_handle_t *module = pi_module_create(&services_);
        QVERIFY(module != nullptr);
        QCOMPARE(pi_module_on_attach(module, R"({"module_instance":"demo"})"), 0);
        const QByteArray payload = R"({"temperature_C":24.6,"humidity_RH":61.2,"light_lux":720})";
        QCOMPARE(pi_module_on_data(module, PI_TRANSPORT_HOTSPOT_LAN,
                                   reinterpret_cast<const uint8_t *>(payload.constData()),
                                   uint32_t(payload.size())), 0);
        QVERIFY(!g_types.isEmpty());
        QCOMPARE(g_types.last(), QStringLiteral("sample"));
        pi_module_destroy(module);
    }

    void unknownActionFails() {
        pi_module_handle_t *module = pi_module_create(&services_);
        QVERIFY(module != nullptr);
        QCOMPARE(pi_module_action(module, "definitely_not_declared"), -1);
        pi_module_destroy(module);
    }
};

QTEST_MAIN(PlanterFakeTest)
#include "planter_fake_test.moc"
