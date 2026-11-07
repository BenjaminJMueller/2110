/*
 * Analyse von ST-2110-Paketmitschnitten. Siehe st2110analyze.h.
 *
 * Messgrößen (Definitionen nach SMPTE ST 2110-21:2017 bzw. -30, eigene
 * Implementierung):
 *  - Verluste, Duplikate, Umsortierungen (RTP-Sequenznummern, bei Video mit ESN)
 *  - Paketabstand (IAT), Datenrate
 *  - Video: Bildrate aus RTP-Zeitstempeln, Bildgröße aus Zeilenköpfen,
 *    Pakete je Bild, Marker, Cinst (Network Compatibility Model, β = 1,1),
 *    VRX (Virtual Receiver Buffer, ausgerichtet am ersten Paket des Bildes),
 *    Abstand erstes Paket ↔ Bildzeit (RTP-Latenz/TRO)
 *  - Audio: Paketzeit, TS-DF (Timestamped Delay Factor, 1-s-Fenster)
 *  - Zusatzdaten (ST 2110-40): DID/SDID
 *  - PTP: Domains, Master, Grandmaster, Nachrichtenraten
 *  - IGMP: Querier, Joins/Leaves je Gruppe
 *
 * Grenzen: Die Zeitmessung ist nur so genau wie die Zeitstempel des
 * Mitschnitts. Softwaremitschnitte (tcpdump, Wireshark, 2110 Viewer) streuen um
 * Mikrosekunden bis Millisekunden; für eine belastbare Bewertung nach
 * ST 2110-21 sind Hardware-Zeitstempel (z. B. Capture-NIC, PTP-gesteuert) nötig.
 */
#include "st2110analyze.h"
#include "st2110core.h"
#include "st_internal.h"

#include <glib.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <strings.h>
#include <sys/stat.h>

#define MAX_STREAMS 256
#define MAX_PTP 16
#define MAX_GROUPS 256
#define SERIES_MAX 4000

typedef struct {
    float *t;   /* Sekunden ab Mitschnittbeginn */
    float *v;
    size_t n, cap;
    size_t stride, skip; /* Ausdünnung */
} series;

static void series_add(series *s, double t, double v)
{
    if (s->stride == 0) s->stride = 1;
    if (++s->skip < s->stride) return;
    s->skip = 0;
    if (s->n == s->cap) {
        if (s->cap >= SERIES_MAX) {
            /* jeden zweiten Punkt verwerfen, Schrittweite verdoppeln */
            size_t j = 0;
            for (size_t i = 0; i < s->n; i += 2, j++) { s->t[j] = s->t[i]; s->v[j] = s->v[i]; }
            s->n = j;
            s->stride *= 2;
        } else {
            s->cap = s->cap ? s->cap * 2 : 256;
            s->t = realloc(s->t, s->cap * sizeof(float));
            s->v = realloc(s->v, s->cap * sizeof(float));
        }
    }
    s->t[s->n] = (float)t;
    s->v[s->n] = (float)v;
    s->n++;
}

typedef struct { double min, max, sum; uint64_t n; } mstat;
static void stat_add(mstat *s, double v)
{
    if (s->n == 0 || v < s->min) s->min = v;
    if (s->n == 0 || v > s->max) s->max = v;
    s->sum += v;
    s->n++;
}
static double stat_avg(const mstat *s) { return s->n ? s->sum / (double)s->n : 0; }

typedef enum { K_UNKNOWN = 0, K_VIDEO, K_AUDIO, K_ANC } kind;

typedef struct {
    uint32_t src, dst;
    uint16_t sport, dport;
    uint32_t ssrc;
    int pt;
    kind k;
    int sdp_index;          /* passende SDP oder -1 */
    st_sdp_media sdp;

    uint64_t packets, bytes, rtp_bad;
    double first_t, last_t;
    /* Sequenz */
    int have_seq;
    uint32_t last_ext;      /* erweiterte Sequenz (ESN bei Video) */
    uint16_t last_seq;
    uint64_t lost, dup, reorder, ssrc_changes;
    /* Paketabstand */
    double last_arrival;
    mstat iat;
    uint64_t iat_hist[16];  /* < 1,2,5,10,20,50,100,200,500 µs, 1,2,5,10,20,50 ms, mehr */
    /* Klassifikation */
    uint64_t ts_changes;
    uint32_t last_ts;
    int have_ts;
    uint32_t ts_step_mode;
    uint32_t step_vals[8];
    uint32_t step_cnt[8];
    size_t psize_min, psize_max;
    uint64_t srd_ok, srd_checked, markers;

    /* Video je Bild */
    double f_first, f_last;
    uint32_t f_ts;
    int f_open;
    uint32_t f_pkts;
    int f_maxline, f_maxpix, f_interlace, f_marker;
    double *arr;            /* Ankunftszeiten der Pakete des aktuellen Bildes */
    size_t arr_n, arr_cap;
    uint64_t frames, frames_no_marker;
    mstat pkts_per_frame, frame_dur_ms, first_pkt_ms, cmax, vrx_max, latency_ms, frame_ival_ms;
    uint64_t vrx_underflow_frames;
    int width, height, interlaced, pgroup;  /* erkannt */
    uint32_t px_seen_bytes, px_seen_px;
    double bucket, bucket_t;
    series s_latency, s_cinst, s_vrx, s_pkts, s_iat;
    /* Vorschaubild */
    uint8_t *thumb_buf;
    int thumb_w, thumb_h, thumb_state; /* 0 warten, 1 sammeln, 2 fertig */
    uint32_t thumb_ts;

    /* Audio */
    double tsdf_r0, tsdf_a0, tsdf_min, tsdf_max, tsdf_win_start;
    int tsdf_have;
    mstat tsdf_us, ptime_ms, audio_latency_ms;
    series s_tsdf;
    uint32_t audio_payload;

    /* ANC */
    uint32_t did_sdid[16];
    uint32_t did_cnt[16];
    int did_n;
} stream;

typedef struct {
    int domain;
    uint64_t announce, sync, follow_up, delay_req, delay_resp, other;
    uint8_t gm[8];
    int have_gm;
    int priority1, priority2, clock_class, clock_accuracy, time_source, utc_offset, steps_removed;
    uint8_t masters[4][8];
    int n_masters;
    double first_t, last_t;
    int two_step;
} ptp_domain;

typedef struct {
    uint32_t group;
    uint64_t joins, leaves;
} igmp_group;

struct st_analysis {
    char *json;
    stream *streams[MAX_STREAMS];
    int n_streams;
    st_sdp_media sdps[32];
    int n_sdps;
    ptp_domain ptp[MAX_PTP];
    int n_ptp;
    igmp_group groups[MAX_GROUPS];
    int n_groups;
    uint64_t igmp_queries, igmp_v3_queries;
    uint32_t querier;
    uint64_t total_packets, ip_packets, udp_packets, non_ip, fragments, truncated;
    double t0, t_last;
    int have_t0;
    char format[32];
    int linktype;
    int ts_resolution_ns;
    int software_capture;   /* Kommentar „2110 Viewer Software-Mitschnitt“ */
    char comment[256];
};

/* ------------------------------------------------------------------ */

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

static void ipstr(uint32_t ip, char *o, size_t n)
{
    snprintf(o, n, "%u.%u.%u.%u", ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255);
}

