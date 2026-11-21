#include "node_state.h"
#include <string.h>
#include <stdio.h>

void xt_init(xt_state_t *s) { memset(s, 0, sizeof(*s)); s->stable = s->candidate = -1; }
void xt_record_stop(xt_state_t *s) {
    s->owner[0] = s->session[0] = 0;
    s->lease_until_ms = 0;
    s->count = s->next = 0;
    memset(s->events, 0, sizeof(s->events));
}
void xt_tick(xt_state_t *s, int64_t now_ms) {
    if (s->session[0] && now_ms >= s->lease_until_ms) xt_record_stop(s);
}
void xt_enable(xt_state_t *s, int64_t now_us) {
    if (s->enabled) return;
    s->enabled = true;
    s->stable = s->candidate = -1;
    s->candidate_since_us = now_us;
    ++s->revision;
}
void xt_disable(xt_state_t *s) {
    if (s->enabled) ++s->revision;
    s->enabled = false;
    s->stable = s->candidate = -1;
    xt_record_stop(s);
}
bool xt_record_start(xt_state_t *s, const char *owner, const char *session, int64_t now_ms) {
    xt_tick(s, now_ms);
    if (!s->enabled || !owner || !session || !owner[0] || !session[0] ||
        strlen(owner) > 64 || strlen(session) > 64) return false;
    if (s->session[0]) return xt_record_keepalive(s, owner, session, now_ms);
    snprintf(s->owner, sizeof(s->owner), "%s", owner);
    snprintf(s->session, sizeof(s->session), "%s", session);
    ++s->record_epoch;
    s->count = s->next = 0;
    memset(s->events, 0, sizeof(s->events));
    s->lease_until_ms = now_ms + XT_LEASE_MS;
    return true;
}
bool xt_record_keepalive(xt_state_t *s, const char *owner, const char *session, int64_t now_ms) {
    xt_tick(s, now_ms);
    if (!s->enabled || !s->session[0] || !owner || !session ||
        strcmp(owner, s->owner) || strcmp(session, s->session)) return false;
    s->lease_until_ms = now_ms + XT_LEASE_MS;
    return true;
}
bool xt_sample(xt_state_t *s, int raw, int64_t now_us) {
    xt_tick(s, now_us / 1000);
    if (!s->enabled || (raw != 0 && raw != 1)) return false;
    if (raw != s->candidate) { s->candidate = raw; s->candidate_since_us = now_us; }
    if (s->stable == s->candidate || now_us - s->candidate_since_us < 20000) return false;
    bool initial = s->stable < 0;
    s->stable = raw;
    if (!initial) ++s->changes;
    ++s->seq;
    // Only retain bounded RAM events while an authorized recording lease exists.
    // Before login / after logout, live state remains but no event history is kept.
    if (s->session[0]) {
        xt_event_t *e = &s->events[s->next];
        *e = (xt_event_t){.seq=s->seq, .uptime_ms=now_us / 1000, .stable=raw,
                         .changes=s->changes, .record_epoch=s->record_epoch};
        snprintf(e->event, sizeof(e->event), "%s", initial ? "INITIAL" : "CHANGE");
        s->next = (s->next + 1) % XT_EVENT_CAPACITY;
        if (s->count < XT_EVENT_CAPACITY) ++s->count;
    }
    return true;
}
const xt_event_t *xt_event_at(const xt_state_t *s, unsigned index) {
    if (index >= s->count) return NULL;
    return &s->events[(s->next + XT_EVENT_CAPACITY - s->count + index) % XT_EVENT_CAPACITY];
}
