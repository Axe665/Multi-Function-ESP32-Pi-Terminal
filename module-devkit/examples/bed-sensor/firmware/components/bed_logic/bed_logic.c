#include "bed_logic.h"

#include <math.h>
#include <string.h>

static uint32_t event_bit(bed_event_t event) {
    return 1u << (unsigned)event;
}

void bed_logic_reset(bed_logic_t *logic) {
    if (!logic) return;
    memset(logic, 0, sizeof(*logic));
    logic->state = BED_STATE_OUT;
}

uint32_t bed_logic_update(bed_logic_t *logic, const bed_logic_config_t *config,
                          const bed_logic_input_t *input, uint32_t now_ms) {
    if (!logic || !config || !input) return 0;

    uint32_t events = 0;
    const float weight = input->weight_kg;

    if (logic->state == BED_STATE_OUT) {
        logic->leave_ms = logic->leave_since ? (now_ms - logic->leave_since) : 0;
    }

    if (!input->valid) {
        logic->last_event_mask = 0;
        return 0;
    }

    logic->weight_kg = weight;
    logic->motion_kg = input->motion_kg;
    if (weight >= 0.5f) {
        logic->x_cm = input->x_cm;
        logic->y_cm = input->y_cm;
    }

    if (logic->state == BED_STATE_OUT) {
        if (weight >= config->present_kg) {
            if (!logic->enter_pending) {
                logic->enter_pending = true;
                logic->enter_since = now_ms;
            }
            if (now_ms - logic->enter_since >= config->enter_ms) {
                logic->state = BED_STATE_IN;
                logic->present = true;
                logic->enter_pending = false;
                logic->in_bed_since = now_ms;
                logic->in_bed_ms = 0;
                logic->leave_since = 0;
                logic->leave_ms = 0;
                logic->ref_x = input->x_cm;
                logic->ref_y = input->y_cm;
                logic->ref_valid = true;
                logic->edge_active = false;
                logic->edge_pending = false;
                logic->no_return_fired = false;
                events |= event_bit(BED_EVT_ENTER);
            }
        } else {
            logic->enter_pending = false;
        }

        if (logic->leave_since && config->no_return_ms &&
            now_ms - logic->leave_since >= config->no_return_ms &&
            !logic->no_return_fired) {
            logic->no_return_fired = true;
            events |= event_bit(BED_EVT_NO_RETURN);
        }
    } else {
        logic->in_bed_ms = now_ms - logic->in_bed_since;

        if (weight <= config->absent_kg) {
            if (!logic->exit_pending) {
                logic->exit_pending = true;
                logic->exit_since = now_ms;
            }
            if (now_ms - logic->exit_since >= config->exit_ms) {
                logic->state = BED_STATE_OUT;
                logic->present = false;
                logic->exit_pending = false;
                logic->leave_since = now_ms;
                logic->leave_ms = 0;
                logic->in_bed_ms = 0;
                logic->ref_valid = false;
                logic->shift_pending = false;
                logic->edge_pending = false;
                logic->edge_active = false;
                events |= event_bit(BED_EVT_EXIT);
            }
        } else {
            logic->exit_pending = false;

            if (!logic->ref_valid) {
                logic->ref_x = input->x_cm;
                logic->ref_y = input->y_cm;
                logic->ref_valid = true;
            }

            const float dx = input->x_cm - logic->ref_x;
            const float dy = input->y_cm - logic->ref_y;
            const bool shifted = fabsf(dx) >= config->turn_cm || fabsf(dy) >= config->turn_cm;

            if (shifted) {
                if (!logic->shift_pending) {
                    logic->shift_pending = true;
                    logic->shift_since = now_ms;
                }
                if (now_ms - logic->shift_since >= config->shift_hold_ms) {
                    if (fabsf(dy) >= config->sit_cm && fabsf(dx) < config->turn_cm)
                        events |= event_bit(BED_EVT_SIT);
                    else
                        events |= event_bit(BED_EVT_TURN);
                    logic->ref_x = input->x_cm;
                    logic->ref_y = input->y_cm;
                    logic->shift_pending = false;
                }
            } else {
                logic->shift_pending = false;
                // Follow very slow drift (zero shift, creep) without hiding real turns.
                logic->ref_x += dx * 0.0002f;
                logic->ref_y += dy * 0.0002f;
            }

            const bool in_edge =
                input->x_cm < config->edge_margin_cm ||
                input->x_cm > config->bed_w_cm - config->edge_margin_cm ||
                input->y_cm < config->edge_margin_cm ||
                input->y_cm > config->bed_l_cm - config->edge_margin_cm;

            if (in_edge) {
                if (!logic->edge_pending) {
                    logic->edge_pending = true;
                    logic->edge_since = now_ms;
                }
                if (now_ms - logic->edge_since >= config->edge_ms) {
                    if (!logic->edge_active) {
                        logic->edge_active = true;
                        events |= event_bit(BED_EVT_EDGE);
                    }
                    logic->state = BED_STATE_EDGE;
                }
            } else {
                logic->edge_pending = false;
                logic->edge_active = false;
                logic->state = BED_STATE_IN;
            }
        }
    }

    logic->present = (logic->state != BED_STATE_OUT);
    logic->last_event_mask = events;
    return events;
}

const char *bed_event_name(bed_event_t event) {
    switch (event) {
    case BED_EVT_ENTER: return "enter";
    case BED_EVT_EXIT: return "exit";
    case BED_EVT_TURN: return "turn";
    case BED_EVT_SIT: return "sit";
    case BED_EVT_EDGE: return "edge";
    case BED_EVT_NO_RETURN: return "no_return";
    default: return "none";
    }
}

const char *bed_state_name(bed_state_t state) {
    switch (state) {
    case BED_STATE_IN: return "in";
    case BED_STATE_EDGE: return "edge";
    default: return "out";
    }
}