static stream *get_stream(st_analysis *a, uint32_t src, uint32_t dst, uint16_t sp, uint16_t dp, uint32_t ssrc, double t)
{
    for (int i = 0; i < a->n_streams; i++) {
        stream *s = a->streams[i];
        if (s->src == src && s->dst == dst && s->sport == sp && s->dport == dp) {
            if (s->ssrc != ssrc) { s->ssrc_changes++; s->ssrc = ssrc; s->have_seq = 0; s->have_ts = 0; }
            return s;
        }
    }
    if (a->n_streams >= MAX_STREAMS) return NULL;
    stream *s = calloc(1, sizeof *s);
    s->src = src; s->dst = dst; s->sport = sp; s->dport = dp; s->ssrc = ssrc;
    s->first_t = t;
    s->sdp_index = -1;
    s->psize_min = SIZE_MAX;
    char d[32];
    ipstr(dst, d, sizeof d);
    for (int i = 0; i < a->n_sdps; i++) {
        if (strcmp(a->sdps[i].dest_addr, d) == 0 && a->sdps[i].port == dp) {
            s->sdp_index = i;
            s->sdp = a->sdps[i];
            break;
        }
    }
    a->streams[a->n_streams++] = s;
    return s;
}

static void note_step(stream *s, uint32_t d)
{
    for (int i = 0; i < 8; i++) {
        if (s->step_cnt[i] && s->step_vals[i] == d) { s->step_cnt[i]++; return; }
    }
    for (int i = 0; i < 8; i++) {
        if (!s->step_cnt[i]) { s->step_vals[i] = d; s->step_cnt[i] = 1; return; }
    }
}

static uint32_t mode_step(const stream *s)
{
    uint32_t best = 0, cnt = 0;
    for (int i = 0; i < 8; i++) if (s->step_cnt[i] > cnt) { cnt = s->step_cnt[i]; best = s->step_vals[i]; }
    return best;
}

static int iat_bin(double us)
{
    static const double lim[15] = { 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000 };
    for (int i = 0; i < 15; i++) if (us < lim[i]) return i;
    return 15;
}

/* Ende eines Videobildes: Kennzahlen nach ST 2110-21 */
static void close_frame(st_analysis *a, stream *s, int final)
{
    if (!s->f_open || s->arr_n == 0) return;
    s->f_open = 0;
    if (final && !s->f_marker) return; /* unvollständiges letztes Bild am Mitschnittende */
    s->frames++;
    if (!s->f_marker) s->frames_no_marker++;
    uint32_t N = (uint32_t)s->arr_n;
    stat_add(&s->pkts_per_frame, N);
    double t_rel = s->f_first - a->t0;
    series_add(&s->s_pkts, t_rel, N);
    if (s->f_maxline > 0 && s->f_marker) {
        s->height = s->f_interlace ? s->f_maxline * 2 : s->f_maxline;
        if (s->f_maxpix > s->width) s->width = s->f_maxpix;
        s->interlaced = s->f_interlace;
    }
    stat_add(&s->frame_dur_ms, (s->f_last - s->f_first) * 1000.0);

    uint32_t step = s->ts_step_mode ? s->ts_step_mode : mode_step(s);
    if (step == 0 || step > 90000) return;
    double Tframe = step / 90000.0;
    int H = s->height > 0 ? (s->interlaced ? s->height / 2 : s->height) : 1080;
    int total = (s->height == 1080 || s->height == 540) ? 1125 : (s->height == 720 ? 750 : (s->height == 2160 ? 2250 : H + H / 24));
    if (s->interlaced) total = total / 2;
    double Ractive = (double)H / (double)total;

    /* RTP-Latenz: erstes Paket gegenüber Bildzeit (RTP-Zeitstempel).
     * Absolut nur sinnvoll, wenn der Mitschnittrechner PTP-synchron war. */
    uint64_t ref_ns = (uint64_t)(s->f_first * 1e9) + (uint64_t)ST_TAI_UTC_OFFSET_S * 1000000000ULL;
    uint64_t frame_ns = st_ticks_to_ns(st_rtp_unwrap(s->f_ts, 90000, ref_ns), 90000);
    double lat_ms = ((double)ref_ns - (double)frame_ns) / 1e6;
    if (fabs(lat_ms) < 1e6) {
        stat_add(&s->latency_ms, lat_ms);
        series_add(&s->s_latency, t_rel, lat_ms);
    }

    /* Cinst: Eimer füllt sich je Paket um 1, leert sich mit 1 Paket je TDRAIN */
    double Tdrain = (Tframe / N) / 1.1;
    double cmax_frame = 0;
    for (size_t i = 0; i < s->arr_n; i++) {
        double t = s->arr[i];
        if (s->bucket_t > 0) {
            double drained = (t - s->bucket_t) / Tdrain;
            s->bucket = s->bucket - drained;
            if (s->bucket < 0) s->bucket = 0;
        }
        s->bucket += 1;
        s->bucket_t = t;
        if (s->bucket > cmax_frame) cmax_frame = s->bucket;
    }
    stat_add(&s->cmax, cmax_frame);
    series_add(&s->s_cinst, t_rel, cmax_frame);

    /* VRX: Empfänger liest ab dem ersten Paket alle TRS ein Paket */
    double TRS = Tframe * Ractive / N;
    double vmax = 0;
    int underflow = 0;
    for (size_t i = 0; i < s->arr_n; i++) {
        double t = s->arr[i] - s->arr[0];
        double reads = floor(t / TRS);
        double v = (double)(i + 1) - reads;
        if (v > vmax) vmax = v;
        if (v < 0) underflow = 1;
    }
    stat_add(&s->vrx_max, vmax);
    series_add(&s->s_vrx, t_rel, vmax);
    if (underflow) s->vrx_underflow_frames++;
}

