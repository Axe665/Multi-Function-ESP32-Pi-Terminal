/* 模块 mDNS 广播：_orpi-module._tcp（设计 §3.2）。
 *
 * 依赖：ESP-IDF 官方 mdns 组件（组件名 mdns，头文件 mdns.h）。ESP-IDF 5.x 的
 * 主仓不再自带该组件，需要由工程通过 idf_component.yml 声明
 *   dependencies:
 *     espressif/mdns: "^1.8"
 * 或预置 managed_components/espressif__mdns。
 *
 * shortcut: 默认关闭（CONFIG_MODULE_DATA_MDNS_ENABLED=n），因为本仓库要能离线
 * 构建；需要周边扫描时在 sdkconfig 打开并确保 mdns 组件已获取。关闭时本文件只
 * 提供空实现，数据面仍可用，主机走 BLE/手动连接。
 */
#include "module_data_mdns.h"
#include "sdkconfig.h"

#if CONFIG_MODULE_DATA_MDNS_ENABLED

#include "esp_log.h"
#include "esp_mac.h"
#include "mdns.h"
#include "mbedtls/sha256.h"

#include <stdio.h>
#include <string.h>

#define MODULE_MDNS_SERVICE "_orpi-module"
#define MODULE_MDNS_PROTO "_tcp"
#define MODULE_MDNS_TYPE_LEN 16
#define MODULE_MDNS_DEFAULT_TYPE "GENERIC"

static const char *TAG = "PI_MODULE_MDNS";

static bool s_mdns_started;
// 只有本组件真正调用 mdns_init() 成功时才在 stop 里 mdns_free()：
// ESP-IDF 的 mDNS 实例可能被同固件的其它组件共用（例如配网），
// 释放别人的实例会让那些功能静默失效。
static bool s_mdns_owned;
static bool s_service_added;
static char s_uid[33];

bool module_data_module_uid(char out[33], const char *module_type)
{
    if (out == NULL) return false;
    out[0] = '\0';

    uint8_t mac[6] = {0};
    if (esp_read_mac(mac, ESP_MAC_WIFI_STA) != ESP_OK) return false;

    /* 布局与桥板 pbridge_module_uid() 严格一致：6 字节 MAC + 16 字节定长
     * module_type（不足补 0）。不要在这里改成"字符串 + 长度前缀"之类。 */
    uint8_t input[6 + MODULE_MDNS_TYPE_LEN];
    memset(input, 0, sizeof(input));
    memcpy(input, mac, sizeof(mac));
    const char *type = (module_type != NULL && module_type[0] != '\0')
                           ? module_type
                           : MODULE_MDNS_DEFAULT_TYPE;
    size_t type_len = strnlen(type, MODULE_MDNS_TYPE_LEN);
    if (type_len > MODULE_MDNS_TYPE_LEN) type_len = MODULE_MDNS_TYPE_LEN;
    memcpy(input + 6, type, type_len);

    unsigned char digest[32];
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    const int started = mbedtls_sha256_starts(&ctx, 0);
    const int updated = started == 0 ? mbedtls_sha256_update(&ctx, input, sizeof(input)) : -1;
    const int finished = updated == 0 ? mbedtls_sha256_finish(&ctx, digest) : -1;
    mbedtls_sha256_free(&ctx);
    if (finished != 0) return false;

    for (int i = 0; i < 16; ++i) snprintf(out + i * 2, 3, "%02x", digest[i]);
    out[32] = '\0';
    return true;
}

const char *module_data_mdns_uid(void)
{
    return s_uid;
}

void module_data_mdns_stop(void)
{
    if (s_service_added) {
        (void)mdns_service_remove(MODULE_MDNS_SERVICE, MODULE_MDNS_PROTO);
        s_service_added = false;
    }
    if (s_mdns_started && s_mdns_owned) {
        mdns_free();
    }
    s_mdns_started = false;
    s_mdns_owned = false;
    s_uid[0] = '\0';
}

esp_err_t module_data_mdns_start(uint8_t module_id, uint16_t port,
                                 const char *module_type, const char *display_name)
{
    if (module_id == 0 || port == 0) return ESP_ERR_INVALID_ARG;

    // 幂等：先撤销旧广播（端口/名称可能随重连变化）。
    module_data_mdns_stop();

    char uid[33];
    if (!module_data_module_uid(uid, module_type)) {
        // 拿不到 MAC 时不能广播一个假 uid：宁可没有广播，让主机走 BLE/手动。
        ESP_LOGW(TAG, "module uid unavailable (no WiFi MAC); mDNS broadcast skipped");
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t err = mdns_init();
    if (err == ESP_OK) {
        s_mdns_owned = true;
    } else if (err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "mdns_init failed: %s", esp_err_to_name(err));
        return err;
    }
    s_mdns_started = true;

    // 主机名只用于 mDNS 报文里的 host 段，用 uid 前 8 位避免冲突。
    char hostname[24];
    snprintf(hostname, sizeof(hostname), "orpi-%.8s", uid);
    err = mdns_hostname_set(hostname);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "mdns_hostname_set(%s) failed: %s", hostname, esp_err_to_name(err));
        module_data_mdns_stop();
        return err;
    }

    const char *display = (display_name != NULL && display_name[0] != '\0') ? display_name : hostname;
    (void)mdns_instance_name_set(display);

    char mid[8];
    snprintf(mid, sizeof(mid), "%u", (unsigned)module_id);
    char port_text[8];
    snprintf(port_text, sizeof(port_text), "%u", (unsigned)port);

    mdns_txt_item_t txt[] = {
        {.key = "v", .value = "1"},
        {.key = "uid", .value = uid},
        {.key = "mid", .value = mid},
        {.key = "port", .value = port_text},
        {.key = "name", .value = display},
    };
    err = mdns_service_add(NULL, MODULE_MDNS_SERVICE, MODULE_MDNS_PROTO, port, txt,
                           sizeof(txt) / sizeof(txt[0]));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "mdns_service_add failed: %s", esp_err_to_name(err));
        module_data_mdns_stop();
        return err;
    }
    s_service_added = true;
    strlcpy(s_uid, uid, sizeof(s_uid));
    ESP_LOGI(TAG, "advertising _orpi-module._tcp uid=%s mid=%u port=%u name=%s",
             s_uid, (unsigned)module_id, (unsigned)port, display);
    return ESP_OK;
}

#else

bool module_data_module_uid(char out[33], const char *module_type)
{
    (void)module_type;
    if (out != NULL) out[0] = '\0';
    return false;
}

esp_err_t module_data_mdns_start(uint8_t module_id, uint16_t port,
                                 const char *module_type, const char *display_name)
{
    (void)module_id; (void)port; (void)module_type; (void)display_name;
    return ESP_ERR_NOT_SUPPORTED;
}

void module_data_mdns_stop(void) {}

const char *module_data_mdns_uid(void) { return ""; }

#endif
