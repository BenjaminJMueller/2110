/* Unit-Tests: SDP-Parser, Formatprüfung, RTP-Zeitstempel, Versatzschätzer. */
#include "st2110core.h"
#include "st_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FEHLER %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static char dir[512];
static int parse(const char *name, st_sdp_media *m, int max)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fehlt: %s\n", path); fails++; return -2; }
    char buf[8192];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = 0;
    fclose(f);
    char err[256];
    return st_sdp_parse(buf, m, max, err, sizeof err);
}

static void test_sdp(void)
{
    st_sdp_media m[4];
    char msg[512];
    CHECK(parse("video_1080p25.sdp", m, 4) == 1);
    CHECK(m[0].kind == ST_MEDIA_VIDEO);
    CHECK(strcmp(m[0].encoding, "raw") == 0);
    CHECK(m[0].payload_type == 96 && m[0].clock_rate == 90000 && m[0].port == 5004);
    CHECK(strcmp(m[0].dest_addr, "239.21.1.1") == 0 && m[0].ttl == 64);
    CHECK(strcmp(m[0].source_addr, "192.168.10.21") == 0);
    CHECK(m[0].width == 1920 && m[0].height == 1080 && m[0].depth == 10);
    CHECK(m[0].fps_num == 25 && m[0].fps_den == 1 && !m[0].interlaced);
    CHECK(strcmp(m[0].sampling, "YCbCr-4:2:2") == 0);
    CHECK(m[0].has_ptp_refclk && m[0].ptp_domain == 127);
    CHECK(strcmp(m[0].ptp_gmid, "08-00-11-FF-FE-21-E1-B0") == 0);
    CHECK(m[0].has_mediaclk && m[0].mediaclk_direct && m[0].mediaclk_offset == 0);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_OK);

    CHECK(parse("video_1080p50.sdp", m, 4) == 1);
    CHECK(m[0].fps_num == 50 && m[0].payload_type == 98 && m[0].ptp_domain == 0);
    CHECK(strcmp(m[0].mid, "primary") == 0);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_OK);

    CHECK(parse("audio_16ch_125us.sdp", m, 4) == 1);
    CHECK(m[0].kind == ST_MEDIA_AUDIO && m[0].channels == 16 && m[0].clock_rate == 48000);
    CHECK(fabs(m[0].ptime_ms - 0.125) < 1e-9);
    CHECK(strcmp(m[0].encoding, "L24") == 0);
    CHECK(strstr(m[0].channel_order, "SGRP") != NULL);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_OK);

    /* Sitzungsweite c=, ts-refclk */
    CHECK(parse("audio_8ch_1ms.sdp", m, 4) == 1);
    CHECK(strcmp(m[0].dest_addr, "239.21.1.3") == 0 && m[0].port == 5006 && m[0].channels == 8);
    CHECK(m[0].has_ptp_refclk && m[0].ptp_domain == 127);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_OK);

    CHECK(parse("video_1080i50.sdp", m, 4) == 1);
    CHECK(m[0].interlaced == 1);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_NO);
    CHECK(strstr(msg, "progressives Format") != NULL);

    CHECK(parse("video_rgb.sdp", m, 4) == 1);
    CHECK(m[0].fps_num == 30000 && m[0].fps_den == 1001);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_NO);
    CHECK(strstr(msg, "4:2:2") != NULL);

    CHECK(parse("video_jxsv.sdp", m, 4) == 1);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_NO);
    CHECK(strstr(msg, "JPEG XS") != NULL);

    CHECK(parse("dup_2022_7.sdp", m, 4) == 2);
    CHECK(m[0].dup_group && m[1].dup_group);
    CHECK(strcmp(m[1].dest_addr, "239.140.0.1") == 0 && strcmp(m[1].source_addr, "192.168.20.40") == 0);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_WARNING);

    CHECK(parse("anc.sdp", m, 4) == 1);
    CHECK(m[0].kind == ST_MEDIA_DATA);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_NO);

    CHECK(parse("invalid.sdp", m, 4) == -1);
    char err[128];
    CHECK(st_sdp_parse("", m, 4, err, sizeof err) == -1);

    /* Schreiben und wieder lesen */
    st_sdp_media w;
    memset(&w, 0, sizeof w);
    w.kind = ST_MEDIA_VIDEO; w.payload_type = 96; w.port = 5004; w.width = 1920; w.height = 1080;
    w.fps_num = 50; w.fps_den = 1; w.depth = 10; w.ptp_domain = 127; w.has_ptp_refclk = 1;
    strcpy(w.dest_addr, "239.1.2.3"); strcpy(w.source_addr, "10.1.1.1"); strcpy(w.ptp_gmid, "AA-BB-CC-FF-FE-DD-EE-FF");
    char out[4096];
    CHECK(st_sdp_write(&w, out, sizeof out) > 0);
    CHECK(st_sdp_parse(out, m, 4, err, sizeof err) == 1);
    CHECK(m[0].width == 1920 && m[0].fps_num == 50 && strcmp(m[0].source_addr, "10.1.1.1") == 0 && m[0].ptp_domain == 127);
    CHECK(st_check_media(&m[0], msg, sizeof msg) == ST_SUPPORT_OK);
    memset(&w, 0, sizeof w);
    w.kind = ST_MEDIA_AUDIO; w.port = 5006; w.channels = 16; w.clock_rate = 48000; w.ptime_ms = 0.125;
    strcpy(w.dest_addr, "239.1.2.4"); strcpy(w.encoding, "L24");
    CHECK(st_sdp_write(&w, out, sizeof out) > 0);
    CHECK(st_sdp_parse(out, m, 4, err, sizeof err) == 1);
    CHECK(m[0].channels == 16 && fabs(m[0].ptime_ms - 0.125) < 1e-9 && m[0].payload_type == 97);
}