static void handle_video(st_analysis *a, stream *s, double t, const uint8_t *pl, size_t n, uint32_t ts, int marker, uint16_t seq)
{
    (void)seq;
    if (s->f_open && ts != s->f_ts) close_frame(a, s, 0);
    if (!s->f_open) {
        if (s->frames > 0) stat_add(&s->frame_ival_ms, (t - s->f_first) * 1000.0);
        s->f_open = 1;
        s->f_ts = ts;
        s->f_first = t;
        s->f_maxline = s->f_maxpix = s->f_interlace = s->f_marker = 0;
        s->arr_n = 0;
        /* Vorschaubild: drittes Bild sammeln */
        if (s->thumb_state == 0 && s->frames >= 2 && s->width > 0 && s->height > 0 && s->pgroup > 0) {
            int h = s->interlaced ? s->height / 2 : s->height;
            s->thumb_w = s->width;
            s->thumb_h = h;
            s->thumb_buf = calloc((size_t)s->width / 2 * (size_t)s->pgroup * (size_t)h, 1);
            s->thumb_ts = ts;
            s->thumb_state = s->thumb_buf ? 1 : 3;
        }
    }
    s->f_last = t;
    if (s->arr_n == s->arr_cap) {
        s->arr_cap = s->arr_cap ? s->arr_cap * 2 : 4096;
        s->arr = realloc(s->arr, s->arr_cap * sizeof(double));
    }
    s->arr[s->arr_n++] = t;
    if (marker) s->f_marker = 1;
    /* RFC 4175: ESN, dann SRD-Köpfe */
    if (n < 8) return;
    const uint8_t *p = pl + 2, *end = pl + n;
    const uint8_t *hdr[16];
    int nh = 0;
    while (p + 6 <= end && nh < 16) {
        hdr[nh++] = p;
        int cont = p[4] >> 7;
        p += 6;
        if (!cont) break;
    }
    const uint8_t *data = p;
    for (int i = 0; i < nh; i++) {
        int len = rd16(hdr[i]);
        int field = hdr[i][2] >> 7;
        int line = (hdr[i][2] & 0x7f) << 8 | hdr[i][3];
        int off = (hdr[i][4] & 0x7f) << 8 | hdr[i][5];
        if (field) s->f_interlace = 1;
        if (line + 1 > s->f_maxline) s->f_maxline = line + 1;
        /* pgroup-Größe aus Byte/Pixel-Verhältnis bestimmen */
        if (s->pgroup == 0 && i + 1 < nh) {
            int len2 = rd16(hdr[i + 1]);
            (void)len2;
        }
        if (s->pgroup > 0) {
            int px = off + len / s->pgroup * 2;
            if (px > s->f_maxpix) s->f_maxpix = px;
        } else if (len > 0) {
            /* Zwischenspeicher: Summe Bytes und Offsets je Zeile 0 */
            if (line == 0 && off > 0 && !s->px_seen_px) { s->px_seen_px = (uint32_t)off; }
            if (line == 0 && off == 0) s->px_seen_bytes = (uint32_t)len;
            if (s->px_seen_px && s->px_seen_bytes) {
                double r = (double)s->px_seen_bytes / (double)s->px_seen_px; /* Byte je Pixel */
                if (fabs(r - 2.5) < 0.01) s->pgroup = 5;
                else if (fabs(r - 2.0) < 0.01) s->pgroup = 4;
                else if (fabs(r - 3.0) < 0.01) s->pgroup = 6;
            }
        }
        if (s->thumb_state == 1 && ts == s->thumb_ts && s->pgroup > 0) {
            size_t lb = (size_t)s->thumb_w / 2 * (size_t)s->pgroup;
            size_t bo = (size_t)off / 2 * (size_t)s->pgroup;
            if (line < s->thumb_h && bo + (size_t)len <= lb && data + len <= end)
                memcpy(s->thumb_buf + (size_t)line * lb + bo, data, (size_t)len);
        }
        data += len;
    }
    if (s->sdp_index >= 0 && s->sdp.depth == 10) s->pgroup = 5;
    if (s->sdp_index >= 0 && s->sdp.depth == 8) s->pgroup = 4;
    if (s->thumb_state == 1 && marker && ts == s->thumb_ts) s->thumb_state = 2;
}

static void handle_audio(st_analysis *a, stream *s, double t, size_t n, uint32_t ts)
{
    (void)a;
    int rate = (s->sdp_index >= 0 && s->sdp.clock_rate > 0) ? s->sdp.clock_rate : 48000;
    s->audio_payload = (uint32_t)n;
    double r = ts / (double)rate;
    if (!s->tsdf_have) {
        s->tsdf_have = 1;
        s->tsdf_a0 = t;
        s->tsdf_r0 = r;
        s->tsdf_min = s->tsdf_max = 0;
        s->tsdf_win_start = t;
    } else {
        double rr = r - s->tsdf_r0;
        if (rr < -1000) rr += 4294967296.0 / rate; /* Umlauf */
        double d = (t - s->tsdf_a0) - rr;
        if (d < s->tsdf_min) s->tsdf_min = d;
        if (d > s->tsdf_max) s->tsdf_max = d;
        if (t - s->tsdf_win_start >= 1.0) {
            double tsdf = (s->tsdf_max - s->tsdf_min) * 1e6;
            stat_add(&s->tsdf_us, tsdf);
            series_add(&s->s_tsdf, t - a->t0, tsdf);
            s->tsdf_a0 = t;
            s->tsdf_r0 = r;
            s->tsdf_min = s->tsdf_max = 0;
            s->tsdf_win_start = t;
        }
    }
    uint64_t ref_ns = (uint64_t)(t * 1e9) + (uint64_t)ST_TAI_UTC_OFFSET_S * 1000000000ULL;
    uint64_t cap = st_ticks_to_ns(st_rtp_unwrap(ts, (uint32_t)rate, ref_ns), (uint32_t)rate);
    double lat = ((double)ref_ns - (double)cap) / 1e6;
    if (fabs(lat) < 1e6) stat_add(&s->audio_latency_ms, lat);
}

static void handle_anc(stream *s, const uint8_t *pl, size_t n)
{
    /* ST 2110-40 / RFC 8331: ESN(2) Länge(2) ANC_Count(1) F+res(3), dann Pakete */
    if (n < 8) return;
    int count = pl[4];
    const uint8_t *p = pl + 8, *end = pl + n;
    for (int i = 0; i < count && p + 8 <= end; i++) {
        /* C(1) Line(11) HOffset(12) S(1) StreamNum(7) = 32 Bit, dann DID(10) SDID(10) DataCount(10) ... */
        uint64_t bits = (uint64_t)rd32(p + 4) << 32 | (p + 8 <= end ? 0 : 0);
        uint32_t w = rd32(p + 4);
        uint32_t did = (w >> 22) & 0xff, sdid = (w >> 12) & 0xff;
        (void)bits;
        uint32_t key = did << 8 | sdid;
        int found = 0;
        for (int k = 0; k < s->did_n; k++) if (s->did_sdid[k] == key) { s->did_cnt[k]++; found = 1; break; }
        if (!found && s->did_n < 16) { s->did_sdid[s->did_n] = key; s->did_cnt[s->did_n++] = 1; }
        uint32_t dc = (w >> 2) & 0xff;
        size_t words = 3 + dc + 1;            /* DID, SDID, DC, UDW…, Checksum */
        size_t bitsz = 32 + words * 10;
        size_t bytes = (bitsz + 7) / 8;
        bytes = (bytes + 3) & ~(size_t)3;     /* auf 32 Bit aufgefüllt */
        p += bytes;
    }
}

