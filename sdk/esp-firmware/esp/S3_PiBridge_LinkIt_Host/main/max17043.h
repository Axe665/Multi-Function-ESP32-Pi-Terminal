#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/* MAX17043 single-cell fuel gauge on the bridge board.
 *
 * Wiring (see bridge_pins.h): SDA = GPIO8, SCL = GPIO9, ALRT = GPIO7 (unused).
 * The gauge is powered from the cell itself, so a missing cell reads ~0 V and
 * must be reported as "no battery" rather than 0 %.
 */
typedef struct {
    bool valid;
    float volts;
    int percent;
    int64_t sample_time_us;
} max17043_sample_t;

/* Starts the I2C bus and the 1 Hz sampling task.
 *
 * An absent or miswired gauge is recoverable: the task keeps probing and
 * publishes valid=false. Only a failure to create the I2C bus or the task is
 * returned as an error.
 */
esp_err_t max17043_start(void);

/* Copies the latest sample. Returns false only when the sampler never ran. */
bool max17043_latest(max17043_sample_t *out);

/* Most recent reading as a compact JSON fragment for PBR1 diagnostics. */
const char *max17043_json(char *buffer, size_t capacity);