static void test_clock(void)
{
    const uint64_t S = 1000000000ULL;
    /* 2026-11-06 ~ 1.7964e9 s seit 1970 (+37 s TAI) */
    uint64_t t = 1796600000ULL * S + 123456789ULL;
    for (int k = 0; k < 2; k++) {
        uint32_t rate = k ? 48000 : 90000;
        uint64_t ticks = st_ns_to_ticks(t, rate);
        uint32_t ts = (uint32_t)ticks;
        CHECK(st_rtp_unwrap(ts, rate, t) == ticks);
        CHECK(st_rtp_unwrap(ts, rate, t + 3600 * S) == ticks);     /* Referenz 1 h später */
        CHECK(st_rtp_unwrap(ts, rate, t - 3600 * S) == ticks);     /* Referenz 1 h früher */
        CHECK(st_rtp_unwrap(ts, rate, t + 37 * S) == ticks);       /* UTC/TAI-Verwechslung */
        uint64_t ns = st_ticks_to_ns(ticks, rate);
        CHECK(ns <= t && t - ns < S / rate + 1);
    }
    /* Über die 32-Bit-Grenze hinweg */
    uint64_t wrap_ticks = (1ULL << 32) * 37000ULL; /* exakt auf einer Umlaufgrenze */
    uint64_t wrap_ns = st_ticks_to_ns(wrap_ticks, 90000);
    CHECK(st_rtp_unwrap(0xFFFFFFF0u, 90000, wrap_ns) == wrap_ticks - 16);
    CHECK(st_rtp_unwrap(0x00000010u, 90000, wrap_ns) == wrap_ticks + 16);
    /* Video und Audio derselben Aufnahmezeit ergeben dieselbe Zeit (±1 Tick) */
    uint64_t cap = t;
    uint64_t v = st_ticks_to_ns(st_rtp_unwrap((uint32_t)st_ns_to_ticks(cap, 90000), 90000, cap + 5 * S), 90000);
    uint64_t a = st_ticks_to_ns(st_rtp_unwrap((uint32_t)st_ns_to_ticks(cap, 48000), 48000, cap + 5 * S), 48000);
    CHECK(llabs((long long)v - (long long)a) < 25000); /* < 25 µs */
}

static void test_tracker(void)
{
    st_offset_tracker t;
    st_offset_init(&t);
    const int64_t MS = 1000000;
    uint64_t now = 0;
    CHECK(st_offset_update(&t, 1000 * MS, now) == 1);
    CHECK(t.offset == 1000 * MS);
    /* Jitter nach oben ändert nichts */
    for (int i = 0; i < 100; i++) { now += 10 * MS; st_offset_update(&t, 1000 * MS + (i % 5) * MS, now); }
    CHECK(llabs(t.offset - 1000 * MS) <= 1);
    /* Langsame Drift: +20 ppm über 60 s wird nachgeführt */
    int64_t base = 1000 * MS;
    for (int i = 0; i < 6000; i++) {
        now += 10 * MS;
        int64_t drift = (int64_t)((double)now * 20e-6);
        st_offset_update(&t, base + drift, now);
    }
    int64_t expect = base + (int64_t)((double)now * 20e-6);
    CHECK(llabs(t.offset - expect) < 2 * MS);
    CHECK(t.drift_ppm > 10 && t.drift_ppm < 30);
    uint64_t rs = t.resyncs;
    /* Sprung nach vorne (Pakete kommen 500 ms früher): sofort */
    now += 10 * MS;
    CHECK(st_offset_update(&t, expect - 500 * MS, now) == 1);
    CHECK(t.resyncs == rs + 1 && t.offset == expect - 500 * MS);
    /* Dauerhaft spätere Ankunft: nach einem Fenster neu ausrichten */
    int64_t later = expect + 200 * MS;
    int snapped = 0;
    for (int i = 0; i < 300; i++) { now += 10 * MS; snapped |= st_offset_update(&t, later, now); }
    CHECK(snapped && llabs(t.offset - later) < MS);
}

int main(int argc, char **argv)
{
    snprintf(dir, sizeof dir, "%s", argc > 1 ? argv[1] : "tests/sdp");
    test_sdp();
    test_clock();
    test_tracker();
    printf("%d Prüfungen, %d Fehler\n", checks, fails);
    return fails ? 1 : 0;
}