static void handle_rtp(st_analysis *a, uint32_t src, uint32_t dst, uint16_t sp, uint16_t dp,
                       const uint8_t *u, size_t n, double t)
{
    if (n < 12 || (u[0] >> 6) != 2) return;
    size_t off = 12 + 4u * (u[0] & 0x0f);
    if (u[0] & 0x10) {
        if (n < off + 4) return;
        off += 4 + 4u * rd16(u + off + 2);
    }
    if (off > n) return;
    uint32_t ssrc = rd32(u + 8);
    stream *s = get_stream(a, src, dst, sp, dp, ssrc, t);
    if (!s) return;
    uint16_t seq = rd16(u + 2);
    uint32_t ts = rd32(u + 4);
    int marker = u[1] >> 7;
    s->pt = u[1] & 0x7f;
    s->packets++;
    s->bytes += n + 42; /* inkl. Eth/IP/UDP */
    s->last_t = t;
    size_t pl = n - off;
    if (pl < s->psize_min) s->psize_min = pl;
    if (pl > s->psize_max) s->psize_max = pl;
    if (marker) s->markers++;
    /* Paketabstand */
    if (s->packets > 1) {
        double iat = (t - s->last_arrival) * 1e6;
        stat_add(&s->iat, iat);
        s->iat_hist[iat_bin(iat)]++;
        series_add(&s->s_iat, t - a->t0, iat);
    }
    s->last_arrival = t;
    /* Zeitstempelschritte */
    if (s->have_ts && ts != s->last_ts) {
        s->ts_changes++;
        note_step(s, ts - s->last_ts);
    }
    s->have_ts = 1;
    s->last_ts = ts;
    /* RFC-4175-Plausibilität */
    if (pl >= 8) {
        s->srd_checked++;
        int len = rd16(u + off + 2), line = (u[off + 4] & 0x7f) << 8 | u[off + 5];
        if (len > 0 && (size_t)len + 8 <= pl && line < 4400) s->srd_ok++;
    }
    /* Klassifikation (SDP hat Vorrang) */
    if (s->k == K_UNKNOWN) {
        if (s->sdp_index >= 0) {
            s->k = s->sdp.kind == ST_MEDIA_VIDEO ? K_VIDEO : s->sdp.kind == ST_MEDIA_AUDIO ? K_AUDIO : K_ANC;
        } else if (s->packets >= 200) {
            double ppt = (double)s->packets / (double)(s->ts_changes + 1);
            if (ppt >= 4 && s->srd_ok > s->srd_checked * 9 / 10) s->k = K_VIDEO;
            else if (ppt <= 1.05 && s->psize_max == s->psize_min) s->k = K_AUDIO;
            else if (ppt <= 4 && s->markers > s->packets / 4) s->k = K_ANC;
        }
    }
    /* Sequenz (Video: mit ESN aus dem Nutzlastkopf); erst nach der Einordnung */
    if (s->k == K_UNKNOWN) return;
    int vid = s->k == K_VIDEO;
    uint32_t ext = seq;
    if (vid && pl >= 2) ext = (uint32_t)rd16(u + off) << 16 | seq;
    if (s->have_seq) {
        uint32_t diff = vid ? ext - (s->last_ext + 1) : (uint16_t)(seq - (uint16_t)(s->last_seq + 1));
        uint32_t back = vid ? s->last_ext - ext : (uint16_t)(s->last_seq - seq);
        uint32_t half = vid ? 0x80000000u : 0x8000u;
        if (diff == 0) {
            /* erwartet */
        } else if (diff < half && diff < 100000) {
            s->lost += diff;
        } else if (back == 0) {
            s->dup++;
            return;
        } else if (back < 1000) {
            s->reorder++;
            if (s->lost) s->lost--;
            return;
        }
        /* sonst: Sprung (Senderneustart) – neu aufsetzen */
    }
    s->have_seq = 1;
    s->last_seq = seq;
    s->last_ext = ext;

    if (s->k == K_VIDEO) {
        if (!s->ts_step_mode && s->ts_changes > 10) s->ts_step_mode = mode_step(s);
        handle_video(a, s, t, u + off, pl, ts, marker, seq);
    } else if (s->k == K_AUDIO) {
        handle_audio(a, s, t, pl, ts);
        if (s->ts_changes > 0) stat_add(&s->ptime_ms, (double)mode_step(s) / ((s->sdp_index >= 0 && s->sdp.clock_rate) ? s->sdp.clock_rate : 48000) * 1000.0);
    } else if (s->k == K_ANC) {
        handle_anc(s, u + off, pl);
    }
}

static void handle_ptp(st_analysis *a, const uint8_t *p, size_t n, double t)
{
    if (n < 34) return;
    int type = p[0] & 0x0f, ver = p[1] & 0x0f;
    if (ver != 2) return;
    int dom = p[4];
    ptp_domain *d = NULL;
    for (int i = 0; i < a->n_ptp; i++) if (a->ptp[i].domain == dom) d = &a->ptp[i];
    if (!d) {
        if (a->n_ptp >= MAX_PTP) return;
        d = &a->ptp[a->n_ptp++];
        memset(d, 0, sizeof *d);
        d->domain = dom;
        d->first_t = t;
    }
    d->last_t = t;
    const uint8_t *clk = p + 20;
    switch (type) {
    case 0x0:
        d->sync++;
        if (p[6] & 0x02) d->two_step = 1;
        break;
    case 0x8: d->follow_up++; break;
    case 0x1: d->delay_req++; break;
    case 0x9: d->delay_resp++; break;
    case 0xB:
        d->announce++;
        if (n >= 64) {
            d->utc_offset = (int16_t)rd16(p + 44);
            d->priority1 = p[47];
            d->clock_class = p[48];
            d->clock_accuracy = p[49];
            d->priority2 = p[52];
            memcpy(d->gm, p + 53, 8);
            d->have_gm = 1;
            d->steps_removed = rd16(p + 61);
            d->time_source = p[63];
        }
        break;
    default: d->other++; break;
    }
    if (type == 0x0 || type == 0xB) {
        int known = 0;
        for (int i = 0; i < d->n_masters; i++) if (memcmp(d->masters[i], clk, 8) == 0) known = 1;
        if (!known && d->n_masters < 4) memcpy(d->masters[d->n_masters++], clk, 8);
    }
}

static void igmp_group_add(st_analysis *a, uint32_t g, int join)
{
    for (int i = 0; i < a->n_groups; i++) {
        if (a->groups[i].group == g) { if (join) a->groups[i].joins++; else a->groups[i].leaves++; return; }
    }
    if (a->n_groups >= MAX_GROUPS) return;
    a->groups[a->n_groups].group = g;
    a->groups[a->n_groups].joins = join ? 1 : 0;
    a->groups[a->n_groups].leaves = join ? 0 : 1;
    a->n_groups++;
}

static void handle_igmp(st_analysis *a, uint32_t src, const uint8_t *p, size_t n)
{
    if (n < 8) return;
    switch (p[0]) {
    case 0x11:
        a->igmp_queries++;
        if (n >= 12) a->igmp_v3_queries++;
        a->querier = src;
        break;
    case 0x12: case 0x16: igmp_group_add(a, rd32(p + 4), 1); break;
    case 0x17: igmp_group_add(a, rd32(p + 4), 0); break;
    case 0x22: {
        int nrec = rd16(p + 6);
        const uint8_t *r = p + 8, *end = p + n;
        for (int i = 0; i < nrec && r + 8 <= end; i++) {
            int rtype = r[0], aux = r[1], nsrc = rd16(r + 2);
            uint32_t g = rd32(r + 4);
            /* 1/2 = MODE_IS_INCLUDE/EXCLUDE, 4 = CHANGE_TO_EXCLUDE (Join), 3 = CHANGE_TO_INCLUDE (Leave, wenn leer) */
            int join = (rtype == 2 || rtype == 4 || rtype == 5 || ((rtype == 1 || rtype == 3) && nsrc > 0));
            igmp_group_add(a, g, join);
            r += 8 + 4 * nsrc + 4 * aux;
        }
        break;
    }
    default: break;
    }
}

static void handle_ip(st_analysis *a, const uint8_t *p, size_t n, double t)
{
    if (n < 20 || (p[0] >> 4) != 4) { a->non_ip++; return; }
    a->ip_packets++;
    size_t ihl = (size_t)(p[0] & 0x0f) * 4;
    size_t tot = rd16(p + 2);
    if (tot < n) n = tot;
    if (n < ihl) return;
    uint16_t frag = rd16(p + 6);
    if ((frag & 0x3fff) != 0) { a->fragments++; return; }
    uint32_t src = rd32(p + 12), dst = rd32(p + 16);
    int proto = p[9];
    const uint8_t *l4 = p + ihl;
    size_t l4n = n - ihl;
    if (proto == 2) { handle_igmp(a, src, l4, l4n); return; }
    if (proto != 17 || l4n < 8) return;
    a->udp_packets++;
    uint16_t sp = rd16(l4), dp = rd16(l4 + 2);
    if (dp == 319 || dp == 320) { handle_ptp(a, l4 + 8, l4n - 8, t); return; }
    handle_rtp(a, src, dst, sp, dp, l4 + 8, l4n - 8, t);
}

