#pragma once

// Small, dependency-free C++ helpers for external module authors.  The ABI
// itself remains pi_module_api.h; this header only reduces repetitive safety
// checks and keeps the host callback usage consistent.
//
// 每个封装都先判空函数指针：宿主版本不同，老宿主可能没填 network_request /
// file_request；直接调用会段错误，而段错误发生在 worker 里，模块自己看不到。
#include "pi_module_api.h"
#include <cstdint>
#include <string>

namespace pi_module_sdk {
inline bool valid(const pi_module_handle_t *module, const char *text) {
    return module && text && *text;
}

// ---- 业务数据 ----

// 向设备侧下行一段 JSON（走当前 transport 的 data 通道）。
// 返回宿主 send_data 的原始结果：>= 0 成功，< 0 表示当前没有可用链路。
inline int send_json(pi_module_handle_t *module, const pi_host_services_t *host,
                     uint8_t transport, const std::string &json) {
    if (!module || !host || !host->send_data || json.size() > UINT32_MAX)
        return -1;
    return host->send_data(host->context, transport,
                           reinterpret_cast<const uint8_t *>(json.data()),
                           static_cast<uint32_t>(json.size()));
}

// 把一条结构化记录交给宿主（写进 data_schema 对应的存储）。
// 优先用 emit_event（带 context，v3 推荐）；老宿主只有 publish_event 时回退。
// 注意：type 必须在 manifest.json 的 data_schema.records 里声明过，
// 写成未声明的名字宿主会静默丢弃，不报错也不记录。
inline void publish(const pi_host_services_t *host, const char *type,
                    const std::string &json) {
    if (!host || !type) return;
    if (host->emit_event)
        host->emit_event(host->context, type, json.c_str());
    else if (host->publish_event)
        host->publish_event(type, json.c_str());
}

// ---- 诊断与日志 ----

inline void log(const pi_host_services_t *host, int level,
                const std::string &message) {
    if (host && host->log) host->log(level, message.c_str());
}

// PBR1 桥控制面。只用于桥板诊断（PI_BRIDGE_CONTROL_PING / _STATUS），
// 不是业务数据通道；业务一律走 send_json。
inline int send_control(const pi_host_services_t *host, uint8_t command,
                        const void *payload, uint16_t length,
                        uint16_t *sequence_out = nullptr) {
    if (!host || !host->send_control) return -1;
    return host->send_control(host->context, command,
                              static_cast<const uint8_t *>(payload), length,
                              sequence_out);
}

// ---- v2 宿主能力：数据目录、HTTP(S)、文件 ----

// 模块自己的可写数据目录（宿主按模块实例分配，sandbox 允许写的就是这里）。
// 返回 nullptr 表示宿主没提供；返回的指针生命周期由宿主管理，不要 free。
inline const char *data_directory(const pi_host_services_t *host) {
    if (!host || !host->data_directory) return nullptr;
    return host->data_directory();
}

// 宿主 broker 的同步 HTTP(S) 请求。request_json 形如：
//   {"method":"GET|POST|...","url":"https://...","headers":{},
//    "bodyBase64":"...","timeoutMs":...}
// 返回的 JSON 形如 {"ok":true,"status":200,"headers":{},"bodyBase64":"..."}
// 或 {"ok":false,"error":"..."}。
//
// 三个必须知道的约束：
//   1. 只允许公网目标（宿主拒绝内网/环回地址），且需要 manifest 的 network_api
//      被宿主授予该模块的网络权限，否则返回 ok:false；
//   2. 同步阻塞，最长 35 秒；不要在 UI 线程或 on_data 的热路径里调用；
//   3. 返回的 const char* 只活到下一次调用，这里拷成 std::string 再返回。
inline std::string network_request(const pi_host_services_t *host,
                                   const std::string &request_json) {
    if (!host || !host->network_request)
        return R"({"ok":false,"error":"host does not provide network_request"})";
    const char *response = host->network_request(host->context, request_json.c_str());
    return response ? std::string(response)
                    : std::string(R"({"ok":false,"error":"empty response"})");
}

// 受控文件 API：request_json 的 "op" 取 read / write / mkdir / rename / remove。
// 写类操作被限制在本模块的 app data root；读可以到授权范围，敏感路径由外置
// daemon 拒绝。需要 manifest 的 file_api 被授权，否则返回 ok:false。
// 与 network_request 一样是同步阻塞、返回值只活到下一次调用。
inline std::string file_request(const pi_host_services_t *host,
                                const std::string &request_json) {
    if (!host || !host->file_request)
        return R"({"ok":false,"error":"host does not provide file_request"})";
    const char *response = host->file_request(host->context, request_json.c_str());
    return response ? std::string(response)
                    : std::string(R"({"ok":false,"error":"empty response"})");
}

// ---- 能力探测：决定要不要走 v2 通道 ----

inline bool has_network(const pi_host_services_t *host) {
    return host && host->network_request;
}
inline bool has_file(const pi_host_services_t *host) {
    return host && host->file_request;
}
inline bool has_data_directory(const pi_host_services_t *host) {
    return host && host->data_directory;
}
} // namespace pi_module_sdk
