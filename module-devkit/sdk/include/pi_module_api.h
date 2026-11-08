#pragma once

#include <stdint.h>

// v2 起每个模块必须返回这个版本，并在 manifest 声明 platform_api/network_api。
// 缺声明或旧版返回 1 的模块在 ModuleManager/worker 加载前拒绝。
#define PI_MODULE_API_VERSION 2u

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pi_host_services pi_host_services_t;
typedef struct pi_module_handle pi_module_handle_t;

enum {
    PI_TRANSPORT_BLE = 1,
    PI_TRANSPORT_HOTSPOT_LAN = 2,
};

// send_control is reserved for PBR1 bridge diagnostics. Business commands and
// payloads must use send_data on the active BLE/LAN module session.
enum {
    PI_BRIDGE_CONTROL_PING = 1,
    PI_BRIDGE_CONTROL_STATUS = 2,
};

struct pi_host_services {
    uint32_t api_version;
    void *context;
    int (*send_control)(void *context, uint8_t command,
                        const uint8_t *payload, uint16_t length,
                        uint16_t *sequence_out);
    int (*send_data)(void *context, uint8_t transport,
                     const uint8_t *payload, uint32_t length);
    void (*publish_action)(const char *action_id, const char *text);
    void (*publish_event)(const char *type, const char *json);
    const char *(*data_directory)();
    void (*log)(int level, const char *message);
    // Appended context-aware publication; original v1 prefix remains unchanged.
    void (*emit_event)(void *context, const char *type, const char *json);
    // v2: 宿主 broker 的同步 HTTP(S) 封装。request_json 为
    // {method,url,headers:{},bodyBase64,timeoutMs}；返回 UTF-8 JSON，
    // 生命周期到下一次调用。失败返回 {"ok":false,"error":"..."}。
    // 目标仅限公网；权限由宿主按模块实例判定。
    const char *(*network_request)(void *context, const char *request_json);
    // v2: 文件 API。request_json 的 op 见 docs/devdocs/22；仅允许家目录只读
    // + 本包 app 数据可写，敏感路径由外置 daemon 拒绝。返回 JSON 生命周期
    // 到下一次调用。
    const char *(*file_request)(void *context, const char *request_json);
};

uint32_t pi_module_api_version(void);
const char *pi_module_manifest_json(void);
pi_module_handle_t *pi_module_create(const pi_host_services_t *host);
void pi_module_destroy(pi_module_handle_t *module);
int pi_module_on_attach(pi_module_handle_t *module, const char *transport_json);
void pi_module_on_transport_connected(pi_module_handle_t *module, uint8_t transport);
int pi_module_on_data(pi_module_handle_t *module, uint8_t transport,
                      const uint8_t *payload, uint32_t payload_length);
void pi_module_on_disconnect_request(pi_module_handle_t *module, const char *json);
void pi_module_on_detach(pi_module_handle_t *module);
void pi_module_stop(pi_module_handle_t *module);
const char *pi_module_qml_page(pi_module_handle_t *module);
int pi_module_action(pi_module_handle_t *module, const char *action);

#ifdef __cplusplus
}
#endif
