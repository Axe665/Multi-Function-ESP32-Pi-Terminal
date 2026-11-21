#pragma once

#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t module_id;
    const char *module_instance;
    const char *token;
    uint16_t port;
    /* 可选：mDNS 广播（_orpi-module._tcp，设计 §3.2）用的模块型号与显示名。
     * 两者为 NULL 时分别回退到 "GENERIC" / module_instance。
     *
     * module_type 的含义必须与 linkit 握手包里的 module_type 字段**逐字节相同**
     * （模块指纹 uid = SHA256(mac ‖ 16 字节定长 module_type)[0:16]）。当前固件
     * 未调用 linkit_slave_init()，握手实际发的是 linkit SDK 的默认值
     * "GENERIC"（linkit_role_device.c 的 s_module_type 初值），所以这里默认也取
     * "GENERIC"。将来若启用自定义型号，必须同时把同一字符串传给本字段，
     * 否则模块广播的 uid 与桥板 attach 携带的 uid 会对不上。 */
    const char *module_type;
    const char *display_name;
} module_data_config_t;

typedef bool (*module_data_command_cb_t)(const char *event, const char *json, void *context);
typedef bool (*module_data_wire_send_cb_t)(const uint8_t *payload, size_t length, void *context);
typedef size_t (*module_data_package_read_cb_t)(const char *file, uint32_t offset,
                                                uint8_t *buffer, size_t capacity,
                                                uint32_t *total, void *context);

// Convenience reader for a mounted filesystem directory containing the two
// package files. The directory must already be mounted by the board firmware.
size_t module_data_package_read_from_directory(const char *file, uint32_t offset,
                                               uint8_t *buffer, size_t capacity,
                                               uint32_t *total, void *context);

// The caller owns Wi-Fi initialization. Call this only after the station has
// acquired an address. The service accepts one Pi terminal connection at a time.
esp_err_t module_data_service_start(const module_data_config_t *config,
                                    module_data_command_cb_t command_callback,
                                    void *context);
/* Wi-Fi 重连拿到 IP 后调用：数据面重新可用，重新广播 _orpi-module._tcp。
 * 断开时广播已被撤销（见 module_data_wifi.c），没有这一步广播永不再出现。
 * 服务未运行时是空操作（不广播、不报错）。 */
void module_data_service_refresh_mdns(void);

esp_err_t module_data_service_start_ble(const char *device_name);
// Optional read-only HTTP endpoint for signed package files. Intended for
// hotspot package delivery while the authenticated business session remains
// on BLE; exposes only package.json and package.tar.zst from the reader.
esp_err_t module_data_service_start_package_http(uint16_t port, const char *allowed_peer_ipv4);
void module_data_service_stop_package_http(void);
void module_data_service_stop(void);
void module_data_service_set_package_reader(module_data_package_read_cb_t reader, void *context);
void module_data_service_set_ble_sender(module_data_wire_send_cb_t sender, void *context);
void module_data_service_receive(const uint8_t *payload, size_t length);
void module_data_service_receive_ble(const uint8_t *payload, size_t length);

// Publishes a raw module payload as the Pi terminal's version-1 data event.
// Payloads are Base64 encoded by the service and are bounded to 64 KiB.
esp_err_t module_data_service_publish(const uint8_t *payload, size_t length);
// Ask the host terminal to close this module session. The host responds with
// disconnect_ack; an accepted request is completed by session_close.
esp_err_t module_data_service_request_disconnect(const char *reason, bool auto_reconnect);

typedef struct {
    const char *ssid;
    const char *password;
    uint8_t max_retry;
    // Optional static IPv4 settings; when all are empty, DHCP is used.
    const char *static_ip;
    const char *netmask;
    const char *gateway;
} module_data_wifi_config_t;

// Initializes ESP-NETIF/Wi-Fi STA and waits for an address before returning.
// The caller remains responsible for avoiding conflicts with LinkIt ownership.
esp_err_t module_data_wifi_start(const module_data_wifi_config_t *config);
void module_data_wifi_stop(void);

/* Typical board integration after Wi-Fi STA/GATT setup:
 *
 *   module_data_config_t cfg = { .module_id = 0x14,
 *       .module_instance = "env-01", .token = CONFIG_PI_TOKEN, .port = 4580 };
 *   module_data_service_start(&cfg, on_command, app_context);
 *   module_data_service_set_package_reader(read_package, app_context);
 *
 * The service deliberately does not initialize Wi-Fi or mount storage because
 * those resources are board-specific and may already be owned by LinkIt.
 */
