#pragma once

#include <stdbool.h>
#include <stdint.h>

// Pure logic: no ESP-IDF dependencies, so it can be exercised on the host.
// Coordinates are centimetres with the origin at the head-left bed corner.
// Channel order is fixed: 0 head-left, 1 head-right, 2 foot-left, 3 foot-right.

typedef enum {
    BED_STATE_OUT = 0,
    BED_STATE_IN,
    BED_STATE_EDGE,
} bed_state_t;

typedef enum {
    BED_EVT_NONE = 0,
    BED_EVT_ENTER,
    BED_EVT_EXIT,
    BED_EVT_TURN,
    BED_EVT_SIT,
    BED_EVT_EDGE,
    BED_EVT_NO_RETURN,
} bed_event_t;

typedef struct {
    float present_kg;      // weight that starts an enter debounce
    float absent_kg;       // weight that starts an exit debounce
    uint32_t enter_ms;
    uint32_t exit_ms;
    float turn_cm;         // CoM jump that counts as a posture change
    float sit_cm;          // head-foot shift that is reported as sitting up
    uint32_t shift_hold_ms;
    float edge_margin_cm;  // distance to any bed edge that counts as "edge"
    uint32_t edge_ms;
    uint32_t no_return_ms; // 0 disables the event
    float bed_w_cm;
    float bed_l_cm;
} bed_logic_config_t;

typedef struct {
    float weight_kg;
    float x_cm;
    float y_cm;
    float motion_kg;
    bool valid;
} bed_logic_input_t;

typedef struct {
    bed_state_t state;
    bool present;
    float weight_kg;
    float x_cm;
    float y_cm;
    float motion_kg;
    uint32_t in_bed_ms;
    uint32_t leave_ms;
    uint32_t last_event_mask;
    // internal timing state
    uint32_t in_bed_since;
    uint32_t leave_since;
    uint32_t enter_since;
    uint32_t exit_since;
    uint32_t shift_since;
    uint32_t edge_since;
    bool enter_pending;
    bool exit_pending;
    bool shift_pending;
    bool edge_pending;
    bool edge_active;
    bool ref_valid;
    bool no_return_fired;
    float ref_x;
    float ref_y;
} bed_logic_t;

void bed_logic_reset(bed_logic_t *logic);

// Returns a bitmask of BED_EVT_* events produced by this update.
// now_ms must be monotonic; tests can drive it directly.
uint32_t bed_logic_update(bed_logic_t *logic, const bed_logic_config_t *config,
                          const bed_logic_input_t *input, uint32_t now_ms);

const char *bed_event_name(bed_event_t event);
const char *bed_state_name(bed_state_t state);
