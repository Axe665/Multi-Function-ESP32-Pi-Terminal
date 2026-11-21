#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/base64.h"
#include "nvs.h"
#include "nvs_flash.h"

#include "bed_logic.h"
#include "hx711.h"
#include "module_control_service.h"
#include "module_data_service.h"

#define MODULE_ID 84
#define CELL_COUNT 4
#define CELL_FAULT_LIMIT 5
#define NVS_NAMESPACE "bedsensor"
#define NVS_KEY "cal"
#define CAL_MAGIC 0x42454453u  // "BEDS"
#define CAL_VERSION 1

#define BED_W_CM ((float)CONFIG_BED_BED_WIDTH_MM / 10.0f)
#define BED_L_CM ((float)CONFIG_BED_BED_LENGTH_MM / 10.0f)

#if CONFIG_BED_SAMPLE_RATE_SPS < 8
#define MOTION_WINDOW 8
#elif CONFIG_BED_SAMPLE_RATE_SPS > 128
#define MOTION_WINDOW 128
#else
#define MOTION_WINDOW CONFIG_BED_SAMPLE_RATE_SPS
#endif

static const char *TAG = "bed";

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t reserved;
    int32_t offset[CELL_COUNT];
    float scale[CELL_COUNT];
} cal_blob_t;

typedef enum {
    ACK_NONE = 0,
    ACK_TARE,
    ACK_CAL_START,
    ACK_CAL_NEXT,
    ACK_CAL_DONE,
    ACK_RESET,
    ACK_STATUS,
    ACK_ERROR,
} ack_t;

static hx711_t s_cell[CELL_COUNT];
static bool s_cell_ready[CELL_COUNT];
static int32_t s_last_raw[CELL_COUNT];
static int s_fault[CELL_COUNT];
static float s_last_kg[CELL_COUNT];
static cal_blob_t s_cal;
static bool s_need_tare;

static volatile bool s_data_ready;
static volatile bool s_tare_req;
static volatile bool s_cal_req;
static volatile bool s_reset_req;
static volatile bool s_status_req;
static volatile int s_ack;

static int s_cal_step;  // 0 idle, 1..4 waiting for a corner, 5 done
static bool s_cal_holding;
static uint32_t s_cal_hold_since;
static int s_cal_samples;
static int64_t s_cal_sum;
static uint32_t s_cal_done_ms;

static volatile bool s_direct_cal_req;
static volatile int s_direct_cal_ch;
static volatile float s_direct_cal_kg;

static uint32_t s_evt_seq;

extern const uint8_t _binary_embedded_package_json_start[];
extern const uint8_t _binary_embedded_package_json_end[];
extern const uint8_t _binary_embedded_package_tar_zst_start[];
extern const uint8_t _binary_embedded_package_tar_zst_end[];

static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

static size_t package_reader(const char *file, uint32_t offset, uint8_t *buffer,
                             size_t capacity, uint32_t *total, void *context) {
    (void)context;
    const uint8_t *start = NULL;
    const uint8_t *end = NULL;
    if (strcmp(file, "package.json") == 0) {
        start = _binary_embedded_package_json_start;
        end = _binary_embedded_package_json_end;
    } else if (strcmp(file, "package.tar.zst") == 0) {
        start = _binary_embedded_package_tar_zst_start;
        end = _binary_embedded_package_tar_zst_end;
    } else {
        return 0;
    }
    const size_t size = (size_t)(end - start);
    if (!size || offset >= size || !buffer || !capacity || !total) return 0;
    *total = (uint32_t)size;
    if (capacity > size - offset) capacity = size - offset;
    memcpy(buffer, start + offset, capacity);
    return capacity;
}

static void cal_defaults(void) {
    memset(&s_cal, 0, sizeof(s_cal));
    s_cal.magic = CAL_MAGIC;
    s_cal.version = CAL_VERSION;
    for (int i = 0; i < CELL_COUNT; ++i)
        s_cal.scale[i] = 1.0f / (float)CONFIG_BED_NOMINAL_COUNTS_PER_KG;
}

