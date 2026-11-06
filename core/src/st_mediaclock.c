/*
 * Abbildung von RTP-Zeitstempeln auf den gemeinsamen Zeitbezug.
 *
 * ST 2110-10 / ST 2059-1: RTP-Zeitstempel = floor(PTP-Zeit * Taktrate) mod 2^32,
 * gemessen ab der SMPTE-Epoche (1970-01-01 TAI). Video (90 kHz) und Audio
 * (48 kHz) desselben Senders tragen daher Zeitstempel, die sich auf dieselbe
 * Uhr beziehen. Aus beiden lässt sich die Aufnahmezeit zurückrechnen, sofern
 * ein Referenzzeitpunkt bekannt ist, der näher als eine halbe Umlaufperiode
 * (Video: 2^32/90000 s ≈ 13,2 h; Audio: 2^32/48000 s ≈ 24,8 h) liegt.
 */
#include "st2110core.h"
#include "st_internal.h"

#define NS_PER_S 1000000000ULL

uint64_t st_ns_to_ticks(uint64_t ns, uint32_t rate)
{
    return (ns / NS_PER_S) * rate + ((ns % NS_PER_S) * rate) / NS_PER_S;
}

uint64_t st_ticks_to_ns(uint64_t ticks, uint32_t rate)
{
    if (rate == 0) return 0;
    return (ticks / rate) * NS_PER_S + ((ticks % rate) * NS_PER_S) / rate;
}

uint64_t st_rtp_unwrap(uint32_t ts, uint32_t rate, uint64_t ref_ns)
{
    const uint64_t wrap = 1ULL << 32;
    uint64_t ref = st_ns_to_ticks(ref_ns, rate);
    uint64_t cand = (ref & ~(wrap - 1)) | ts;
    /* Kandidaten cand - wrap, cand, cand + wrap: nächstliegenden wählen */
    if (cand > ref && cand - ref > wrap / 2 && cand >= wrap) cand -= wrap;
    else if (cand < ref && ref - cand > wrap / 2) cand += wrap;
    return cand;
}

/* ------------------------------------------------------------------ */

void st_offset_init(st_offset_tracker *t)
{
    t->have = 0;
    t->offset = 0;
    t->have_win = 0;
    t->win_min = 0;
    t->win_start = 0;
    t->window_ns = 2 * NS_PER_S;
    t->snap_threshold = 25 * 1000000LL;  /* 25 ms */
    t->max_slew = 200 * 1000LL;          /* 0,2 ms je 2 s = 100 ppm */
    t->resyncs = 0;
    t->drift_ppm = 0;
    t->last_target = 0;
    t->last_target_time = 0;
    t->late_since = 0;
    t->late_min = 0;
    t->drift_base = 0;
    t->drift_base_time = 0;
}

static int64_t llabs64(int64_t v) { return v < 0 ? -v : v; }

int st_offset_update(st_offset_tracker *t, int64_t delta, uint64_t now)
{
    if (!t->have) {
        t->have = 1;
        t->offset = delta;
        t->win_min = delta;
        t->have_win = 1;
        t->win_start = now;
        t->last_target = delta;
        t->last_target_time = now;
        return 1;
    }
    /* Deutlich frühere Ankunft als erwartet: Zeitbezug hat sich verschoben
     * (z. B. Senderneustart, PTP-Sprung). Sofort übernehmen. */
    if (delta < t->offset - t->snap_threshold) {
        t->offset = delta;
        t->win_min = delta;
        t->win_start = now;
        t->resyncs++;
        t->last_target = delta;
        t->last_target_time = now;
        t->drift_base_time = 0;
        return 1;
    }
    /* Dauerhaft deutlich spätere Ankunft (z. B. Sender-Zeitbezug sprang
     * zurück): nach 300 ms neu ausrichten, statt Bilder als verspätet zu verwerfen. */
    if (delta > t->offset + t->snap_threshold) {
        if (!t->late_since) {
            t->late_since = now ? now : 1;
            t->late_min = delta;
        } else if (delta < t->late_min) {
            t->late_min = delta;
        }
        if (now - t->late_since >= 300000000ULL) {
            t->offset = t->late_min;
            t->win_min = t->late_min;
            t->have_win = 1;
            t->win_start = now;
            t->late_since = 0;
            t->resyncs++;
            t->last_target = t->offset;
            t->last_target_time = now;
            t->drift_base_time = 0;
            return 1;
        }
    } else {
        t->late_since = 0;
    }
    if (!t->have_win || delta < t->win_min) {
        t->win_min = delta;
        t->have_win = 1;
    }
    if (now - t->win_start >= t->window_ns) {
        int64_t target = t->win_min;
        int64_t diff = target - t->offset;
        int snapped = 0;
        if (llabs64(diff) > t->snap_threshold) {
            /* Pakete kommen dauerhaft später: neu ausrichten */
            t->offset = target;
            t->resyncs++;
            snapped = 1;
        } else {
            if (diff > t->max_slew) diff = t->max_slew;
            if (diff < -t->max_slew) diff = -t->max_slew;
            t->offset += diff;
        }
        /* Drift über lange Basis (mind. 20 s) schätzen; Sprünge setzen sie zurück. */
        if (snapped || t->drift_base_time == 0) {
            t->drift_base = target;
            t->drift_base_time = now ? now : 1;
            t->drift_ppm = 0;
        } else if (now - t->drift_base_time >= 20000000000ULL) {
            t->drift_ppm = (double)(target - t->drift_base) / (double)(now - t->drift_base_time) * 1e6;
        }
        t->last_target = target;
        t->last_target_time = now;
        t->win_start = now;
        t->have_win = 0;
        return snapped;
    }
    return 0;
}
