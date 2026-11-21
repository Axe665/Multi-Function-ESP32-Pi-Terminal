#include <inttypes.h>
#include <stdio.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define INPUT_GPIO GPIO_NUM_4
#define STABLE_US INT64_C(20000)
#define HEARTBEAT_US INT64_C(1000000)

static void report(const char *event, int raw, int stable, uint32_t changes)
{
    printf("{\"app\":\"xiaotian_io4_probe\",\"version\":\"1.0\","
           "\"event\":\"%s\",\"uptime_ms\":%" PRId64 ","
           "\"gpio\":4,\"raw\":%d,\"stable\":%d,\"level\":\"%s\","
           "\"changes\":%" PRIu32 "}\n",
           event, esp_timer_get_time() / 1000, raw, stable,
           stable < 0 ? "WAIT" : (stable ? "HIGH" : "LOW"), changes);
    fflush(stdout);
}

void app_main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const gpio_config_t input = {
        .pin_bit_mask = 1ULL << INPUT_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&input));

    // Allow supply/startup transients to settle; initial state is not a crossing.
    vTaskDelay(pdMS_TO_TICKS(1000));
    int candidate = gpio_get_level(INPUT_GPIO);
    int stable = -1;
    uint32_t changes = 0;
    int64_t candidate_since = esp_timer_get_time();
    int64_t last_report = candidate_since;
    report("BOOT", candidate, stable, changes);

    for (;;) {
        const int raw = gpio_get_level(INPUT_GPIO);
        const int64_t now = esp_timer_get_time();
        if (raw != candidate) {
            candidate = raw;
            candidate_since = now;
        }
        if (candidate != stable && now - candidate_since >= STABLE_US) {
            const int initial = stable < 0;
            stable = candidate;
            if (!initial) {
                ++changes;
            }
            report(initial ? "INITIAL" : "CHANGE", raw, stable, changes);
            last_report = now;
        } else if (now - last_report >= HEARTBEAT_US) {
            report("STATUS", raw, stable, changes);
            last_report = now;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