static bool cal_load(void) {
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle) != ESP_OK) return false;
    cal_blob_t loaded;
    size_t length = sizeof(loaded);
    const esp_err_t err = nvs_get_blob(handle, NVS_KEY, &loaded, &length);
    nvs_close(handle);
    if (err != ESP_OK || length != sizeof(loaded)) return false;
    if (loaded.magic != CAL_MAGIC || loaded.version != CAL_VERSION) return false;
    for (int i = 0; i < CELL_COUNT; ++i) {
        if (!isfinite(loaded.scale[i]) || fabsf(loaded.scale[i]) < 1e-7f ||
            fabsf(loaded.scale[i]) > 1e-2f)
            return false;
    }
    s_cal = loaded;
    return true;
}

static void cal_save(void) {
    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        ESP_LOGW(TAG, "nvs open failed, calibration is RAM only");
        return;
    }
    const esp_err_t err = nvs_set_blob(handle, NVS_KEY, &s_cal, sizeof(s_cal));
    if (err == ESP_OK) nvs_commit(handle);
    else ESP_LOGW(TAG, "nvs set blob: %s", esp_err_to_name(err));
    nvs_close(handle);
}

// Averages both raw offset and noise. The bed must be empty while this runs.
static void tare_now(void) {
    int64_t sum[CELL_COUNT] = {0};
    int count[CELL_COUNT] = {0};
    const int64_t start = esp_timer_get_time();
    while (esp_timer_get_time() - start < 2000000) {
        for (int i = 0; i < CELL_COUNT; ++i) {
            if (!s_cell_ready[i]) continue;
            int32_t raw;
            if (hx711_read(&s_cell[i], &raw, CONFIG_BED_READ_TIMEOUT_MS) == ESP_OK) {
                sum[i] += raw;
                count[i]++;
                s_last_raw[i] = raw;
                s_fault[i] = 0;
            }
        }
        vTaskDelay(1);
    }
    for (int i = 0; i < CELL_COUNT; ++i) {
        if (count[i] > 0) s_cal.offset[i] = (int32_t)(sum[i] / count[i]);
    }
    cal_save();
    ESP_LOGI(TAG, "tare done");
}

static void calibration_tick(const float kg[CELL_COUNT], const int32_t raw[CELL_COUNT],
                             bool all_ok, uint32_t now) {
    if (s_cal_step < 1 || s_cal_step > 4) return;
    if (!all_ok) {
        s_cal_holding = false;
        return;
    }

    const int ch = s_cal_step - 1;
    const float cal_kg = (float)CONFIG_BED_CAL_WEIGHT_KG;
    bool isolated = kg[ch] >= cal_kg * 0.5f;
    for (int i = 0; i < CELL_COUNT; ++i) {
        if (i != ch && kg[i] > cal_kg * 0.2f) isolated = false;
    }
    if (!isolated) {
        s_cal_holding = false;
        return;
    }

    if (!s_cal_holding) {
        s_cal_holding = true;
        s_cal_hold_since = now;
        s_cal_samples = 0;
        s_cal_sum = 0;
    }
    s_cal_sum += raw[ch];
    s_cal_samples++;
    if (now - s_cal_hold_since < 1500 || s_cal_samples < 8) return;

    const double average = (double)s_cal_sum / (double)s_cal_samples;
    const double delta = average - (double)s_cal.offset[ch];
    const double scale = (fabs(delta) > 500.0) ? (double)CONFIG_BED_CAL_WEIGHT_KG / delta : 0.0;
    if (fabs(scale) > 1e-7 && fabs(scale) < 1e-2) {
        s_cal.scale[ch] = (float)scale;
        cal_save();
        s_cal_holding = false;
        s_cal_step++;
        if (s_cal_step > 4) {
            s_cal_step = 5;
            s_cal_done_ms = now;
            s_ack = ACK_CAL_DONE;
        } else {
            s_ack = ACK_CAL_NEXT;
        }
        ESP_LOGI(TAG, "calibrated channel %d scale=%f", ch, scale);
    } else {
        s_cal_holding = false;
        s_cal_step = 0;
        s_ack = ACK_ERROR;
        ESP_LOGW(TAG, "calibration rejected, delta=%f", delta);
    }
}