static void handle_frame(st_analysis *a, int link, const uint8_t *d, size_t n, double t)
{
    if (!a->have_t0) { a->t0 = t; a->have_t0 = 1; }
    a->t_last = t;
    a->total_packets++;
    uint16_t et;
    switch (link) {
    case 1: /* Ethernet */
        if (n < 14) return;
        et = rd16(d + 12);
        d += 14; n -= 14;
        while ((et == 0x8100 || et == 0x88a8) && n >= 4) { et = rd16(d + 2); d += 4; n -= 4; }
        if (et == 0x88f7) { handle_ptp(a, d, n, t); return; }
        if (et != 0x0800) { a->non_ip++; return; }
        handle_ip(a, d, n, t);
        return;
    case 0: case 108: /* BSD-/OpenBSD-Loopback */
        if (n < 4) return;
        handle_ip(a, d + 4, n - 4, t);
        return;
    case 101: case 12: case 14: case 228: /* rohes IP */
        handle_ip(a, d, n, t);
        return;
    case 113: /* Linux cooked */
        if (n < 16) return;
        et = rd16(d + 14);
        if (et == 0x88f7) { handle_ptp(a, d + 16, n - 16, t); return; }
        if (et == 0x0800) handle_ip(a, d + 16, n - 16, t);
        return;
    case 276: /* Linux cooked v2 */
        if (n < 20) return;
        et = rd16(d);
        if (et == 0x88f7) { handle_ptp(a, d + 20, n - 20, t); return; }
        if (et == 0x0800) handle_ip(a, d + 20, n - 20, t);
        return;
    default:
        a->non_ip++;
    }
}

/* ------------------------------------------------------------------ */
/* Dateiformate                                                       */

