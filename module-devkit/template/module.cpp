// 模块入口：实现 pi_module_api.h 声明的 C ABI。
//
// 宿主（ModuleManager / worker）按下列顺序调用：
//   pi_module_api_version -> pi_module_manifest_json -> pi_module_create
//   -> pi_module_on_attach -> pi_module_on_transport_connected
//   -> pi_module_on_data (可多次) -> pi_module_action (可多次)
//   -> pi_module_stop -> pi_module_detach -> pi_module_destroy
//
// 三条硬规则，违反其中任何一条宿主都会拒载或静默丢数据：
//   1. pi_module_api_version 必须返回 PI_MODULE_API_VERSION（当前 3）；
//   2. manifest.json 必须声明 platform_api=2 与合法的 data_schema；
//   3. 业务数据一律走 pi_module_sdk::publish，且记录名必须已写进 data_schema。
//      写成 schema 里没有的名字，宿主的 DataSchema 直接丢弃，不报错。
//
// 本文件把固件每秒上报的 JSON 转成 sample.demo 记录；真实模块在这里做协议解析。
#include "pi_module_sdk.h"
#include "module_manifest.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>

#include <string>

struct pi_module_handle {
    const pi_host_services_t *host = nullptr;
    uint8_t transport = PI_TRANSPORT_BLE;
    bool attached = false;
};

extern "C" uint32_t pi_module_api_version() { return PI_MODULE_API_VERSION; }

extern "C" const char *pi_module_manifest_json() { return MODULE_MANIFEST_JSON; }

extern "C" pi_module_handle_t *pi_module_create(const pi_host_services_t *host) {
    if (!host || host->api_version != PI_MODULE_API_VERSION) return nullptr;
    auto *module = new pi_module_handle;
    module->host = host;
    return module;
}

extern "C" void pi_module_destroy(pi_module_handle_t *module) { delete module; }

// 返回 0 表示接受这次附着；非 0 会让宿主把模块标记为 attach 失败。
extern "C" int pi_module_on_attach(pi_module_handle_t *module, const char *transport_json) {
    if (!module) return -1;
    module->attached = true;
    pi_module_sdk::log(module->host, 2,
                       std::string("attached: ") + (transport_json ? transport_json : "{}"));
    const QJsonObject ready{{QStringLiteral("at"), double(QDateTime::currentMSecsSinceEpoch())}};
    pi_module_sdk::publish(module->host, "event.module_ready",
                           QJsonDocument(ready).toJson(QJsonDocument::Compact).toStdString());
    return 0;
}

extern "C" void pi_module_on_transport_connected(pi_module_handle_t *module, uint8_t transport) {
    if (module) module->transport = transport;
}

// 设备侧上行的原始字节：解析固件的 JSON，按 data_schema 发布结构化记录。
extern "C" int pi_module_on_data(pi_module_handle_t *module, uint8_t transport,
                                 const uint8_t *payload, uint32_t payload_length) {
    if (!module || (!payload && payload_length)) return -1;
    (void)transport;
    const QJsonDocument document =
        QJsonDocument::fromJson(QByteArray(reinterpret_cast<const char *>(payload), int(payload_length)));
    if (!document.isObject()) return -1;

    QJsonObject sample = document.object();
    QJsonObject record;
    for (const char *key : {"value_a", "value_b", "value_c"}) {
        if (sample.contains(QLatin1String(key))) record.insert(QLatin1String(key), sample.value(QLatin1String(key)));
    }
    record.insert(QStringLiteral("online"), true);
    pi_module_sdk::publish(module->host, "sample.demo",
                           QJsonDocument(record).toJson(QJsonDocument::Compact).toStdString());
    return 0;
}

extern "C" void pi_module_on_disconnect_request(pi_module_handle_t *module, const char *json) {
    (void)module;
    (void)json;
}

extern "C" void pi_module_on_detach(pi_module_handle_t *module) {
    if (module) module->attached = false;
}

extern "C" void pi_module_stop(pi_module_handle_t *module) {
    if (module) module->attached = false;
}

// QML 页面路径，相对本模块包根目录。worker 会把它交给宿主的 ModulePageHost。
extern "C" const char *pi_module_qml_page(pi_module_handle_t *module) {
    (void)module;
    return "qml/ModulePage.qml";
}

// UI 上的按钮回调。action 名字必须出现在 manifest.json 的 actions 数组里。
extern "C" int pi_module_action(pi_module_handle_t *module, const char *action) {
    if (!module || !action) return -1;
    const std::string name(action);
    if (name == "ping") {
        return pi_module_sdk::send_json(module, module->host, module->transport,
                                        R"({"command":"ping"})");
    }
    return -1;  // 未知 action：告诉宿主不支持
}
