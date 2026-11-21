#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "driver/gpio.h"

typedef struct {
    gpio_num_t dout;
    gpio_num_t sck;
    int32_t raw;
    bool ready;
} hx711_t;

// Bit-banged HX711 reader. Channel A, gain 128, 25 clock pulses per sample.
esp_err_t hx711_init(hx711_t *dev, int dout_gpio, int sck_gpio);

// Waits for DOUT to go low, then shifts out one signed 24-bit sample.
esp_err_t hx711_read(hx711_t *dev, int32_t *raw, uint32_t timeout_ms);