static bed_event_t highest_event(uint32_t mask) {
    if (mask & (1u << BED_EVT_EXIT)) return BED_EVT_EXIT;
    if (mask & (1u << BED_EVT_ENTER)) return BED_EVT_ENTER;
    if (mask & (1u << BED_EVT_NO_RETURN)) return BED_EVT_NO_RETURN;
    if (mask & (1u << BED_EVT_EDGE)) return BED_EVT_EDGE;
    if (mask & (1u << BED_EVT_SIT)) return BED_EVT_SIT;
    if (mask & (1u << BED_EVT_TURN)) return BED_EVT_TURN;
    return BED_EVT_NONE;
}

static const char *ack_name(ack_t ack) {
    switch (ack) {
    case ACK_TARE: return "tare_ok";
    case ACK_CAL_START: return "cal_start";
    case ACK_CAL_NEXT: return "cal_next";
    case ACK_CAL_DONE: return "cal_done";
    case ACK_RESET: return "reset_ok";
    case ACK_STATUS: return "status_ok";
    case ACK_ERROR: return "error";
    default: return NULL;
    }
}

static const char *cal_name(void) {
    static const char *const names[] = {"idle", "ch1", "ch2", "ch3", "ch4", "done"};
    if (s_cal_step < 0 || s_cal_step > 5) return "idle";
    return names[s_cal_step];
}

static void publish_status(const bed_logic_t *logic, uint32_t events,
                           const float kg[CELL_COUNT], bool all_ok,
                           float weight, float x_cm, float y_cm, float motion,
                           uint32_t now) {
    if (!s_data_ready) return;

    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddNumberToObject(root, "v", 1);
    cJSON_AddNumberToObject(root, "w", roundf(weight * 10.0f) / 10.0f);
    cJSON_AddNumberToObject(root, "x", roundf(x_cm * 10.0f) / 10.0f);
    cJSON_AddNumberToObject(root, "y", roundf(y_cm * 10.0f) / 10.0f);
    cJSON_AddBoolToObject(root, "present", logic->present);
    cJSON_AddStringToObject(root, "state", bed_state_name(logic->state));
    cJSON_AddNumberToObject(root, "mov", roundf(motion * 100.0f) / 100.0f);
    cJSON_AddStringToObject(root, "event", bed_event_name(highest_event(events)));
    cJSON_AddNumberToObject(root, "evt", s_evt_seq);
    cJSON_AddNumberToObject(root, "in_ms", logic->in_bed_ms);
    cJSON_AddNumberToObject(root, "out_ms", logic->leave_ms);
    cJSON_AddStringToObject(root, "cal", cal_name());
    cJSON_AddNumberToObject(root, "fault", all_ok ? 0 : 1);
    cJSON_AddNumberToObject(root, "bw", BED_W_CM);
    cJSON_AddNumberToObject(root, "bl", BED_L_CM);
    cJSON_AddNumberToObject(root, "em", (float)CONFIG_BED_EDGE_CM);
    cJSON_AddNumberToObject(root, "cw", CONFIG_BED_CAL_WEIGHT_KG);
    cJSON_AddNumberToObject(root, "t", now);

    cJSON *channels = cJSON_AddArrayToObject(root, "ch");
    if (channels) {
        for (int i = 0; i < CELL_COUNT; ++i)
            cJSON_AddItemToArray(channels,
                                 cJSON_CreateNumber(roundf(kg[i] * 10.0f) / 10.0f));
    }

    const char *ack = ack_name((ack_t)s_ack);
    if (ack) cJSON_AddStringToObject(root, "ack", ack);

    char *text = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!text) return;
    const esp_err_t err = module_data_service_publish((const uint8_t *)text, strlen(text));
    if (err != ESP_OK) ESP_LOGW(TAG, "publish failed: %s", esp_err_to_name(err));
    cJSON_free(text);
}

