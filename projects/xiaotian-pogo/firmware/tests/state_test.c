#include "node_state.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    xt_state_t s;
    xt_init(&s);
    assert(!xt_sample(&s, 0, 1000000) && s.stable == -1 && !s.count);
    assert(!xt_record_start(&s, "pi", "a", 0));
    xt_enable(&s, 1000000);
    assert(!xt_sample(&s, 1, 1000000));
    assert(!xt_sample(&s, 1, 1019999));
    assert(xt_sample(&s, 1, 1020000) && s.changes == 0 && s.count == 0);
    assert(!xt_sample(&s, 0, 1030000));
    assert(!xt_sample(&s, 1, 1035000)); // brief low must not count
    assert(!xt_sample(&s, 1, 1055000));
    assert(xt_record_start(&s, "pi", "a", 1100));
    assert(!xt_record_start(&s, "other", "b", 1100));
    assert(!xt_record_keepalive(&s, "other", "a", 1101));
    assert(!xt_sample(&s, 0, 1120000));
    assert(xt_sample(&s, 0, 1140000));
    assert(s.changes == 1 && s.count == 1 && xt_event_at(&s,0)->stable == 0);
    xt_tick(&s, 6100);
    assert(s.enabled && !s.session[0] && !s.count && s.stable == 0);
    assert(!xt_record_keepalive(&s, "pi", "a", 6101)); // expired lease never revived
    assert(xt_record_start(&s, "pi", "b", 6200));
    assert(s.record_epoch == 2 && !s.count);
    for (unsigned i=0; i<70; ++i) {
        int64_t t=6300000 + i*22000;
        int raw=(i % 2) ? 0 : 1;
        assert(!xt_sample(&s,raw,t));
        assert(xt_sample(&s,raw,t+20000));
    }
    assert(s.count == 64 && xt_event_at(&s,0)->seq + 63 == s.seq);
    xt_disable(&s);
    assert(!s.enabled && s.stable == -1 && !s.session[0] && !s.count);
    uint32_t rev=s.revision;
    xt_disable(&s);
    assert(s.revision == rev);
    xt_enable(&s, 9000000);
    assert(s.enabled && !s.session[0]);
    xt_init(&s);
    assert(!s.enabled && !s.session[0]); // reboot requires explicit enable
    puts("PASS: standby/filter/initial/change/owner/lease/purge/ring/disable/re-enable/reboot");
    return 0;
}
