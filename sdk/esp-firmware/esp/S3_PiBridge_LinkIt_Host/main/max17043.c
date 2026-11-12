/* MAX17043 fuel gauge for the S3 control bridge.
 *
 * The bridge previously only reserved GPIO8/9 for this part and never started
 * an I2C bus. The gauge now feeds the PBR1 battery telemetry so the Pi can show
 * real pack voltage and state of charge instead of "power unknown".
 *
 * Register map (datasheet):
 *   0x02 VCELL  12-bit, 1.25 mV/LSB in the upper 12 bits
 *   0x04 SOC    upper byte is the integer percentage
 *   0x06 MODE   writing 0x4000 triggers a quick start (re-estimate SOC)
 */
#include "max17043.h"

#include <math.h>
#include <stdio.h>

#include "bridge_pins.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define GAUGE_ADDR7        0x36
#define REG_VCELL          0x02
#define REG_SOC            0x04
#define REG_MODE           0x06
#define MODE_QUICK_START   0x4000
#define GAUGE_TIMEOUT_MS   50
#define GAUGE_INTERVAL_MS  1000

static const char *TAG = "MAX17043";

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_dev;
static SemaphoreHandle_t s_lock;
static max17043_sample_t s_latest;

static bool gauge_read(uint8_t reg, uint16_t *out)
{
    if (!s_dev) return false;
    const uint8_t tx[1] = {reg};
    uint8_t rx[2] = {0};
    if (i2c_master_transmit_receive(s_dev, tx, sizeof(tx), rx, sizeof(rx),
                                    GAUGE_TIMEOUT_MS) != ESP_OK)
        return false;
    *out = (uint16_t)(((uint16_t)rx[0] << 8) | rx[1]);
    return true;
}

static bool gauge_write(uint8_t reg, uint16_t value)
{
    if (!s_dev) return false;
    const uint8_t tx[3] = {reg, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF)};
    return i2c_master_transmit(s_dev, tx, sizeof(tx), GAUGE_TIMEOUT_MS) == ESP_OK;
}

/* Returns true only for a plausible cell reading. */
static bool read_gauge(max17043_sample_t *out)
{
    uint16_t vcell = 0;
    if (!gauge_read(REG_VCELL, &vcell)) return false;
    const float volts = (float)((vcell >> 4) * 125u) / 100000.0f;
    /* No cell fitted, or the gauge is only parasitically powered through the
     * I2C pull-ups. Both read near 0 V and mean "no battery", not "0 %". */
    if (!isfinite(volts) || volts < 2.0f) return false;

    uint16_t soc = 0;
    if (!gauge_read(REG_SOC, &soc)) return false;
    int percent = (int)(soc >> 8);
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    if (volts > 4.5f) return false;

    out->valid = true;
    out->volts = volts;
    out->percent = percent;
    out->sample_time_us = esp_timer_get_time();
    return true;
}

static void gauge_task(void *arg)
{
    (void)arg;
    bool logged_absent = false;
    for (;;) {
        max17043_sample_t sample = {0};
        const bool ok = read_gauge(&sample);

        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (ok) {
            s_latest = sample;
        } else {
            /* Keep the timestamp fresh but flag the value invalid: consumers
             * must see "unknown", never a stale voltage. */
            s_latest.valid = false;
            s_latest.sample_time_us = esp_timer_get_time();
        }
        xSemaphoreGive(s_lock);

        if (ok) {
            if (logged_absent || s_latest.percent == 0) {
                ESP_LOGI(TAG, "gauge online: %.2f V / %d%%", sample.volts, sample.percent);
            }
            logged_absent = false;
        } else if (!logged_absent) {
            ESP_LOGW(TAG, "MAX17043 not responding on SDA=GPIO%d SCL=GPIO%d",
                     BRIDGE_MAX17043_SDA_GPIO, BRIDGE_MAX17043_SCL_GPIO);
            logged_absent = true;
        }
        vTaskDelay(pdMS_TO_TICKS(GAUGE_INTERVAL_MS));
    }
}

esp_err_t max17043_start(void)
{
    if (s_lock) return ESP_ERR_INVALID_STATE;
    s_lock = xSemaphoreCreateMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;

    const i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = BRIDGE_MAX17043_SDA_GPIO,
        .scl_io_num = BRIDGE_MAX17043_SCL_GPIO,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    esp_err_t err = i2c_new_master_bus(&bus_config, &s_bus);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus init failed: %s", esp_err_to_name(err));
        vSemaphoreDelete(s_lock); s_lock = NULL;
        return err;
    }

    const i2c_device_config_t device_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = GAUGE_ADDR7,
        .scl_speed_hz = 100000,
    };
    err = i2c_master_bus_add_device(s_bus, &device_config, &s_dev);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "gauge device add failed: %s", esp_err_to_name(err));
        i2c_del_master_bus(s_bus); s_bus = NULL;
        vSemaphoreDelete(s_lock); s_lock = NULL;
        return err;
    }

    /* Absent hardware is expected until the pack is fitted; never abort boot. */
    if (gauge_write(REG_MODE, MODE_QUICK_START))
        ESP_LOGI(TAG, "quick start issued on SDA=GPIO%d SCL=GPIO%d",
                 BRIDGE_MAX17043_SDA_GPIO, BRIDGE_MAX17043_SCL_GPIO);
    else
        ESP_LOGW(TAG, "gauge not answering yet; will keep probing");

    if (xTaskCreate(gauge_task, "max17043", 3072, NULL, 3, NULL) != pdPASS) {
        ESP_LOGE(TAG, "sampling task allocation failed");
        i2c_master_bus_rm_device(s_dev); s_dev = NULL;
        i2c_del_master_bus(s_bus); s_bus = NULL;
        vSemaphoreDelete(s_lock); s_lock = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

bool max17043_latest(max17043_sample_t *out)
{
    if (!out || !s_lock) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_latest;
    xSemaphoreGive(s_lock);
    return true;
}

const char *max17043_json(char *buffer, size_t capacity)
{
    if (!buffer || capacity < 48) return NULL;
    max17043_sample_t sample = {0};
    if (!max17043_latest(&sample)) {
        snprintf(buffer, capacity, "{\"valid\":false}");
        return buffer;
    }
    if (!sample.valid) {
        /* No invented percentage and no stale voltage. */
        snprintf(buffer, capacity, "{\"valid\":false}");
        return buffer;
    }
    snprintf(buffer, capacity,
             "{\"valid\":true,\"volts\":%.2f,\"percent\":%d,\"source\":\"%s\"}",
             sample.volts, sample.percent,
             sample.volts < 3.40f ? "battery_low" : "battery");
    return buffer;
}