static bool direct_cal_request(const cJSON *command) {
    const cJSON *ch = cJSON_GetObjectItemCaseSensitive(command, "ch");
    const cJSON *kg = cJSON_GetObjectItemCaseSensitive(command, "kg");
    if (!cJSON_IsNumber(ch) || !cJSON_IsNumber(kg)) return false;
    if (ch->valueint < 1 || ch->valueint > CELL_COUNT || kg->valuedouble <= 0) return false;
    s_direct_cal_ch = ch->valueint - 1;
    s_direct_cal_kg = (float)kg->valuedouble;
    s_direct_cal_req = true;
    return true;
}

static bool on_command(const char *event, const char *json, void *context) {
    (void)context;
    if (!event || strcmp(event, "data") != 0 || !json) return true;

    char decoded[512];
    const char *command_json = json;
    cJSON *outer = cJSON_Parse(json);
    if (outer) {
        const cJSON *payload = cJSON_GetObjectItemCaseSensitive(outer, "payload");
        if (cJSON_IsString(payload) && payload->valuestring) {
            size_t length = 0;
            const int result = mbedtls_base64_decode(
                (unsigned char *)decoded, sizeof(decoded) - 1, &length,
                (const unsigned char *)payload->valuestring, strlen(payload->valuestring));
            if (result == 0) {
                decoded[length] = '\0';
                command_json = decoded;
            }
        }
        cJSON_Delete(outer);
    }

    cJSON *command = cJSON_Parse(command_json);
    if (!command) return true;
    const cJSON *name = cJSON_GetObjectItemCaseSensitive(command, "command");
    if (cJSON_IsString(name) && name->valuestring) {
        if (strcmp(name->valuestring, "tare") == 0) {
            s_tare_req = true;
            s_ack = ACK_TARE;
        } else if (strcmp(name->valuestring, "calibrate") == 0) {
            s_cal_req = true;
            s_ack = ACK_CAL_START;
        } else if (strcmp(name->valuestring, "reset") == 0) {
            s_reset_req = true;
            s_ack = ACK_RESET;
        } else if (strcmp(name->valuestring, "status") == 0) {
            s_status_req = true;
            s_ack = ACK_STATUS;
        } else if (strcmp(name->valuestring, "cal") == 0) {
            if (direct_cal_request(command)) s_ack = ACK_CAL_NEXT;
            else s_ack = ACK_ERROR;
        }
    }
    cJSON_Delete(command);
    return true;
}

