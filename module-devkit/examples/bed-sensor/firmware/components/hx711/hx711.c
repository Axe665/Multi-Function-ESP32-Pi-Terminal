#include "hx711.h"

#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

esp_err_t hx711_init(hx711_t *dev, int dout_gpio, int sck_gpio) {
    if (!dev || dout_gpio < 0 || sck_gpio < 0) return ESP_ERR_INVALID_ARG;

    gpio_config_t io = {0};
    io.pin_bit_mask = 1ULL << (unsigned)dout_gpio;
    io.mode = GPIO_MODE_INPUT;
    io.pull_up_en = GPIO_PULLUP_ENABLE;
    io.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io.intr_type = GPIO_INTR_DISABLE;
    esp_err_t err = gpio_config(&io);
    if (err != ESP_OK) return err;

    io.pin_bit_mask = 1ULL << (unsigned)sck_gpio;
    io.mode = GPIO_MODE_OUTPUT;
    io.pull_up_en = GPIO_PULLUP_DISABLE;
    err = gpio_config(&io);
    if (err != ESP_OK) return err;
    gpio_set_level((gpio_num_t)sck_gpio, 0);

    dev->dout = (gpio_num_t)dout_gpio;
    dev->sck = (gpio_num_t)sck_gpio;
    dev->raw = 0;
    dev->ready = false;
    return ESP_OK;
}

esp_err_t hx711_read(hx711_t *dev, int32_t *raw, uint32_t timeout_ms) {
    if (!dev || !raw) return ESP_ERR_INVALID_ARG;

    const int64_t deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    while (gpio_get_level(dev->dout)) {
        if (esp_timer_get_time() >= deadline_us) return ESP_ERR_TIMEOUT;
        vTaskDelay(1);
    }

    uint32_t value = 0;
    for (int i = 0; i < 24; ++i) {
        gpio_set_level(dev->sck, 1);
        esp_rom_delay_us(1);
        value = (value << 1) | (uint32_t)gpio_get_level(dev->dout);
        gpio_set_level(dev->sck, 0);
        esp_rom_delay_us(1);
    }

    // 25th pulse: channel A, gain 128.
    gpio_set_level(dev->sck, 1);
    esp_rom_delay_us(1);
    gpio_set_level(dev->sck, 0);
    esp_rom_delay_us(1);

    if (value & 0x800000u) value |= 0xFF000000u;
    dev->raw = (int32_t)value;
    dev->ready = true;
    *raw = dev->raw;
    return ESP_OK;
}
