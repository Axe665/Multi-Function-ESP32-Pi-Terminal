#include <QtTest>

#include <QJsonDocument>
#include <QJsonObject>

#include "pi_module_api.h"

namespace {
struct Capture {
    int events = 0;
    int sends = 0;
    QByteArray lastEvent;
    QByteArray lastSend;
};

void captureEvent(void *context, const char *type, const char *json) {
    auto *capture = static_cast<Capture *>(context);
    if (!capture || !type || !json) return;
    capture->events++;
    capture->lastEvent = QByteArray(type) + "|" + QByteArray(json);
}

int captureSend(void *context, uint8_t, const uint8_t *payload, uint32_t length) {
    auto *capture = static_cast<Capture *>(context);
    if (!capture || !payload) return -1;
    capture->sends++;
    capture->lastSend = QByteArray(reinterpret_cast<const char *>(payload), int(length));
    return 0;
}

pi_host_services_t hostFor(Capture *capture) {
    pi_host_services_t host{};
    host.api_version = PI_MODULE_API_VERSION;
    host.context = capture;
    host.emit_event = &captureEvent;
    host.send_data = &captureSend;
    return host;
}
}  // namespace

class BedModuleTest : public QObject {
    Q_OBJECT

private slots:
    void forwardsSampleWithHostContext() {
        Capture capture;
        pi_host_services_t host = hostFor(&capture);
        pi_module_handle_t *module = pi_module_create(&host);
        QVERIFY(module);

        const QByteArray payload = R"({"v":1,"w":62.3,"state":"in","evt":3,"event":"turn"})";
        QCOMPARE(pi_module_on_data(module, PI_TRANSPORT_BLE,
                                   reinterpret_cast<const uint8_t *>(payload.constData()),
                                   uint32_t(payload.size())),
                 0);
        QCOMPARE(capture.events, 1);
        QVERIFY(capture.lastEvent.startsWith("sample.bed|"));

        const QByteArray json = capture.lastEvent.mid(11);
        const QJsonObject sample = QJsonDocument::fromJson(json).object();
        QCOMPARE(sample.value("w").toDouble(), 62.3);
        QVERIFY(sample.value("received_at").isDouble());
        QVERIFY(sample.value("night").isBool());

        pi_module_destroy(module);
    }

    void mapsActionsToCommands() {
        Capture capture;
        pi_host_services_t host = hostFor(&capture);
        pi_module_handle_t *module = pi_module_create(&host);
        QVERIFY(module);

        QCOMPARE(pi_module_action(module, "tare"), 0);
        QCOMPARE(capture.sends, 1);
        QCOMPARE(QJsonDocument::fromJson(capture.lastSend).object().value("command").toString(),
                 QStringLiteral("tare"));

        QCOMPARE(pi_module_action(module, "calibrate"), 0);
        QCOMPARE(QJsonDocument::fromJson(capture.lastSend).object().value("command").toString(),
                 QStringLiteral("calibrate"));

        QCOMPARE(pi_module_action(module, "reset"), 0);
        QCOMPARE(QJsonDocument::fromJson(capture.lastSend).object().value("command").toString(),
                 QStringLiteral("reset"));

        QCOMPARE(pi_module_action(module, "unknown"), -1);
        pi_module_destroy(module);
    }

    void rejectsMalformedPayload() {
        Capture capture;
        pi_host_services_t host = hostFor(&capture);
        pi_module_handle_t *module = pi_module_create(&host);
        QVERIFY(module);

        const QByteArray broken = "{not json";
        QCOMPARE(pi_module_on_data(module, PI_TRANSPORT_BLE,
                                   reinterpret_cast<const uint8_t *>(broken.constData()),
                                   uint32_t(broken.size())),
                 -1);
        QCOMPARE(capture.events, 0);
        pi_module_destroy(module);
    }
};

QTEST_MAIN(BedModuleTest)
#include "bed_module_test.moc"