static uint32_t rd32le(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t rd32x(const uint8_t *p, int be) { return be ? rd32(p) : rd32le(p); }
static uint16_t rd16x(const uint8_t *p, int be) { return be ? rd16(p) : (uint16_t)(p[0] | p[1] << 8); }

static int read_pcap(st_analysis *a, FILE *f, const uint8_t *hdr, long fsize, st_progress_fn prog, void *user, char *err, size_t el)
{
    uint32_t magic = rd32le(hdr);
    int be = 0, ns = 0;
    if (magic == 0xa1b2c3d4) { be = 0; ns = 0; }
    else if (magic == 0xa1b23c4d) { be = 0; ns = 1; }
    else if (magic == 0xd4c3b2a1) { be = 1; ns = 0; }
    else if (magic == 0x4d3cb2a1) { be = 1; ns = 1; }
    else { snprintf(err, el, "Unbekanntes Dateiformat."); return -1; }
    snprintf(a->format, sizeof a->format, "pcap");
    a->linktype = (int)(rd32x(hdr + 20, be) & 0x0fffffff);
    a->ts_resolution_ns = ns ? 1 : 1000;
    uint8_t rh[16];
    uint8_t *buf = malloc(262144);
    long pos = 24;
    uint64_t cnt = 0;
    while (fread(rh, 1, 16, f) == 16) {
        uint32_t sec = rd32x(rh, be), frac = rd32x(rh + 4, be), incl = rd32x(rh + 8, be), orig = rd32x(rh + 12, be);
        if (incl > 262144) { snprintf(err, el, "Beschädigter Datensatz (Länge %u).", incl); free(buf); return -1; }
        if (fread(buf, 1, incl, f) != incl) { a->truncated++; break; }
        if (incl < orig) a->truncated++;
        double t = sec + frac / (ns ? 1e9 : 1e6);
        handle_frame(a, a->linktype, buf, incl, t);
        pos += 16 + (long)incl;
        if (prog && (++cnt & 0x3fff) == 0 && prog(user, fsize > 0 ? (double)pos / (double)fsize : 0)) { free(buf); snprintf(err, el, "Abgebrochen."); return -1; }
    }
    free(buf);
    return 0;
}

static int read_pcapng(st_analysis *a, FILE *f, long fsize, st_progress_fn prog, void *user, char *err, size_t el)
{
    snprintf(a->format, sizeof a->format, "pcapng");
    int be = 0;
    int link[32];
    double tsres[32];
    int nif = 0;
    uint8_t *buf = malloc(262144 + 64);
    uint8_t bh[8];
    long pos = 0;
    uint64_t cnt = 0;
    while (fread(bh, 1, 8, f) == 8) {
        uint32_t type = rd32x(bh, be);
        if (type == 0x0A0D0D0A) {
            /* Bytereihenfolge aus dem SHB lesen */
            uint8_t bom[4];
            if (fread(bom, 1, 4, f) != 4) break;
            be = rd32le(bom) == 0x4d3c2b1a ? 1 : 0;
            uint32_t len = rd32x(bh + 4, be);
            if (len < 16 || len > 262144) { snprintf(err, el, "Beschädigter pcapng-Block."); free(buf); return -1; }
            if (fread(buf, 1, len - 12, f) != len - 12) break;
            /* Optionen ab Offset 12 (nach Major/Minor/SectionLength) */
            size_t o = 12;
            while (o + 4 <= len - 16) {
                uint16_t code = rd16x(buf + o, be), ol = rd16x(buf + o + 2, be);
                if (code == 0) break;
                if (code == 1 && ol > 0) {
                    size_t cl = ol < sizeof a->comment - 1 ? ol : sizeof a->comment - 1;
                    memcpy(a->comment, buf + o + 4, cl);
                    a->comment[cl] = 0;
                    if (strstr(a->comment, "2110 Viewer")) a->software_capture = 1;
                }
                o += 4 + ((ol + 3u) & ~3u);
            }
            nif = 0;
            pos += (long)len;
            continue;
        }
        uint32_t len = rd32x(bh + 4, be);
        if (len < 12 || len > 262144 + 64) { snprintf(err, el, "Beschädigter pcapng-Block (Länge %u).", len); free(buf); return -1; }
        if (fread(buf, 1, len - 8, f) != len - 8) { a->truncated++; break; }
        pos += (long)len;
        if (type == 1 && nif < 32) { /* IDB */
            link[nif] = rd16x(buf, be);
            tsres[nif] = 1e-6;
            size_t o = 8;
            while (o + 4 <= len - 12) {
                uint16_t code = rd16x(buf + o, be), ol = rd16x(buf + o + 2, be);
                if (code == 0) break;
                if (code == 9 && ol >= 1) {
                    uint8_t r = buf[o + 4];
                    tsres[nif] = (r & 0x80) ? pow(2.0, -(double)(r & 0x7f)) : pow(10.0, -(double)r);
                }
                if (code == 1 && ol > 0 && strstr((const char *)buf + o + 4, "2110 Viewer")) a->software_capture = 1;
                o += 4 + ((ol + 3u) & ~3u);
            }
            if (nif == 0) {
                a->linktype = link[0];
                a->ts_resolution_ns = (int)lround(tsres[0] * 1e9);
                if (a->ts_resolution_ns < 1) a->ts_resolution_ns = 1;
            }
            nif++;
        } else if (type == 6) { /* EPB */
            uint32_t ifid = rd32x(buf, be);
            uint64_t ts = (uint64_t)rd32x(buf + 4, be) << 32 | rd32x(buf + 8, be);
            uint32_t cap = rd32x(buf + 12, be), orig = rd32x(buf + 16, be);
            if ((int)ifid >= nif || cap + 20 > len - 8) continue;
            if (cap < orig) a->truncated++;
            handle_frame(a, link[ifid], buf + 20, cap, (double)ts * tsres[ifid]);
        } else if (type == 3 && nif > 0) { /* SPB ohne Zeitstempel: nur zählen */
            a->total_packets++;
        }
        if (prog && (++cnt & 0x3fff) == 0 && prog(user, fsize > 0 ? (double)pos / (double)fsize : 0)) { free(buf); snprintf(err, el, "Abgebrochen."); return -1; }
    }
    free(buf);
    return 0;
}

/* ------------------------------------------------------------------ */
/* JSON                                                               */

static void js_str(GString *g, const char *s)
{
    g_string_append_c(g, '"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { g_string_append_c(g, '\\'); g_string_append_c(g, (char)c); }
        else if (c < 0x20) g_string_append_printf(g, "\\u%04x", c);
        else g_string_append_c(g, (char)c);
    }
    g_string_append_c(g, '"');
}

static void js_num(GString *g, double v)
{
    if (isnan(v) || isinf(v)) g_string_append(g, "null");
    else g_string_append_printf(g, "%.6g", v);
}

static void js_stat(GString *g, const char *name, const mstat *s)
{
    g_string_append_printf(g, "\"%s\":{\"min\":", name);
    js_num(g, s->n ? s->min : 0);
    g_string_append(g, ",\"avg\":");
    js_num(g, stat_avg(s));
    g_string_append(g, ",\"max\":");
    js_num(g, s->n ? s->max : 0);
    g_string_append_printf(g, ",\"n\":%llu}", (unsigned long long)s->n);
}

static void js_series(GString *g, const char *name, const series *s)
{
    g_string_append_printf(g, "\"%s\":{\"t\":[", name);
    for (size_t i = 0; i < s->n; i++) { if (i) g_string_append_c(g, ','); g_string_append_printf(g, "%.4f", s->t[i]); }
    g_string_append(g, "],\"v\":[");
    for (size_t i = 0; i < s->n; i++) { if (i) g_string_append_c(g, ','); js_num(g, s->v[i]); }
    g_string_append(g, "]}");
}

typedef struct { int level; char text[400]; } finding;

static void add_finding(finding *f, int *n, int level, const char *fmt, ...) G_GNUC_PRINTF(4, 5);
static void add_finding(finding *f, int *n, int level, const char *fmt, ...)
{
    if (*n >= 16) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(f[*n].text, sizeof f[*n].text, fmt, ap);
    va_end(ap);
    f[*n].level = level;
    (*n)++;
}

static void build_json(st_analysis *a)
{
    GString *g = g_string_new("{");
    double dur = a->have_t0 ? a->t_last - a->t0 : 0;
    g_string_append(g, "\"capture\":{\"format\":");
    js_str(g, a->format);
    g_string_append_printf(g, ",\"linktype\":%d,\"packets\":%llu,\"ip_packets\":%llu,\"udp_packets\":%llu,\"fragments\":%llu,\"truncated\":%llu,\"duration_s\":",
                           a->linktype, (unsigned long long)a->total_packets, (unsigned long long)a->ip_packets,
                           (unsigned long long)a->udp_packets, (unsigned long long)a->fragments, (unsigned long long)a->truncated);
    js_num(g, dur);
    g_string_append_printf(g, ",\"timestamp_resolution_ns\":%d,\"software_capture\":%s,\"comment\":", a->ts_resolution_ns,
                           a->software_capture ? "true" : "false");
    js_str(g, a->comment);
    g_string_append(g, ",\"findings\":[");
    int nfc = 0;
#define CF(level, ...) do { char _t[400]; snprintf(_t, sizeof _t, __VA_ARGS__); \
        g_string_append_printf(g, "%s{\"level\":%d,\"text\":", nfc++ ? "," : "", level); js_str(g, _t); g_string_append_c(g, '}'); } while (0)
    if (a->fragments)
        CF(2, "%llu IP-Fragmente: Die Pakete waren größer als die MTU eines Netzabschnitts. ST 2110 setzt unfragmentierte Pakete voraus; vermutlich ist die MTU (z. B. 1500 Byte) an Adapter oder Switch zu klein eingestellt.", (unsigned long long)a->fragments);
    if (a->truncated)
        CF(1, "%llu Pakete wurden beim Mitschnitt gekürzt (Snaplen zu klein). Für die Bildauswertung mindestens 1600 Byte mitschneiden.", (unsigned long long)a->truncated);
    if (a->software_capture)
        CF(1, "Software-Mitschnitt: Zeitstempel stammen vom Programm, nicht vom Netzwerkanschluss. Paketabstände, Cinst und VRX sind nur Richtwerte.");
    else if (a->ts_resolution_ns >= 1000)
        CF(1, "Zeitstempel mit Mikrosekunden-Auflösung. Für ST-2110-21-Bewertungen bei HD sind Nanosekunden-Hardwarezeitstempel empfehlenswert.");
    if (a->n_ptp == 0)
        CF(1, "Keine PTP-Nachrichten im Mitschnitt. Entweder ist kein Grandmaster aktiv oder der Mitschnitt enthält nur gefilterte Ströme.");
    for (int i = 0; i < a->n_ptp; i++)
        if (a->ptp[i].n_masters > 1) CF(2, "PTP-Domain %d: %d Geräte senden Sync/Announce (mehrere Master). Möglicherweise ist an einem Gerät „PTP follower only“ nicht gesetzt.", a->ptp[i].domain, a->ptp[i].n_masters);
    if (a->igmp_queries == 0 && a->n_groups > 0)
        CF(1, "IGMP-Meldungen, aber keine IGMP-Abfragen (Querier) gesehen. Ohne Querier kann der Switch Multicast-Ströme nach einiger Zeit abschalten.");
#undef CF
    g_string_append(g, "]},\"streams\":[");

    for (int i = 0; i < a->n_streams; i++) {
        stream *s = a->streams[i];
        if (s->k == K_VIDEO) close_frame(a, s, 1);
        if (i) g_string_append_c(g, ',');
        char src[32], dst[32];
        ipstr(s->src, src, sizeof src);
        ipstr(s->dst, dst, sizeof dst);
        double sd = s->last_t - s->first_t;
        const char *kn = s->k == K_VIDEO ? "video" : s->k == K_AUDIO ? "audio" : s->k == K_ANC ? "anc" : "unknown";
        g_string_append_printf(g, "{\"index\":%d,\"kind\":\"%s\",\"source\":\"%s:%u\",\"destination\":\"%s:%u\",\"ssrc\":%u,\"payload_type\":%d,"
                                  "\"packets\":%llu,\"bytes\":%llu,\"duration_s\":",
                               i, kn, src, s->sport, dst, s->dport, s->ssrc, s->pt,
                               (unsigned long long)s->packets, (unsigned long long)s->bytes);
        js_num(g, sd);
        g_string_append(g, ",\"rate_mbps\":");
        js_num(g, sd > 0 ? (double)s->bytes * 8 / sd / 1e6 : 0);
        g_string_append_printf(g, ",\"lost\":%llu,\"duplicates\":%llu,\"reordered\":%llu,\"ssrc_changes\":%llu,\"sdp_matched\":%s,",
                               (unsigned long long)s->lost, (unsigned long long)s->dup, (unsigned long long)s->reorder,
                               (unsigned long long)s->ssrc_changes, s->sdp_index >= 0 ? "true" : "false");
        js_stat(g, "iat_us", &s->iat);
        g_string_append(g, ",\"iat_histogram\":[");
        for (int b = 0; b < 16; b++) g_string_append_printf(g, "%s%llu", b ? "," : "", (unsigned long long)s->iat_hist[b]);
        g_string_append(g, "],");

        finding f[16];
        int nf = 0;
        double loss_pct = s->packets + s->lost ? 100.0 * (double)s->lost / (double)(s->packets + s->lost) : 0;
        if (s->lost) add_finding(f, &nf, loss_pct > 0.01 ? 2 : 1, "%llu Pakete fehlen (%.4f %%).", (unsigned long long)s->lost, loss_pct);
        else add_finding(f, &nf, 0, "Keine Paketverluste.");
        if (s->reorder) add_finding(f, &nf, 1, "%llu Pakete in falscher Reihenfolge.", (unsigned long long)s->reorder);
        if (s->ssrc_changes) add_finding(f, &nf, 1, "SSRC hat %llu-mal gewechselt (Senderneustart?).", (unsigned long long)s->ssrc_changes);

        if (s->k == K_VIDEO) {
            uint32_t step = s->ts_step_mode ? s->ts_step_mode : mode_step(s);
            double fps = step ? 90000.0 / step : 0;
            double npk = stat_avg(&s->pkts_per_frame);
            double Tframe = fps > 0 ? 1.0 / fps : 0;
            int H = s->interlaced ? s->height / 2 : s->height;
            int total = (s->height == 1080 || s->height == 540) ? 1125 : (s->height == 720 ? 750 : (s->height == 2160 ? 2250 : H + H / 24));
            double Ractive = total > 0 ? (double)H / (s->interlaced ? total / 2 : total) : 1;
            double cmax_n = fps > 0 ? fmax(4, floor(npk / (43200.0 * Ractive * Tframe))) : 0;
            double cmax_w = fps > 0 ? fmax(16, floor(npk / (21600.0 * Tframe))) : 0;
            double vrx_n = fps > 0 ? fmax(8, floor(npk / (27000.0 * Tframe))) : 0;
            double vrx_w = fps > 0 ? fmax(720, floor(npk / (300.0 * Tframe))) : 0;
            const char *cls = "unbekannt";
            if (s->cmax.n) {
                if (s->cmax.max <= cmax_n && s->vrx_max.max <= vrx_n) cls = "N";
                else if (s->cmax.max <= cmax_w && s->vrx_max.max <= vrx_w) cls = "W";
                else cls = "nicht konform";
            }
            g_string_append_printf(g, "\"video\":{\"width\":%d,\"height\":%d,\"interlaced\":%s,\"pgroup_bytes\":%d,\"fps\":",
                                   s->width, s->height, s->interlaced ? "true" : "false", s->pgroup);
            js_num(g, fps);
            g_string_append_printf(g, ",\"frames\":%llu,\"frames_without_marker\":%llu,\"ts_step\":%u,",
                                   (unsigned long long)s->frames, (unsigned long long)s->frames_no_marker, step);
            js_stat(g, "packets_per_frame", &s->pkts_per_frame); g_string_append_c(g, ',');
            js_stat(g, "frame_duration_ms", &s->frame_dur_ms); g_string_append_c(g, ',');
            js_stat(g, "frame_interval_ms", &s->frame_ival_ms); g_string_append_c(g, ',');
            js_stat(g, "rtp_latency_ms", &s->latency_ms); g_string_append_c(g, ',');
            js_stat(g, "cinst", &s->cmax); g_string_append_c(g, ',');
            js_stat(g, "vrx", &s->vrx_max);
            g_string_append(g, ",\"limits\":{\"cmax_narrow\":"); js_num(g, cmax_n);
            g_string_append(g, ",\"cmax_wide\":"); js_num(g, cmax_w);
            g_string_append(g, ",\"vrx_narrow\":"); js_num(g, vrx_n);
            g_string_append(g, ",\"vrx_wide\":"); js_num(g, vrx_w);
            g_string_append_printf(g, "},\"st2110_21_class\":\"%s\",\"vrx_underflow_frames\":%llu,\"thumbnail\":%s,\"series\":{",
                                   cls, (unsigned long long)s->vrx_underflow_frames, s->thumb_state == 2 ? "true" : "false");
            js_series(g, "rtp_latency_ms", &s->s_latency); g_string_append_c(g, ',');
            js_series(g, "cinst", &s->s_cinst); g_string_append_c(g, ',');
            js_series(g, "vrx", &s->s_vrx); g_string_append_c(g, ',');
            js_series(g, "packets_per_frame", &s->s_pkts); g_string_append_c(g, ',');
            js_series(g, "iat_us", &s->s_iat);
            g_string_append(g, "}},");
            if (s->interlaced) add_finding(f, &nf, 1, "Halbbilder (Zeilensprung) erkannt.");
            if (s->frames_no_marker) add_finding(f, &nf, 1, "%llu Bilder ohne RTP-Marker am letzten Paket.", (unsigned long long)s->frames_no_marker);
            if (s->cmax.n) {
                if (strcmp(cls, "N") == 0) add_finding(f, &nf, 0, "Zeitverhalten passt zu ST 2110-21 Narrow (Cmax %.0f ≤ %.0f, VRX %.0f ≤ %.0f).", s->cmax.max, cmax_n, s->vrx_max.max, vrx_n);
                else if (strcmp(cls, "W") == 0) add_finding(f, &nf, 1, "Zeitverhalten passt zu ST 2110-21 Wide, nicht Narrow (Cmax %.0f, Grenze N %.0f / W %.0f).", s->cmax.max, cmax_n, cmax_w);
                else add_finding(f, &nf, 2, "Pakete kommen burstartiger als ST 2110-21 Wide erlaubt (Cmax %.0f > %.0f oder VRX %.0f > %.0f).", s->cmax.max, cmax_w, s->vrx_max.max, vrx_w);
            }
        } else if (s->k == K_AUDIO) {
            uint32_t step = mode_step(s);
            int rate = (s->sdp_index >= 0 && s->sdp.clock_rate) ? s->sdp.clock_rate : 48000;
            int ch = s->sdp_index >= 0 ? s->sdp.channels : 0;
            int bps = (s->sdp_index >= 0 && strcasecmp(s->sdp.encoding, "L16") == 0) ? 2 : 3;
            if (!ch && step) ch = (int)(s->audio_payload / ((size_t)step * 3));
            g_string_append_printf(g, "\"audio\":{\"samples_per_packet\":%u,\"channels\":%d,\"channels_from_sdp\":%s,\"bytes_per_sample\":%d,\"payload_bytes\":%u,\"ptime_ms\":",
                                   step, ch, s->sdp_index >= 0 ? "true" : "false", bps, s->audio_payload);
            js_num(g, step ? step * 1000.0 / rate : 0);
            g_string_append_c(g, ',');
            js_stat(g, "tsdf_us", &s->tsdf_us); g_string_append_c(g, ',');
            js_stat(g, "rtp_latency_ms", &s->audio_latency_ms);
            g_string_append(g, ",\"series\":{");
            js_series(g, "tsdf_us", &s->s_tsdf); g_string_append_c(g, ',');
            js_series(g, "iat_us", &s->s_iat);
            g_string_append(g, "}},");
            if (s->tsdf_us.n) add_finding(f, &nf, 0, "TS-DF max. %.0f µs (Paketzeit %.3f ms).", s->tsdf_us.max, step * 1000.0 / rate);
        } else if (s->k == K_ANC) {
            g_string_append(g, "\"anc\":{\"did_sdid\":[");
            for (int k = 0; k < s->did_n; k++) {
                g_string_append_printf(g, "%s{\"did\":%u,\"sdid\":%u,\"count\":%u}", k ? "," : "", s->did_sdid[k] >> 8, s->did_sdid[k] & 0xff, s->did_cnt[k]);
                const char *what = s->did_sdid[k] == 0x6060 ? "Timecode (ATC, ST 12-2)" : s->did_sdid[k] == 0x6101 ? "Untertitel (CEA-708)" :
                                   s->did_sdid[k] == 0x6102 ? "Untertitel (CEA-608)" : s->did_sdid[k] == 0x4105 ? "AFD/Bar Data" : NULL;
                if (what) add_finding(f, &nf, 0, "%s enthalten.", what);
            }
            g_string_append(g, "]},");
        }
        g_string_append(g, "\"findings\":[");
        for (int k = 0; k < nf; k++) {
            if (k) g_string_append_c(g, ',');
            g_string_append_printf(g, "{\"level\":%d,\"text\":", f[k].level);
            js_str(g, f[k].text);
            g_string_append_c(g, '}');
        }
        g_string_append(g, "]}");
    }
    g_string_append(g, "],\"ptp\":[");
    for (int i = 0; i < a->n_ptp; i++) {
        ptp_domain *d = &a->ptp[i];
        double dd = d->last_t - d->first_t;
        char gm[32] = "";
        if (d->have_gm) snprintf(gm, sizeof gm, "%02X-%02X-%02X-%02X-%02X-%02X-%02X-%02X", d->gm[0], d->gm[1], d->gm[2], d->gm[3], d->gm[4], d->gm[5], d->gm[6], d->gm[7]);
        g_string_append_printf(g, "%s{\"domain\":%d,\"grandmaster\":\"%s\",\"masters\":%d,\"announce\":%llu,\"sync\":%llu,\"follow_up\":%llu,"
                                  "\"delay_req\":%llu,\"delay_resp\":%llu,\"two_step\":%s,\"priority1\":%d,\"priority2\":%d,\"clock_class\":%d,"
                                  "\"clock_accuracy\":%d,\"time_source\":%d,\"utc_offset\":%d,\"steps_removed\":%d,\"sync_rate\":",
                               i ? "," : "", d->domain, gm, d->n_masters, (unsigned long long)d->announce, (unsigned long long)d->sync,
                               (unsigned long long)d->follow_up, (unsigned long long)d->delay_req, (unsigned long long)d->delay_resp,
                               d->two_step ? "true" : "false", d->priority1, d->priority2, d->clock_class, d->clock_accuracy,
                               d->time_source, d->utc_offset, d->steps_removed);
        js_num(g, dd > 0 ? d->sync / dd : 0);
        g_string_append(g, ",\"announce_rate\":");
        js_num(g, dd > 0 ? d->announce / dd : 0);
        g_string_append_c(g, '}');
    }
    char q[32];
    ipstr(a->querier, q, sizeof q);
    g_string_append_printf(g, "],\"igmp\":{\"queries\":%llu,\"v3_queries\":%llu,\"querier\":\"%s\",\"groups\":[",
                           (unsigned long long)a->igmp_queries, (unsigned long long)a->igmp_v3_queries, a->igmp_queries ? q : "");
    for (int i = 0; i < a->n_groups; i++) {
        char gs[32];
        ipstr(a->groups[i].group, gs, sizeof gs);
        g_string_append_printf(g, "%s{\"group\":\"%s\",\"joins\":%llu,\"leaves\":%llu}", i ? "," : "", gs,
                               (unsigned long long)a->groups[i].joins, (unsigned long long)a->groups[i].leaves);
    }
    g_string_append(g, "]}}");
    a->json = g_string_free(g, FALSE);
}