static void bed_task(void *argument) {
    (void)argument;
    const bed_logic_config_t config = {
        .present_kg = (float)CONFIG_BED_PRESENT_KG,
        .absent_kg = (float)CONFIG_BED_ABSENT_KG,
        .enter_ms = CONFIG_BED_ENTER_MS,
        .exit_ms = CONFIG_BED_EXIT_MS,
        .turn_cm = (float)CONFIG_BED_TURN_CM,
        .sit_cm = (float)CONFIG_BED_SIT_CM,
        .shift_hold_ms = CONFIG_BED_SHIFT_HOLD_MS,
        .edge_margin_cm = (float)CONFIG_BED_EDGE_CM,
        .edge_ms = CONFIG_BED_EDGE_HOLD_MS,
        .no_return_ms = (uint32_t)CONFIG_BED_NO_RETURN_MIN * 60000u,
        .bed_w_cm = BED_W_CM,
        .bed_l_cm = BED_L_CM,
    };

    bed_logic_t logic;
    bed_logic_reset(&logic);

    float history[MOTION_WINDOW];
    memset(history, 0, sizeof(history));
    int history_count = 0;
    int history_index = 0;

    if (s_need_tare) {
        tare_now();
        s_need_tare = false;
    }

    uint32_t last_publish = 0;

    while (true) {
        uint32_t now = now_ms();

        if (s_reset_req) {
            s_reset_req = false;
            cal_defaults();
            cal_save();
            s_cal_step = 0;
            s_cal_holding = false;
            tare_now();
            ESP_LOGI(TAG, "calibration reset");
        }
        if (s_tare_req) {
            s_tare_req = false;
            tare_now();
            s_cal_step = 0;
            s_cal_holding = false;
        }
        if (s_cal_req) {
            s_cal_req = false;
            s_cal_step = 1;
            s_cal_holding = false;
            ESP_LOGI(TAG, "calibration wizard started");
        }
        if (s_direct_cal_req) {
            s_direct_cal_req = false;
            const int ch = s_direct_cal_ch;
            if (ch >= 0 && ch < CELL_COUNT && s_cell_ready[ch]) {
                const double delta = (double)s_last_raw[ch] - (double)s_cal.offset[ch];
                const double scale = (fabs(delta) > 500.0)
                                         ? (double)s_direct_cal_kg / delta
                                         : 0.0;
                if (fabs(scale) > 1e-7 && fabs(scale) < 1e-2) {
                    s_cal.scale[ch] = (float)scale;
                    cal_save();
                    s_ack = ACK_CAL_NEXT;
                } else {
                    s_ack = ACK_ERROR;
                }
            } else {
                s_ack = ACK_ERROR;
            }
        }

        bool all_ok = true;
        float kg[CELL_COUNT];
        int32_t raw[CELL_COUNT];
        for (int i = 0; i < CELL_COUNT; ++i) {
            raw[i] = s_last_raw[i];
            if (s_cell_ready[i]) {
                int32_t value;
                if (hx711_read(&s_cell[i], &value, CONFIG_BED_READ_TIMEOUT_MS) == ESP_OK) {
                    raw[i] = value;
                    s_last_raw[i] = value;
                    s_fault[i] = 0;
                } else if (s_fault[i] < 1000) {
                    s_fault[i]++;
                }
            } else {
                s_fault[i] = CELL_FAULT_LIMIT;
            }

            const bool ok = s_fault[i] < CELL_FAULT_LIMIT;
            all_ok = all_ok && ok;
            float value_kg = ((float)raw[i] - (float)s_cal.offset[i]) * s_cal.scale[i];
            if (!ok) value_kg = s_last_kg[i];
            s_last_kg[i] = value_kg;
            kg[i] = value_kg;
        }

        float weight = 0.0f;
        for (int i = 0; i < CELL_COUNT; ++i) weight += kg[i];
        if (weight < 0.0f) weight = 0.0f;

        float x_cm = -1.0f;
        float y_cm = -1.0f;
        if (weight > 0.5f) {
            x_cm = (kg[1] + kg[3]) * BED_W_CM / weight;
            y_cm = (kg[2] + kg[3]) * BED_L_CM / weight;
            if (x_cm < 0.0f) x_cm = 0.0f;
            if (x_cm > BED_W_CM) x_cm = BED_W_CM;
            if (y_cm < 0.0f) y_cm = 0.0f;
            if (y_cm > BED_L_CM) y_cm = BED_L_CM;
        }

        history[history_index] = weight;
        history_index = (history_index + 1) % MOTION_WINDOW;
        if (history_count < MOTION_WINDOW) history_count++;

        float mean = 0.0f;
        for (int i = 0; i < history_count; ++i) mean += history[i];
        mean /= (float)history_count;
        float variance = 0.0f;
        for (int i = 0; i < history_count; ++i) {
            const float delta = history[i] - mean;
            variance += delta * delta;
        }
        variance /= (float)history_count;

        const bed_logic_input_t input = {
            .weight_kg = weight,
            .x_cm = x_cm,
            .y_cm = y_cm,
            .motion_kg = sqrtf(variance),
            .valid = all_ok,
        };
        const uint32_t events = bed_logic_update(&logic, &config, &input, now);

        calibration_tick(kg, raw, all_ok, now);

        // Slow zero tracking while the bed is empty; never saved automatically.
        if (logic.state == BED_STATE_OUT && all_ok && input.motion_kg < 0.01f &&
            s_cal_step == 0) {
            for (int i = 0; i < CELL_COUNT; ++i) {
                if (s_cell_ready[i])
                    s_cal.offset[i] += (s_last_raw[i] - s_cal.offset[i]) / 4096;
            }
        }

        if (s_cal_step == 5 && now - s_cal_done_ms > 3000) s_cal_step = 0;

        if (events != 0 || s_status_req || now - last_publish >= CONFIG_BED_PUBLISH_MS) {
            if (events != 0) s_evt_seq++;
            publish_status(&logic, events, kg, all_ok, weight, x_cm, y_cm,
                           input.motion_kg, now);
            s_status_req = false;
            last_publish = now;
            s_ack = ACK_NONE;
        }

        // Keeps the idle loop from spinning when no channel is readable.
        vTaskDelay(1);
    }
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_ERROR_CHECK(esp_netif_init());

    cal_defaults();
    if (!cal_load()) {
        s_need_tare = true;
        ESP_LOGI(TAG, "no stored calibration; tare at boot with an empty bed");
    }

    const int dout[CELL_COUNT] = {
        CONFIG_BED_HX711_DOUT0, CONFIG_BED_HX711_DOUT1,
        CONFIG_BED_HX711_DOUT2, CONFIG_BED_HX711_DOUT3,
    };
    const int sck[CELL_COUNT] = {
        CONFIG_BED_HX711_SCK0, CONFIG_BED_HX711_SCK1,
        CONFIG_BED_HX711_SCK2, CONFIG_BED_HX711_SCK3,
    };
    for (int i = 0; i < CELL_COUNT; ++i) {
        memset(&s_cell[i], 0, sizeof(s_cell[i]));
        s_last_raw[i] = 0;
        s_fault[i] = CELL_FAULT_LIMIT;
        s_last_kg[i] = 0.0f;
        if (hx711_init(&s_cell[i], dout[i], sck[i]) == ESP_OK) {
            s_cell_ready[i] = true;
            s_fault[i] = 0;
        } else {
            s_cell_ready[i] = false;
            ESP_LOGE(TAG, "hx711 %d init failed (dout=%d sck=%d)", i, dout[i], sck[i]);
        }
    }

    module_data_config_t data_config = {
        .module_id = MODULE_ID,
        .module_instance = CONFIG_MODULE_INSTANCE,
        .token = CONFIG_MODULE_TOKEN,
        .port = CONFIG_MODULE_PORT,
    };
    module_data_service_set_package_reader(package_reader, NULL);

    const module_control_service_config_t control = {
        .module_id = MODULE_ID,
#if CONFIG_MODULE_TRANSPORT_BLE
        .transport_mode = "fixed_ble",
#else
        .transport_mode = "fixed_hotspot_lan",
#endif
        .package_transport = "data",
        .module_type = "module",
    };
    ESP_ERROR_CHECK(module_control_service_start(&control));
    ESP_ERROR_CHECK(module_data_service_start(&data_config, on_command, NULL));
#if CONFIG_MODULE_TRANSPORT_BLE
    ESP_ERROR_CHECK(module_data_service_start_ble(CONFIG_MODULE_BLE_NAME));
#else
    const module_data_wifi_config_t wifi = {
        .ssid = CONFIG_PI_HOTSPOT_SSID,
        .password = CONFIG_PI_HOTSPOT_PASSWORD,
        .max_retry = 10,
        .static_ip = CONFIG_PI_MODULE_STATIC_IP,
        .netmask = CONFIG_PI_MODULE_NETMASK,
        .gateway = CONFIG_PI_HOTSPOT_GATEWAY,
    };
    ESP_ERROR_CHECK(module_data_wifi_start(&wifi));
#endif

    s_data_ready = true;
    ESP_LOGI(TAG, "bed sensor ready: %d x %d mm, %d sps",
             CONFIG_BED_BED_WIDTH_MM, CONFIG_BED_BED_LENGTH_MM,
             CONFIG_BED_SAMPLE_RATE_SPS);
    xTaskCreate(bed_task, "bed_task", 4096, NULL, 6, NULL);
}
