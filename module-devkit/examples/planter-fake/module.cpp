// 盆栽假模块（模块 80）——桌面演示用。
//
// 与 smart-planter 的差别只有一处：数据不再来自真实 BLE/LAN 传感器，
// 而是由模块页 QML 侧定时生成（见 qml/ModulePage.qml 的 demoMode）。
// 模块本身保持标准 ABI：收到 on_data 就记一分钟桶、回补 history，
// 再 emit_event("sample") 交给宿主。
//
// 为什么不在模块里用 QTimer：模块运行在 module_worker 的同步阻塞循环里
// （module_worker_main.cpp 只有 QCoreApplication 构造、没有 exec()），
// 没有 Qt 事件循环，QTimer 永远不会触发。定时必须放在有事件循环的一端。
#include "pi_module_sdk.h"
#include "module_manifest.h"
#include "History.h"
#include <QDateTime>
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <memory>

struct pi_module_handle {
    const pi_host_services_t *host;
    uint8_t transport = PI_TRANSPORT_HOTSPOT_LAN;
    bool stopped = false;
    std::unique_ptr<History> history;
};

extern "C" uint32_t pi_module_api_version() { return PI_MODULE_API_VERSION; }
extern "C" const char *pi_module_manifest_json() { return MODULE_MANIFEST_JSON; }

extern "C" pi_module_handle_t *pi_module_create(const pi_host_services_t *h) {
    if (!h || h->api_version != PI_MODULE_API_VERSION || !h->emit_event) return nullptr;
    return new pi_module_handle{h};
}

extern "C" int pi_module_on_attach(pi_module_handle_t *m, const char *json) {
    if (!m || !json) return -1;
    const auto config = QJsonDocument::fromJson(json).object();
    const auto instance = config.value("module_instance").toString();
    if (instance.isEmpty()) return -1;
    const char *base = pi_module_sdk::data_directory(m->host);
    const auto key = QCryptographicHash::hash(instance.toUtf8(), QCryptographicHash::Sha256).toHex();
    const QString file = base ? QString::fromUtf8(base) + "/planter/" + key + ".json" : QString();
    m->history.reset(new History(file));
    m->stopped = false;
    return 0;
}

extern "C" void pi_module_on_transport_connected(pi_module_handle_t *m, uint8_t t) {
    if (m) m->transport = t;
}

extern "C" int pi_module_on_data(pi_module_handle_t *m, uint8_t, const uint8_t *p, uint32_t n) {
    if (!m || m->stopped || !m->history || !p || n > 65532) return -1;
    QJsonParseError parse;
    auto doc = QJsonDocument::fromJson(QByteArray(reinterpret_cast<const char *>(p), int(n)), &parse);
    if (parse.error != QJsonParseError::NoError || !doc.isObject()) return -1;
    auto o = doc.object();
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto temperature = o.value("temperature_C");
    m->history->prune(now);
    if (temperature.isDouble()) m->history->add(now, temperature.toDouble());
    o["received_at"] = double(now);
    o["history_day"] = m->history->series(now, 24LL * 60 * History::minute, 15 * History::minute);
    o["history_week"] = m->history->series(now, History::week, 120 * History::minute);
    o["history_error"] = m->history->error;
    const auto data = QJsonDocument(o).toJson(QJsonDocument::Compact);
    m->host->emit_event(m->host->context, "sample", data.constData());
    return 0;
}

extern "C" int pi_module_action(pi_module_handle_t *m, const char *a) {
    if (!m || m->stopped || !a || QByteArray(a) != "request_disconnect" || !m->host->send_data) return -1;
    const QByteArray data("{\"command\":\"request_disconnect\"}");
    return m->host->send_data(m->host->context, m->transport,
                             reinterpret_cast<const uint8_t *>(data.constData()), uint32_t(data.size()));
}

extern "C" void pi_module_on_disconnect_request(pi_module_handle_t *, const char *) {}

extern "C" void pi_module_stop(pi_module_handle_t *m) {
    if (!m || m->stopped) return;
    m->stopped = true;
    if (m->history) m->history->save();
}

extern "C" void pi_module_on_detach(pi_module_handle_t *m) { pi_module_stop(m); }

extern "C" void pi_module_destroy(pi_module_handle_t *m) { delete m; }