st_analysis *st_analyze_file(const char *path, const char *const *sdps, st_progress_fn prog, void *user, char *err, size_t el)
{
    FILE *f = fopen(path, "rb");
    if (!f) { snprintf(err, el, "Datei nicht lesbar: %s", path); return NULL; }
    struct stat sb;
    long fsize = stat(path, &sb) == 0 ? (long)sb.st_size : 0;
    uint8_t hdr[24];
    if (fread(hdr, 1, 24, f) != 24) { fclose(f); snprintf(err, el, "Datei zu kurz."); return NULL; }
    st_analysis *a = calloc(1, sizeof *a);
    if (sdps) {
        for (int i = 0; sdps[i] && a->n_sdps < 32; i++) {
            st_sdp_media m[8];
            char e[128];
            int n = st_sdp_parse(sdps[i], m, 8, e, sizeof e);
            for (int k = 0; k < n && a->n_sdps < 32; k++) a->sdps[a->n_sdps++] = m[k];
        }
    }
    int rc;
    if (rd32le(hdr) == 0x0A0D0D0A) {
        fseek(f, 0, SEEK_SET);
        rc = read_pcapng(a, f, fsize, prog, user, err, el);
    } else {
        rc = read_pcap(a, f, hdr, fsize, prog, user, err, el);
    }
    fclose(f);
    if (rc != 0) { st_analysis_free(a); return NULL; }
    if (a->total_packets == 0) { snprintf(err, el, "Der Mitschnitt enthält keine Pakete."); st_analysis_free(a); return NULL; }
    build_json(a);
    if (prog) prog(user, 1.0);
    return a;
}

