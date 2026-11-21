#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#define XT_POGO_MODULE_ID 0x51u
typedef struct { bool ready, wired; uint32_t rx_frames; } xt_pogo_status_t;
esp_err_t xt_pogo_start(void);
xt_pogo_status_t xt_pogo_snapshot(void);
