#include "pi_module_api.h"
#include "module_manifest.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTime>
#include <cstring>

struct pi_module_handle {
    const pi_host_services_t *host = nullptr;
    uint8_t transport = PI_TRANSPORT_BLE;
    bool stopped = false;
};

static int send_command(pi_module_handle_t *module, const char *name) {
    if (!module || module->stopped || !module->host || !module->host->send_data || !name)
        return -1;
    QJsonObject command;
    command.insert(QStringLiteral("command"), QString::fromLatin1(name));
    const QByteArray payload = QJsonDocument(command).toJson(QJsonDocument::Compact);
    return module->host->send_data(module->host->context, module->transport,
                                   reinterpret_cast<const uint8_t *>(payload.constData()),
                                   static_cast<uint32_t>(payload.size()));
}

extern "C" uint32_t pi_module_api_version() { return PI_MODULE_API_VERSION; }
extern "C" const char *pi_module_manifest_json() { return MODULE_MANIFEST_JSON; }

extern "C" pi_module_handle_t *pi_module_create(const pi_host_services_t *host) {
    if (!host || host->api_version != PI_MODULE_API_VERSION || !host->emit_event) return nullptr;
    return new pi_module_handle{host};
}

extern "C" int pi_module_on_attach(pi_module_handle_t *module, const char *json) {
    (void)json;
    if (!module) return -1;
    module->stopped = false;
    return 0;
}

extern "C" void pi_module_on_transport_connected(pi_module_handle_t *module, uint8_t transport) {
    if (module) module->transport = transport;
}

extern "C" int pi_module_on_data(pi_module_handle_t *module, uint8_t, const uint8_t *payload,
                                 uint32_t length) {
    if (!module || module->stopped || !module->host || !payload || length == 0 || length > 65532)
        return -1;

    QJsonParseError parse;
    const QByteArray frame(reinterpret_cast<const char *>(payload), static_cast<int>(length));
    const QJsonDocument document = QJsonDocument::fromJson(frame, &parse);
    if (parse.error != QJsonParseError::NoError || !document.isObject()) return -1;

    QJsonObject sample = document.object();
    const QDateTime now = QDateTime::currentDateTime();
    sample.insert(QStringLiteral("received_at"), double(now.toMSecsSinceEpoch()));
    const int hour = now.time().hour();
    sample.insert(QStringLiteral("night"), hour >= 22 || hour < 6);

    const QByteArray data = QJsonDocument(sample).toJson(QJsonDocument::Compact);
    module->host->emit_event(module->host->context, "sample", data.constData());
    return 0;
}

extern "C" int pi_module_action(pi_module_handle_t *module, const char *action) {
    if (!module || module->stopped || !action) return -1;
    if (std::strcmp(action, "tare") == 0) return send_command(module, "tare");
    if (std::strcmp(action, "calibrate") == 0) return send_command(module, "calibrate");
    if (std::strcmp(action, "reset") == 0) return send_command(module, "reset");
    return -1;
}

extern "C" void pi_module_on_disconnect_request(pi_module_handle_t *, const char *) {}

extern "C" void pi_module_stop(pi_module_handle_t *module) {
    if (module) module->stopped = true;
}

extern "C" void pi_module_on_detach(pi_module_handle_t *module) { pi_module_stop(module); }

extern "C" void pi_module_destroy(pi_module_handle_t *module) {
    if (!module) return;
    pi_module_stop(module);
    delete module;
}

extern "C" const char *pi_module_qml_page(pi_module_handle_t *) { return "qml/ModulePage.qml"; }