const char *st_analysis_json(st_analysis *a) { return a ? a->json : NULL; }

int st_analysis_thumbnail(st_analysis *a, int idx, uint8_t *out, int tw, int th)
{
    if (!a || idx < 0 || idx >= a->n_streams) return -1;
    stream *s = a->streams[idx];
    if (s->thumb_state != 2 || !s->thumb_buf || s->pgroup != 5) return -1;
    size_t lb = (size_t)s->thumb_w / 2 * 5;
    for (int y = 0; y < th; y++) {
        int sy = y * s->thumb_h / th;
        const uint8_t *row = s->thumb_buf + (size_t)sy * lb;
        for (int x = 0; x < tw; x++) {
            int sx = (x * s->thumb_w / tw) & ~1;
            const uint8_t *p = row + (size_t)(sx / 2) * 5;
            uint64_t v = (uint64_t)p[0] << 32 | (uint64_t)p[1] << 24 | (uint64_t)p[2] << 16 | (uint64_t)p[3] << 8 | p[4];
            double Y = ((int)((v >> 20) & 0x3ff) - 64) / 876.0, Cb = ((int)((v >> 30) & 0x3ff) - 512) / 896.0, Cr = ((int)((v >> 10) & 0x3ff) - 512) / 896.0;
            double R = Y + 1.5748 * Cr, G = Y - 0.187324 * Cb - 0.468124 * Cr, B = Y + 1.8556 * Cb;
            uint8_t *o = out + ((size_t)y * (size_t)tw + (size_t)x) * 4;
            o[0] = (uint8_t)lround(fmin(1, fmax(0, B)) * 255);
            o[1] = (uint8_t)lround(fmin(1, fmax(0, G)) * 255);
            o[2] = (uint8_t)lround(fmin(1, fmax(0, R)) * 255);
            o[3] = 255;
        }
    }
    return 0;
}

static void series_free(series *s) { free(s->t); free(s->v); }

void st_analysis_free(st_analysis *a)
{
    if (!a) return;
    for (int i = 0; i < a->n_streams; i++) {
        stream *s = a->streams[i];
        free(s->arr);
        free(s->thumb_buf);
        series_free(&s->s_latency); series_free(&s->s_cinst); series_free(&s->s_vrx);
        series_free(&s->s_pkts); series_free(&s->s_iat); series_free(&s->s_tsdf);
        free(s);
    }
    g_free(a->json);
    free(a);
}
