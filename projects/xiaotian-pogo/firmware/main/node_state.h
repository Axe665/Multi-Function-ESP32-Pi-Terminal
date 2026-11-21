#pragma once
#include <stdbool.h>
#include <stdint.h>
#define XT_EVENT_CAPACITY 64
#define XT_LEASE_MS 5000
typedef struct {
    uint32_t seq;
    int64_t uptime_ms;
    int stable;
    uint32_t changes;
    uint32_t record_epoch;
    char event[12];
} xt_event_t;
typedef struct {
    bool enabled;
    int stable, candidate;
    int64_t candidate_since_us;
    uint32_t changes, seq, revision, record_epoch;
    int64_t lease_until_ms;
    char owner[65], session[65];
    xt_event_t events[XT_EVENT_CAPACITY];
    unsigned count, next;
} xt_state_t;
void xt_init(xt_state_t *s);
void xt_enable(xt_state_t *s, int64_t now_us);
void xt_disable(xt_state_t *s);
void xt_tick(xt_state_t *s, int64_t now_ms);
bool xt_sample(xt_state_t *s, int raw, int64_t now_us);
bool xt_record_start(xt_state_t *s, const char *owner, const char *session, int64_t now_ms);
bool xt_record_keepalive(xt_state_t *s, const char *owner, const char *session, int64_t now_ms);
void xt_record_stop(xt_state_t *s);
const xt_event_t *xt_event_at(const xt_state_t *s, unsigned index);
