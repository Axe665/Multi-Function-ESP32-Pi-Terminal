#include "bed_logic.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static bed_logic_config_t test_config(void) {
    const bed_logic_config_t config = {
        .present_kg = 8.0f,
        .absent_kg = 4.0f,
        .enter_ms = 800,
        .exit_ms = 1500,
        .turn_cm = 6.0f,
        .sit_cm = 15.0f,
        .shift_hold_ms = 600,
        .edge_margin_cm = 20.0f,
        .edge_ms = 1000,
        .no_return_ms = 2000,
        .bed_w_cm = 150.0f,
        .bed_l_cm = 200.0f,
    };
    return config;
}

static uint32_t step(bed_logic_t *logic, const bed_logic_config_t *config, uint32_t *now,
                     float weight, float x, float y, bool valid) {
    const bed_logic_input_t input = {
        .weight_kg = weight,
        .x_cm = x,
        .y_cm = y,
        .motion_kg = 0.0f,
        .valid = valid,
    };
    const uint32_t events = bed_logic_update(logic, config, &input, *now);
    *now += 100;
    return events;
}

int main(void) {
    const bed_logic_config_t config = test_config();
    bed_logic_t logic;
    bed_logic_reset(&logic);
    uint32_t now = 0;
    uint32_t events = 0;

    // Empty bed: stays out.
    for (int i = 0; i < 5; ++i) events |= step(&logic, &config, &now, 0.0f, 0, 0, true);
    assert(logic.state == BED_STATE_OUT);
    assert(!logic.present);

    // Enter debounce: 0.5 s must not enter, 1.2 s must.
    for (int i = 0; i < 5; ++i) events |= step(&logic, &config, &now, 60.0f, 75.0f, 100.0f, true);
    assert(logic.state == BED_STATE_OUT);
    for (int i = 0; i < 8; ++i) events |= step(&logic, &config, &now, 60.0f, 75.0f, 100.0f, true);
    assert(logic.state == BED_STATE_IN);
    assert(logic.present);
    assert(events & (1u << BED_EVT_ENTER));

    // Lateral CoM shift held for 0.7 s is a turn.
    events = 0;
    for (int i = 0; i < 9; ++i) events |= step(&logic, &config, &now, 60.0f, 96.0f, 100.0f, true);
    assert(events & (1u << BED_EVT_TURN));

    // Head-foot shift is reported as sitting up.
    events = 0;
    for (int i = 0; i < 9; ++i) events |= step(&logic, &config, &now, 60.0f, 96.0f, 123.0f, true);
    assert(events & (1u << BED_EVT_SIT));

    // Near the side edge for more than 1 s.
    events = 0;
    for (int i = 0; i < 13; ++i) events |= step(&logic, &config, &now, 60.0f, 140.0f, 123.0f, true);
    assert(events & (1u << BED_EVT_EDGE));
    assert(logic.state == BED_STATE_EDGE);

    // Invalid samples do not move the state machine.
    for (int i = 0; i < 5; ++i) events |= step(&logic, &config, &now, 0.0f, 0.0f, 0.0f, false);
    assert(logic.state == BED_STATE_EDGE);

    // Exit debounce.
    events = 0;
    for (int i = 0; i < 18; ++i) events |= step(&logic, &config, &now, 0.0f, 0.0f, 0.0f, true);
    assert(logic.state == BED_STATE_OUT);
    assert(!logic.present);
    assert(events & (1u << BED_EVT_EXIT));

    // No-return after the configured 2 s out of bed.
    events = 0;
    for (int i = 0; i < 25; ++i) events |= step(&logic, &config, &now, 0.0f, 0.0f, 0.0f, true);
    assert(events & (1u << BED_EVT_NO_RETURN));

    // Coming back clears the leave timer.
    events = 0;
    for (int i = 0; i < 12; ++i) events |= step(&logic, &config, &now, 60.0f, 75.0f, 100.0f, true);
    assert(logic.state == BED_STATE_IN);
    assert(events & (1u << BED_EVT_ENTER));
    assert(logic.leave_ms == 0);

    printf("bed_logic_test: ok\n");
    return 0;
}
