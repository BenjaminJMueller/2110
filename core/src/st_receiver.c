/*
 * Empfangspipeline für ST 2110-20 Video und ST 2110-30 Audio auf Basis von
 * GStreamer.
 *
 *  Video: [eigener Socket] udpsrc ─(Sonde: Statistik, Zeitbezug)─ queue
 *         ─ rtpvrawdepay ─ queue ─ appsink (sync) ─> Callback (Metal)
 *  Audio: [eigener Socket] udpsrc ─(Sonde)─ queue ─ rtpL24depay ─ audioconvert
 *         ─ F32 ─(Sonde: Pegel, Kanalwahl)─ audioconvert(mix-matrix → 2 ch)
 *         ─ volume ─ audioconvert ─ audioresample ─ osxaudiosink (sync)
 *
 * Synchronisation: In den Betriebsarten „RTP-abgestimmt“ und „PTP“ setzt die
 * Sonde den Präsentationszeitstempel (PTS) jedes Pakets aus seinem RTP-Zeit-
 * stempel. Beide Ströme werden damit auf die gemeinsame Aufnahmezeit des
 * Senders bezogen und mit derselben festen Latenz ausgegeben.
 */
#include "st2110core.h"
#include "st_internal.h"

#include <gio/gio.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/net/gstptpclock.h>
#include <gst/video/video.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#define NS_PER_MS 1000000LL

/* ------------------------------------------------------------------ */

typedef struct {
    uint64_t packets, bytes, lost, reordered, wrong_pt, frames;
    int have_seq;
    uint16_t last_seq;
    uint32_t ssrc;
    int have_ssrc;
    uint32_t last_ts;
    int have_ts;
    int64_t last_packet_us;    /* g_get_monotonic_time */
    double fps;                /* aus RTP-Zeitstempeln */
    /* Video-Formaterkennung */
    int cur_max_line, cur_max_pix, cur_interlace;
    int seen_w, seen_h, seen_interlace;
    int mismatch_count;
    int mismatch_reported;
    /* Zeitbezug */
    uint32_t map_ts;
    int have_map;
    uint64_t map_pts;
    int64_t transit_min;       /* Fenster-Minimum (ns) */
    int64_t transit_show;
    int64_t transit_win_start_us;
    /* Audio */
    int payload_bytes;
    double ptime_ms;
    /* Raten */
    uint64_t rate_bytes_prev;
    int64_t rate_t_prev;
    double rate_mbps;
} stream_stats;

struct st_receiver {
    st_receiver_config cfg;
    st_callbacks cb;

    GstElement *pipeline;
    GstElement *vsink, *asink, *volume;
    GstClock *clock;          /* Pipeline-Uhr */
    GstClock *ptp_clock;      /* nur PTP-Betrieb */
    int vfd, afd;
    int rcvbuf;

    GMutex lock;
    stream_stats vs, as;
    st_offset_tracker tracker;
    GstClockTime base_time;
    int running;
    st_sync_mode active;
    st_state state;
    int64_t start_us;
    int pixfmt;               /* ST_PIXFMT_* */
    int pgroup;               /* Byte je pgroup */

    /* Audio */
    int a_channels;
    int a_bytes_per_sample;
    gint mon_left, mon_right; /* atomar */
    float peak[ST_MAX_AUDIO_CHANNELS];
    int64_t peak_t_us;

    /* Überwachung */
    GThread *monitor;
    gint monitor_stop;

    /* Demo */
    uint64_t demo_frame;

    /* PTP-Diagnose */
    int ptp_enabled, ptp_synced, ptp_domain, ptp_domains_seen;
    char ptp_gm[ST_STR_SHORT], ptp_master[ST_STR_SHORT];
    double ptp_path_delay_us, ptp_rsq;
    uint64_t frame_counter;

    /* Latenzüberwachung: Ankunft an der Senke relativ zum PTS */
    int64_t lat_ns;
    int64_t v_late_win, a_late_win, v_late_show, a_late_show;
    int64_t late_win_start_us;
    int lat_raised;
    int ptp_far_count;        /* Pakete mit unplausiblem PTP-Abstand */
    int ptp_fallback_pending;
    double ptp_far_seconds;

    /* Lippensynchron-Messung (Blitz/Ton-Einsatz) */
    int a_rate;
    uint64_t silent_run;
    int flash_bright;
    GstVideoInfo sync_vinfo;
    int sync_vinfo_ok;
    uint64_t last_flash, last_onset;
    int last_flash_valid, last_onset_valid, last_flash_used, last_onset_used;
    uint64_t sync_n, flashes, onsets;
    double sync_last_ms, sync_avg_ms;
};

/* ------------------------------------------------------------------ */
/* Allgemeines                                                        */
/* ------------------------------------------------------------------ */

static gboolean g_inited = FALSE;

int st_init(char *err, size_t err_len)
{
    if (g_inited) return 0;
    GError *e = NULL;
    if (!gst_init_check(NULL, NULL, &e)) {
        snprintf(err, err_len, "GStreamer konnte nicht gestartet werden: %s", e ? e->message : "?");
        if (e) g_error_free(e);
        return -1;
    }
    g_inited = TRUE;
    return 0;
}

const char *st_gstreamer_version(void)
{
    static char buf[64];
    guint a, b, c, d;
    gst_version(&a, &b, &c, &d);
    snprintf(buf, sizeof buf, "%u.%u.%u", a, b, c);
    return buf;
}

int st_check_plugins(char *missing, size_t len)
{
    static const char *need[] = {
        "udpsrc", "queue", "rtpvrawdepay", "rtpL24depay", "rtpL16depay", "appsink",
        "audioconvert", "audioresample", "volume", "capsfilter", "fakesink",
        "videotestsrc", "audiotestsrc", "videoconvert",
#ifdef __APPLE__
        "osxaudiosink",
#endif
        NULL
    };
    int n = 0;
    if (missing && len) missing[0] = '\0';
    for (int i = 0; need[i]; i++) {
        GstElementFactory *f = gst_element_factory_find(need[i]);
        if (!f) {
            n++;
            if (missing) {
                size_t l = strlen(missing);
                snprintf(missing + l, len - l, "%s%s", l ? ", " : "", need[i]);
            }
        } else {
            gst_object_unref(f);
        }
    }
    return n;
}

const char *st_state_name(st_state s)
{
    switch (s) {
    case ST_STATE_STOPPED: return "Gestoppt";
    case ST_STATE_STARTING: return "Startet";
    case ST_STATE_WAITING: return "Warte auf Signal";
    case ST_STATE_RECEIVING: return "Empfang";
    case ST_STATE_STALLED: return "Signal unterbrochen";
    case ST_STATE_ERROR: return "Fehler";
    }
    return "?";
}

const char *st_sync_mode_name(st_sync_mode m)
{
    switch (m) {
    case ST_SYNC_PREVIEW: return "Einfache Vorschau";
    case ST_SYNC_RTP_ALIGNED: return "Zeitlich abgestimmt (RTP)";
    case ST_SYNC_PTP: return "PTP-synchronisiert";
    }
    return "?";
}

static void emit(st_receiver *r, st_event ev, int code, const char *fmt, ...) G_GNUC_PRINTF(4, 5);
static void emit(st_receiver *r, st_event ev, int code, const char *fmt, ...)
{
    if (!r->cb.event) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    r->cb.event(r->cb.user, ev, code, buf);
}

static void set_state(st_receiver *r, st_state s)
{
    g_mutex_lock(&r->lock);
    int changed = r->state != s;
    r->state = s;
    g_mutex_unlock(&r->lock);
    if (changed) emit(r, ST_EVENT_STATE, (int)s, "%s", st_state_name(s));
}

static uint64_t realtime_tai_ns(void)
{
    return (uint64_t)g_get_real_time() * 1000ULL + (uint64_t)ST_TAI_UTC_OFFSET_S * 1000000000ULL;
}

/* ------------------------------------------------------------------ */
/* PTP-Diagnose                                                       */
/* ------------------------------------------------------------------ */

static GMutex g_ptp_lock;
static st_receiver *g_ptp_receiver = NULL;
static gulong g_ptp_cb_id = 0;
static char g_ptp_iface[ST_STR_SHORT] = "";

static void format_clock_id(guint64 id, char *out, size_t len)
{
    snprintf(out, len, "%02X-%02X-%02X-%02X-%02X-%02X-%02X-%02X",
             (unsigned)(id >> 56) & 0xff, (unsigned)(id >> 48) & 0xff, (unsigned)(id >> 40) & 0xff,
             (unsigned)(id >> 32) & 0xff, (unsigned)(id >> 24) & 0xff, (unsigned)(id >> 16) & 0xff,
             (unsigned)(id >> 8) & 0xff, (unsigned)id & 0xff);
}

static gboolean ptp_stats_cb(guint8 domain, const GstStructure *s, gpointer user)
{
    (void)user;
    g_mutex_lock(&g_ptp_lock);
    st_receiver *r = g_ptp_receiver;
    if (r) {
        g_mutex_lock(&r->lock);
        const char *name = gst_structure_get_name(s);
        if (g_str_equal(name, GST_PTP_STATISTICS_NEW_DOMAIN_FOUND)) {
            r->ptp_domains_seen++;
        } else if (domain == r->ptp_domain) {
            if (g_str_equal(name, GST_PTP_STATISTICS_BEST_MASTER_CLOCK_SELECTED)) {
                guint64 gm = 0, master = 0;
                if (gst_structure_get_uint64(s, "grandmaster-clock-id", &gm))
                    format_clock_id(gm, r->ptp_gm, sizeof r->ptp_gm);
                if (gst_structure_get_uint64(s, "master-clock-id", &master))
                    format_clock_id(master, r->ptp_master, sizeof r->ptp_master);
            } else if (g_str_equal(name, GST_PTP_STATISTICS_PATH_DELAY_MEASURED)) {
                guint64 d = 0;
                if (gst_structure_get_uint64(s, "mean-path-delay-avg", &d))
                    r->ptp_path_delay_us = d / 1000.0;
            } else if (g_str_equal(name, GST_PTP_STATISTICS_TIME_UPDATED)) {
                gdouble rsq = 0;
                gboolean synced = FALSE;
                if (gst_structure_get_double(s, "r-squared", &rsq)) r->ptp_rsq = rsq;
                if (gst_structure_get_boolean(s, "synced", &synced)) r->ptp_synced = synced;
                guint64 d = 0;
                if (gst_structure_get_uint64(s, "mean-path-delay-avg", &d))
                    r->ptp_path_delay_us = d / 1000.0;
            }
        }
        g_mutex_unlock(&r->lock);
    }
    g_mutex_unlock(&g_ptp_lock);
    return TRUE;
}

static int ptp_setup(st_receiver *r, char *err, size_t err_len)
{
    const char *iface = r->cfg.iface_name;
    if (gst_ptp_is_initialized() && strcmp(g_ptp_iface, iface) != 0) {
        /* Andere Schnittstelle gewünscht: neu initialisieren. */
        gst_ptp_deinit();
    }
    if (!gst_ptp_is_initialized()) {
        gchar *ifaces[2] = { (gchar *)iface, NULL };
        if (!gst_ptp_init(GST_PTP_CLOCK_ID_NONE, iface[0] ? ifaces : NULL)) {
            snprintf(err, err_len,
                     "Der PTP-Empfang konnte nicht gestartet werden (Hilfsprogramm gst-ptp-helper). "
                     "Möglicherweise sind die UDP-Ports 319/320 belegt oder die Firewall blockiert sie.");
            return -1;
        }
        g_strlcpy(g_ptp_iface, iface, sizeof g_ptp_iface);
    }
    g_mutex_lock(&g_ptp_lock);
    g_ptp_receiver = r;
    if (!g_ptp_cb_id) g_ptp_cb_id = gst_ptp_statistics_callback_add(ptp_stats_cb, NULL, NULL);
    g_mutex_unlock(&g_ptp_lock);
    r->ptp_enabled = 1;
    r->ptp_clock = gst_ptp_clock_new("st-ptp-clock", (guint)r->ptp_domain);
    if (!r->ptp_clock) {
        snprintf(err, err_len, "PTP-Uhr für Domain %d konnte nicht erzeugt werden.", r->ptp_domain);
        return -1;
    }
    return 0;
}

static void ptp_release(st_receiver *r)
{
    g_mutex_lock(&g_ptp_lock);
    if (g_ptp_receiver == r) g_ptp_receiver = NULL;
    g_mutex_unlock(&g_ptp_lock);
    if (r->ptp_clock) {
        gst_object_unref(r->ptp_clock);
        r->ptp_clock = NULL;
    }
}

/* ------------------------------------------------------------------ */
/* RTP-Sonden                                                         */
/* ------------------------------------------------------------------ */

typedef struct {
    int ok;
    int marker;
    int pt;
    uint16_t seq;
    uint32_t ts;
    uint32_t ssrc;
    const uint8_t *payload;
    size_t payload_len;
} rtp_hdr;

static int parse_rtp(const uint8_t *d, size_t n, rtp_hdr *h)
{
    h->ok = 0;
    if (n < 12 || (d[0] >> 6) != 2) return 0;
    size_t off = 12 + 4u * (d[0] & 0x0f);
    if (d[0] & 0x10) {
        if (n < off + 4) return 0;
        size_t xl = ((size_t)d[off + 2] << 8 | d[off + 3]) * 4u;
        off += 4 + xl;
    }
    size_t end = n;
    if (d[0] & 0x20) { /* Padding */
        uint8_t pad = d[n - 1];
        if (pad > n - off) return 0;
        end -= pad;
    }
    if (off > end) return 0;
    h->marker = d[1] >> 7;
    h->pt = d[1] & 0x7f;
    h->seq = (uint16_t)(d[2] << 8 | d[3]);
    h->ts = (uint32_t)d[4] << 24 | (uint32_t)d[5] << 16 | (uint32_t)d[6] << 8 | d[7];
    h->ssrc = (uint32_t)d[8] << 24 | (uint32_t)d[9] << 16 | (uint32_t)d[10] << 8 | d[11];
    h->payload = d + off;
    h->payload_len = end - off;
    h->ok = 1;
    return 1;
}

/* Sequenznummern, SSRC, Payload-Typ. Liefert 1, wenn der Sender neu
 * gestartet zu sein scheint. Aufruf mit gehaltenem Lock. */
static int track_seq(stream_stats *s, const rtp_hdr *h)
{
    int restart = 0;
    if (s->have_ssrc && h->ssrc != s->ssrc) {
        restart = 1;
        s->have_seq = 0;
        s->have_ts = 0;
    }
    s->ssrc = h->ssrc;
    s->have_ssrc = 1;
    if (s->have_seq) {
        uint16_t expected = (uint16_t)(s->last_seq + 1);
        uint16_t diff = (uint16_t)(h->seq - expected);
        if (diff == 0) {
            s->last_seq = h->seq;
        } else if (diff < 0x8000) {
            if (diff > 30000) {
                restart = 1;
            } else {
                s->lost += diff;
            }
            s->last_seq = h->seq;
        } else {
            s->reordered++;
            if (s->lost > 0) s->lost--; /* verspätetes Paket war als verloren gezählt */
        }
    } else {
        s->last_seq = h->seq;
        s->have_seq = 1;
    }
    return restart;
}

static void update_transit(stream_stats *s, int64_t transit, int64_t now_us)
{
    if (s->transit_win_start_us == 0 || transit < s->transit_min) s->transit_min = transit;
    if (s->transit_win_start_us == 0) s->transit_win_start_us = now_us;
    if (now_us - s->transit_win_start_us > 1000000) {
        s->transit_show = s->transit_min;
        s->transit_min = INT64_MAX;
        s->transit_win_start_us = now_us;
    }
}

/* Berechnet den PTS für einen RTP-Zeitstempel. Rückgabe 0 = verwerfen. */
static int map_timestamp(st_receiver *r, stream_stats *s, uint32_t ts, uint32_t rate,
                         GstClockTime *pts_out, int *resynced)
{
    GstClockTime now = gst_clock_get_time(r->clock);
    if (now == GST_CLOCK_TIME_NONE || now < r->base_time) return 0;
    uint64_t arrival_rt = now - r->base_time;
    int64_t now_us = g_get_monotonic_time();

    uint64_t media_ref = (r->active == ST_SYNC_PTP) ? (uint64_t)now : realtime_tai_ns();
    uint64_t capture = st_ticks_to_ns(st_rtp_unwrap(ts, rate, media_ref), rate);

    if (r->active == ST_SYNC_PTP) {
        int64_t transit = (int64_t)now - (int64_t)capture;
        if (transit > 1000 * NS_PER_MS || transit < -1000 * NS_PER_MS) {
            /* Aufnahmezeit liegt > 1 s neben der PTP-Zeit: Der Sender stempelt
             * offenbar nicht mit diesem Grandmaster (andere Domain, nicht
             * gelockt, UTC statt TAI). Auf RTP-Abstimmung zurückfallen. */
            if (++r->ptp_far_count >= 50) {
                r->active = ST_SYNC_RTP_ALIGNED;
                r->ptp_fallback_pending = 1;
                r->ptp_far_seconds = (double)transit / 1e9;
            }
            return 0;
        }
        r->ptp_far_count = 0;
        if (capture < r->base_time) return 0;
        uint64_t pts = capture - r->base_time;
        update_transit(s, (int64_t)arrival_rt - (int64_t)pts, now_us);
        *pts_out = pts;
        return 1;
    }
    int64_t delta = (int64_t)arrival_rt - (int64_t)capture;
    int snapped = st_offset_update(&r->tracker, delta, arrival_rt);
    if (snapped && r->tracker.resyncs > 0 && resynced) *resynced = 1;
    int64_t pts = (int64_t)capture + r->tracker.offset;
    update_transit(s, (int64_t)arrival_rt - pts, now_us);
    if (r->active == ST_SYNC_PREVIEW) {
        *pts_out = GST_CLOCK_TIME_NONE; /* nicht verändern */
        return 1;
    }
    if (pts < 0) return 0;
    *pts_out = (GstClockTime)pts;
    return 1;
}

static GstPadProbeReturn video_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;
    rtp_hdr h;
    int valid = parse_rtp(map.data, map.size, &h);
    stream_stats *s = &r->vs;
    int restart = 0, resynced = 0, drop = 0;
    int mismatch = 0, interlace_new = 0;
    int seen_w = 0, seen_h = 0;
    GstClockTime pts = GST_CLOCK_TIME_NONE;

    g_mutex_lock(&r->lock);
    s->packets++;
    s->bytes += map.size;
    s->last_packet_us = g_get_monotonic_time();
    if (!valid) {
        drop = 1;
    } else if (r->cfg.video.payload_type >= 0 && h.pt != r->cfg.video.payload_type) {
        s->wrong_pt++;
        drop = 1;
    } else {
        restart = track_seq(s, &h);
        int new_frame = !s->have_ts || h.ts != s->last_ts;
        if (new_frame) {
            if (s->have_ts) {
                uint32_t d = h.ts - s->last_ts;
                if (d > 0 && d < 90000) {
                    double f = 90000.0 / d;
                    s->fps = s->fps <= 0 ? f : s->fps * 0.9 + f * 0.1;
                }
                /* Formaterkennung des abgeschlossenen Bildes */
                if (s->cur_max_line > 0) {
                    s->seen_w = s->cur_max_pix;
                    s->seen_h = s->cur_max_line;
                    if (s->cur_interlace && !s->seen_interlace) interlace_new = 1;
                    s->seen_interlace = s->cur_interlace;
                    int lines = s->cur_interlace ? s->seen_h * 2 : s->seen_h;
                    if ((s->seen_w != r->cfg.video.width && s->seen_w > 0) ||
                        (lines != r->cfg.video.height && lines > 0)) {
                        s->mismatch_count++;
                        if (s->mismatch_count == 3 && !s->mismatch_reported) {
                            s->mismatch_reported = 1;
                            mismatch = 1;
                            seen_w = s->seen_w;
                            seen_h = lines;
                        }
                    } else {
                        s->mismatch_count = 0;
                    }
                }
            }
            s->cur_max_line = 0;
            s->cur_max_pix = 0;
            s->cur_interlace = 0;
            s->have_ts = 1;
            s->last_ts = h.ts;
            if (map_timestamp(r, s, h.ts, 90000, &pts, &resynced)) {
                s->map_ts = h.ts;
                s->map_pts = pts;
                s->have_map = 1;
            } else {
                s->have_map = 0;
            }
        } else if (s->have_map) {
            pts = s->map_pts;
        }
        if (h.marker) s->frames++;
        /* RFC 4175 Nutzlastkopf: ESN (2 Byte), danach SRD-Köpfe à 6 Byte */
        if (h.payload_len >= 8) {
            const uint8_t *p = h.payload + 2;
            const uint8_t *end = h.payload + h.payload_len;
            for (int guard = 0; guard < 16 && p + 6 <= end; guard++) {
                int length = p[0] << 8 | p[1];
                int field = p[2] >> 7;
                int line = (p[2] & 0x7f) << 8 | p[3];
                int cont = p[4] >> 7;
                int offset = (p[4] & 0x7f) << 8 | p[5];
                if (field) s->cur_interlace = 1;
                if (line + 1 > s->cur_max_line) s->cur_max_line = line + 1;
                int pix = offset + (r->pgroup > 0 ? length / r->pgroup * 2 : 0);
                if (pix > s->cur_max_pix) s->cur_max_pix = pix;
                p += 6;
                if (!cont) break;
            }
        }
        if (r->active != ST_SYNC_PREVIEW && pts == GST_CLOCK_TIME_NONE) drop = 1;
    }
    g_mutex_unlock(&r->lock);
    gst_buffer_unmap(buf, &map);

    if (restart) emit(r, ST_EVENT_SENDER_RESTART, 0, "Video: Der Sender wurde vermutlich neu gestartet (neue SSRC oder Sequenzsprung).");
    if (resynced) emit(r, ST_EVENT_WARNING, 1, "Zeitbezug neu ausgerichtet (Sprung in den Zeitstempeln).");
    if (interlace_new) emit(r, ST_EVENT_FORMAT_MISMATCH, 2, "Der Sender überträgt Halbbilder (Zeilensprung). Dieses Format wird nicht unterstützt. Abhilfe: am SDI-Quellgerät ein progressives Format (z. B. 1080p25/1080p50) einstellen.");
    if (mismatch) emit(r, ST_EVENT_FORMAT_MISMATCH, 1,
                       "Empfangenes Bild %d×%d passt nicht zur SDP (%d×%d). Vermutlich hat der Sender das Format geändert – bitte SDP neu laden.",
                       seen_w, seen_h, r->cfg.video.width, r->cfg.video.height);
    if (drop) return GST_PAD_PROBE_DROP;
    if (r->active != ST_SYNC_PREVIEW && pts != GST_CLOCK_TIME_NONE) {
        buf = gst_buffer_make_writable(buf);
        GST_BUFFER_PTS(buf) = pts;
        GST_BUFFER_DTS(buf) = GST_CLOCK_TIME_NONE;
        GST_PAD_PROBE_INFO_DATA(info) = buf;
    }
    return GST_PAD_PROBE_OK;
}

static GstPadProbeReturn audio_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;
    rtp_hdr h;
    int valid = parse_rtp(map.data, map.size, &h);
    stream_stats *s = &r->as;
    int restart = 0, resynced = 0, drop = 0, bad_size = 0;
    GstClockTime pts = GST_CLOCK_TIME_NONE;

    g_mutex_lock(&r->lock);
    s->packets++;
    s->bytes += map.size;
    s->last_packet_us = g_get_monotonic_time();
    if (!valid) {
        drop = 1;
    } else if (r->cfg.audio.payload_type >= 0 && h.pt != r->cfg.audio.payload_type) {
        s->wrong_pt++;
        drop = 1;
    } else {
        restart = track_seq(s, &h);
        s->payload_bytes = (int)h.payload_len;
        int frame_bytes = r->a_channels * r->a_bytes_per_sample;
        if (frame_bytes > 0) {
            if (h.payload_len % (size_t)frame_bytes != 0) {
                s->mismatch_count++;
                if (s->mismatch_count == 10 && !s->mismatch_reported) {
                    s->mismatch_reported = 1;
                    bad_size = 1;
                }
                drop = 1;
            } else {
                s->ptime_ms = (double)(h.payload_len / (size_t)frame_bytes) * 1000.0 / r->cfg.audio.clock_rate;
            }
        }
        if (!drop) {
            if (!map_timestamp(r, s, h.ts, (uint32_t)r->cfg.audio.clock_rate, &pts, &resynced)) drop = 1;
            else if (r->active != ST_SYNC_PREVIEW && pts == GST_CLOCK_TIME_NONE) drop = 1;
        }
        s->have_ts = 1;
        s->last_ts = h.ts;
    }
    g_mutex_unlock(&r->lock);
    gst_buffer_unmap(buf, &map);

    if (restart) emit(r, ST_EVENT_SENDER_RESTART, 0, "Audio: Der Sender wurde vermutlich neu gestartet (neue SSRC oder Sequenzsprung).");
    if (resynced) emit(r, ST_EVENT_WARNING, 1, "Zeitbezug neu ausgerichtet (Sprung in den Zeitstempeln).");
    if (bad_size) emit(r, ST_EVENT_FORMAT_MISMATCH, 3,
                       "Die Audiopakete (%d Byte Nutzlast) passen nicht zu %d Kanälen à %d Bit laut SDP. Vermutlich stimmen Kanalzahl oder Format nicht – bitte SDP neu laden.",
                       (int)h.payload_len, r->a_channels, r->a_bytes_per_sample * 8);
    if (drop) return GST_PAD_PROBE_DROP;
    if (r->active != ST_SYNC_PREVIEW && pts != GST_CLOCK_TIME_NONE) {
        buf = gst_buffer_make_writable(buf);
        GST_BUFFER_PTS(buf) = pts;
        GST_BUFFER_DTS(buf) = GST_CLOCK_TIME_NONE;
        GST_BUFFER_DURATION(buf) = GST_CLOCK_TIME_NONE;
        GST_PAD_PROBE_INFO_DATA(info) = buf;
    }
    return GST_PAD_PROBE_OK;
}


/* Paart Blitz- und Ton-Ereignisse (innerhalb ±500 ms) und misst den Abstand.
 * Aufruf mit gehaltenem Lock. */
static void sync_event(st_receiver *r, int is_video, uint64_t t)
{
    const int64_t win = 500 * NS_PER_MS;
    if (is_video) {
        r->flashes++;
        r->last_flash = t;
        r->last_flash_valid = 1;
        r->last_flash_used = 0;
        if (r->last_onset_valid && !r->last_onset_used &&
            llabs((int64_t)r->last_onset - (int64_t)t) < win) {
            r->last_onset_used = r->last_flash_used = 1;
            goto record;
        }
        return;
    } else {
        r->onsets++;
        r->last_onset = t;
        r->last_onset_valid = 1;
        r->last_onset_used = 0;
        if (r->last_flash_valid && !r->last_flash_used &&
            llabs((int64_t)r->last_flash - (int64_t)t) < win) {
            r->last_onset_used = r->last_flash_used = 1;
            goto record;
        }
        return;
    }
record:;
    double d = ((double)(int64_t)(r->last_onset - r->last_flash)) / 1e6;
    r->sync_last_ms = d;
    if (r->sync_n < 20) r->sync_avg_ms = (r->sync_avg_ms * (double)r->sync_n + d) / (double)(r->sync_n + 1);
    else r->sync_avg_ms = r->sync_avg_ms * 0.9 + d * 0.1;
    r->sync_n++;
}

/* Verspätung eines Puffers an der Senke: Laufzeit jetzt - PTS. Lock nötig. */
static void note_lateness(st_receiver *r, GstClockTime pts, int video)
{
    if (!r->clock || pts == GST_CLOCK_TIME_NONE) return;
    GstClockTime now = gst_clock_get_time(r->clock);
    if (now < r->base_time) return;
    int64_t late = (int64_t)(now - r->base_time) - (int64_t)pts;
    if (video) { if (late > r->v_late_win) r->v_late_win = late; }
    else if (late > r->a_late_win) r->a_late_win = late;
}

/* Gemessen direkt hinter dem Depayloader: Zeitpunkt, zu dem ein Bild bzw.
 * Audioblock vollständig vorliegt, relativ zu seinem PTS. (Am Senkeneingang
 * wäre die Messung wertlos, weil die Senke bis zum Ausgabezeitpunkt blockiert.) */
static GstPadProbeReturn late_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user, int video)
{
    (void)pad;
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    g_mutex_lock(&r->lock);
    note_lateness(r, GST_BUFFER_PTS(buf), video);
    g_mutex_unlock(&r->lock);
    return GST_PAD_PROBE_OK;
}
static GstPadProbeReturn vlate_probe(GstPad *p, GstPadProbeInfo *i, gpointer u) { return late_probe(p, i, u, 1); }
static GstPadProbeReturn alate_probe(GstPad *p, GstPadProbeInfo *i, gpointer u) { return late_probe(p, i, u, 0); }

/* Mittlere Luma (10-Bit-Skala) eines 32×32-Blocks in der Bildmitte. */
static int center_luma(const uint8_t *data, int stride, int w, int h, int uyvp)
{
    long sum = 0;
    int cnt = 0;
    int x0 = (w / 2 - 16) & ~1, y0 = h / 2 - 16;
    for (int y = y0; y < y0 + 32; y++) {
        const uint8_t *row = data + (size_t)y * (size_t)stride;
        for (int x = x0; x < x0 + 32; x += 2) {
            if (uyvp) {
                const uint8_t *p = row + (size_t)(x / 2) * 5;
                uint64_t v = (uint64_t)p[0] << 32 | (uint64_t)p[1] << 24 | (uint64_t)p[2] << 16 | (uint64_t)p[3] << 8 | p[4];
                sum += (long)((v >> 20) & 0x3ff) + (long)(v & 0x3ff);
            } else {
                const uint8_t *p = row + (size_t)(x / 2) * 4;
                sum += ((long)p[1] + (long)p[3]) * 4;
            }
            cnt += 2;
        }
    }
    return cnt ? (int)(sum / cnt) : 0;
}

static GstPadProbeReturn vsink_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf || GST_BUFFER_PTS(buf) == GST_CLOCK_TIME_NONE) return GST_PAD_PROBE_OK;
    if (!r->sync_vinfo_ok) {
        GstCaps *caps = gst_pad_get_current_caps(pad);
        if (caps) {
            r->sync_vinfo_ok = gst_video_info_from_caps(&r->sync_vinfo, caps);
            gst_caps_unref(caps);
        }
        if (!r->sync_vinfo_ok) return GST_PAD_PROBE_OK;
    }
    GstVideoInfo *vi = &r->sync_vinfo;
    int w = GST_VIDEO_INFO_WIDTH(vi), h = GST_VIDEO_INFO_HEIGHT(vi);
    if (w < 64 || h < 64) return GST_PAD_PROBE_OK;
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;
    int stride = GST_VIDEO_INFO_PLANE_STRIDE(vi, 0);
    int luma = 0;
    if ((size_t)stride * (size_t)h <= map.size)
        luma = center_luma(map.data, stride, w, h, GST_VIDEO_INFO_FORMAT(vi) == GST_VIDEO_FORMAT_UYVP);
    gst_buffer_unmap(buf, &map);
    int bright = luma >= 700;
    g_mutex_lock(&r->lock);
    if (bright && !r->flash_bright) sync_event(r, 1, GST_BUFFER_PTS(buf));
    r->flash_bright = bright;
    g_mutex_unlock(&r->lock);
    return GST_PAD_PROBE_OK;
}

/* Pegelmessung und Kanalwahl auf F32-Daten mit N Kanälen. Die gewählten
 * Kanäle werden auf Position 0 und 1 kopiert; die nachfolgende Mix-Matrix
 * gibt nur diese beiden Kanäle aus. So lässt sich die Abhörauswahl ohne
 * Neuaufbau der Pipeline umschalten. */
static GstPadProbeReturn pcm_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    int n = r->a_channels;
    if (n <= 0) return GST_PAD_PROBE_OK;
    buf = gst_buffer_make_writable(buf);
    GST_PAD_PROBE_INFO_DATA(info) = buf;
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READWRITE)) return GST_PAD_PROBE_OK;
    float *smp = (float *)map.data;
    size_t frames = map.size / (sizeof(float) * (size_t)n);
    float pk[ST_MAX_AUDIO_CHANNELS] = {0};
    GstClockTime bpts = GST_BUFFER_PTS(buf);
    uint64_t onset = 0;
    int have_onset = 0;
    int rate = r->a_rate > 0 ? r->a_rate : 48000;
    int L = g_atomic_int_get(&r->mon_left);
    int R = g_atomic_int_get(&r->mon_right);
    if (L < 0 || L >= n) L = 0;
    if (R >= n) R = -1;
    for (size_t f = 0; f < frames; f++) {
        float *fr = smp + f * (size_t)n;
        float amax = 0;
        for (int c = 0; c < n; c++) {
            float a = fabsf(fr[c]);
            if (a > pk[c]) pk[c] = a;
            if (a > amax) amax = a;
        }
        if (amax < 0.01f) {
            r->silent_run++;
        } else if (amax >= 0.1f) {
            /* Einsatz nach mindestens 150 ms Stille (−40 dBFS), Schwelle −20 dBFS */
            if (r->silent_run >= (uint64_t)rate * 15 / 100 && !have_onset && bpts != GST_CLOCK_TIME_NONE) {
                onset = bpts + gst_util_uint64_scale(f, GST_SECOND, (guint64)rate);
                have_onset = 1;
            }
            r->silent_run = 0;
        }
        if (n >= 2) {
            float l = fr[L];
            float rr = (R >= 0) ? fr[R] : l;
            fr[0] = l;
            fr[1] = rr;
        }
    }
    gst_buffer_unmap(buf, &map);
    g_mutex_lock(&r->lock);
    for (int c = 0; c < n && c < ST_MAX_AUDIO_CHANNELS; c++)
        if (pk[c] > r->peak[c]) r->peak[c] = pk[c];
    if (have_onset) sync_event(r, 0, onset);
    g_mutex_unlock(&r->lock);
    return GST_PAD_PROBE_OK;
}

/* ------------------------------------------------------------------ */
/* Demo-Modus: Blitz + Laufbalken in UYVP malen                        */
/* ------------------------------------------------------------------ */

static void uyvp_fill(uint8_t *data, int stride, int x0, int y0, int w, int h,
                      int Y, int Cb, int Cr, int width, int height)
{
    /* pgroup (5 Byte): Cb(10) Y0(10) Cr(10) Y1(10), big-endian Bitfolge */
    uint64_t v = ((uint64_t)Cb << 30) | ((uint64_t)Y << 20) | ((uint64_t)Cr << 10) | (uint64_t)Y;
    uint8_t pg[5] = { (uint8_t)(v >> 32), (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    x0 &= ~1;
    for (int y = y0; y < y0 + h && y < height; y++) {
        if (y < 0) continue;
        uint8_t *row = data + (size_t)y * (size_t)stride;
        for (int x = x0; x < x0 + w && x + 1 < width; x += 2) {
            if (x < 0) continue;
            memcpy(row + (size_t)(x / 2) * 5, pg, 5);
        }
    }
}

static GstPadProbeReturn demo_video_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    st_receiver *r = user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    buf = gst_buffer_make_writable(buf);
    GST_PAD_PROBE_INFO_DATA(info) = buf;
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READWRITE)) return GST_PAD_PROBE_OK;
    int w = 1920, h = 1080;
    int stride = (w / 2) * 5;
    int fps = r->cfg.demo_fps > 0 ? r->cfg.demo_fps : 25;
    GstClockTime pts = GST_BUFFER_PTS(buf);
    uint64_t frame = (pts != GST_CLOCK_TIME_NONE) ? gst_util_uint64_scale(pts, (guint64)fps, GST_SECOND) : r->demo_frame;
    r->demo_frame = frame + 1;
    if ((size_t)stride * (size_t)h <= map.size) {
        /* Laufbalken unten: eine Sekunde = ein Durchlauf */
        int pos = (int)(frame % (uint64_t)fps) * (w - 64) / fps;
        uyvp_fill(map.data, stride, 0, h - 120, w, 40, 64, 512, 512, w, h);
        uyvp_fill(map.data, stride, pos, h - 120, 64, 40, 940, 512, 512, w, h);
        /* Blitz in der Bildmitte zum Sekundenbeginn (zeitgleich mit dem Ton-Tick) */
        if (frame % (uint64_t)fps == 0)
            uyvp_fill(map.data, stride, w / 2 - 200, h / 2 - 200, 400, 400, 940, 512, 512, w, h);
    }
    gst_buffer_unmap(buf, &map);
    return GST_PAD_PROBE_OK;
}

/* ------------------------------------------------------------------ */
/* Senken                                                             */
/* ------------------------------------------------------------------ */

static GstFlowReturn on_new_sample(GstAppSink *sink, gpointer user)
{
    st_receiver *r = user;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;
    GstBuffer *buf = gst_sample_get_buffer(sample);
    GstCaps *caps = gst_sample_get_caps(sample);
    GstVideoInfo vi;
    if (buf && caps && gst_video_info_from_caps(&vi, caps) && r->cb.video_frame) {
        GstVideoFrame vf;
        if (gst_video_frame_map(&vf, &vi, buf, GST_MAP_READ)) {
            st_video_frame f;
            memset(&f, 0, sizeof f);
            f.data = GST_VIDEO_FRAME_PLANE_DATA(&vf, 0);
            f.stride = GST_VIDEO_FRAME_PLANE_STRIDE(&vf, 0);
            f.width = GST_VIDEO_FRAME_WIDTH(&vf);
            f.height = GST_VIDEO_FRAME_HEIGHT(&vf);
            f.size = (size_t)f.stride * (size_t)f.height;
            f.pixfmt = GST_VIDEO_FRAME_FORMAT(&vf) == GST_VIDEO_FORMAT_UYVP ? ST_PIXFMT_UYVP : ST_PIXFMT_UYVY;
            f.colorimetry_bt601 = r->cfg.has_video && strncasecmp(r->cfg.video.colorimetry, "BT601", 5) == 0;
            f.full_range = r->cfg.has_video && strcasecmp(r->cfg.video.range, "FULL") == 0;
            f.pts_ns = GST_BUFFER_PTS(buf);
            f.frame_number = ++r->frame_counter;
            r->cb.video_frame(r->cb.user, &f);
            gst_video_frame_unmap(&vf);
        }
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static GstBusSyncReply bus_sync(GstBus *bus, GstMessage *msg, gpointer user)
{
    (void)bus;
    st_receiver *r = user;
    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError *e = NULL;
        gchar *dbg = NULL;
        gst_message_parse_error(msg, &e, &dbg);
        g_mutex_lock(&r->lock);
        r->state = ST_STATE_ERROR;
        g_mutex_unlock(&r->lock);
        emit(r, ST_EVENT_ERROR, 0, "Fehler in %s: %s",
             GST_OBJECT_NAME(GST_MESSAGE_SRC(msg)), e ? e->message : "?");
        if (e) g_error_free(e);
        g_free(dbg);
        break;
    }
    case GST_MESSAGE_WARNING: {
        GError *e = NULL;
        gchar *dbg = NULL;
        gst_message_parse_warning(msg, &e, &dbg);
        emit(r, ST_EVENT_WARNING, 0, "Hinweis von %s: %s",
             GST_OBJECT_NAME(GST_MESSAGE_SRC(msg)), e ? e->message : "?");
        if (e) g_error_free(e);
        g_free(dbg);
        break;
    }
    default:
        break;
    }
    return GST_BUS_DROP;
}

/* ------------------------------------------------------------------ */
/* Aufbau                                                             */
/* ------------------------------------------------------------------ */

static const char *gst_colorimetry(const st_sdp_media *m)
{
    if (strncasecmp(m->colorimetry, "BT601", 5) == 0) return "BT601-5";
    return "BT709-2";
}

static void append(GString *s, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void append(GString *s, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    g_string_append_vprintf(s, fmt, ap);
    va_end(ap);
}

static void build_audio_tail(st_receiver *r, GString *d)
{
    int n = r->a_channels;
    /* Mix-Matrix: 2 Ausgänge × n Eingänge; Ausgang 0 = Kanal 0, Ausgang 1 = Kanal 1 */
    append(d, " ! audioconvert name=aconv ! audio/x-raw,format=F32LE,layout=interleaved ! identity name=apcm silent=true");
    append(d, " ! audioconvert name=amix mix-matrix=\"<");
    for (int o = 0; o < 2; o++) {
        append(d, "%s<", o ? ", " : "");
        for (int i = 0; i < n; i++) {
            float v = (n == 1) ? 1.0f : (i == o ? 1.0f : 0.0f);
            append(d, "%s(float)%.1f", i ? ", " : "", v);
        }
        append(d, ">");
    }
    append(d, ">\" ! audio/x-raw,channels=2 ! volume name=vol ! audioconvert ! audioresample");
    append(d, " ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000");
    if (r->cfg.audio_null_sink) {
        append(d, " ! fakesink name=asink sync=true");
    } else {
#ifdef __APPLE__
        if (r->cfg.audio_device_id > 0)
            append(d, " ! osxaudiosink name=asink sync=true device=%d", r->cfg.audio_device_id);
        else
            append(d, " ! osxaudiosink name=asink sync=true");
#else
        append(d, " ! autoaudiosink name=asink sync=true");
#endif
    }
}

static gchar *build_description(st_receiver *r)
{
    GString *d = g_string_new(NULL);
    const char *vsink = r->cfg.video_null_sink
        ? "fakesink name=vsink sync=true qos=false max-lateness=40000000"
        : "appsink name=vsink sync=true qos=false max-lateness=40000000 max-buffers=2 drop=true";

    if (r->cfg.demo) {
        int fps = r->cfg.demo_fps > 0 ? r->cfg.demo_fps : 25;
        append(d, "videotestsrc name=dsrc is-live=true pattern=smpte ! videoconvert"
                  " ! video/x-raw,format=UYVP,width=1920,height=1080,framerate=%d/1"
                  " ! identity name=dvid silent=true ! queue max-size-buffers=3 ! %s ", fps, vsink);
        append(d, " audiotestsrc name=asrcd is-live=true wave=ticks tick-interval=1000000000 freq=1000 volume=0.5 samplesperbuffer=480"
                  " ! audio/x-raw,format=F32LE,rate=48000,channels=%d,layout=interleaved", r->a_channels);
        build_audio_tail(r, d);
        return g_string_free(d, FALSE);
    }

    if (r->cfg.has_video) {
        const st_sdp_media *v = &r->cfg.video;
        append(d, "udpsrc name=vsrc caps=\"application/x-rtp,media=video,clock-rate=90000,encoding-name=RAW,"
                  "payload=%d,sampling=%s,depth=(string)%d,width=(string)%d,height=(string)%d,colorimetry=(string)%s\""
                  " ! queue name=vq max-size-buffers=0 max-size-time=200000000 max-size-bytes=0 leaky=downstream"
                  " ! rtpvrawdepay name=vdepay"
                  " ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=1200000000 leaky=downstream ! %s ",
               v->payload_type >= 0 ? v->payload_type : 96, v->sampling, v->depth, v->width, v->height,
               gst_colorimetry(v), vsink);
    }
    if (r->cfg.has_audio) {
        const st_sdp_media *a = &r->cfg.audio;
        int l16 = strcasecmp(a->encoding, "L16") == 0;
        append(d, " udpsrc name=asrc caps=\"application/x-rtp,media=audio,clock-rate=%d,encoding-name=%s,channels=%d,payload=%d\""
                  " ! queue name=aq max-size-buffers=0 max-size-bytes=0 max-size-time=1000000000 leaky=downstream"
                  " ! %s name=adepay",
               a->clock_rate, l16 ? "L16" : "L24", r->a_channels, a->payload_type >= 0 ? a->payload_type : 97,
               l16 ? "rtpL16depay" : "rtpL24depay");
        build_audio_tail(r, d);
    }
    return g_string_free(d, FALSE);
}

static void add_probe(GstElement *pipe, const char *name, const char *pad,
                      GstPadProbeCallback cb, st_receiver *r)
{
    GstElement *e = gst_bin_get_by_name(GST_BIN(pipe), name);
    if (!e) return;
    GstPad *p = gst_element_get_static_pad(e, pad);
    if (p) {
        gst_pad_add_probe(p, GST_PAD_PROBE_TYPE_BUFFER, cb, r, NULL);
        gst_object_unref(p);
    }
    gst_object_unref(e);
}

st_receiver *st_receiver_new(const st_receiver_config *cfg, const st_callbacks *cb,
                             char *err, size_t err_len)
{
    if (st_init(err, err_len) != 0) return NULL;
    if (!cfg->demo && !cfg->has_video && !cfg->has_audio) {
        snprintf(err, err_len, "Weder Video noch Audio ausgewählt.");
        return NULL;
    }
    char msg[512];
    if (!cfg->demo && cfg->has_video && st_check_media(&cfg->video, msg, sizeof msg) == ST_SUPPORT_NO) {
        snprintf(err, err_len, "%s", msg);
        return NULL;
    }
    if (!cfg->demo && cfg->has_audio && st_check_media(&cfg->audio, msg, sizeof msg) == ST_SUPPORT_NO) {
        snprintf(err, err_len, "%s", msg);
        return NULL;
    }
    st_receiver *r = g_new0(st_receiver, 1);
    r->cfg = *cfg;
    if (cb) r->cb = *cb;
    r->vfd = r->afd = -1;
    g_mutex_init(&r->lock);
    st_offset_init(&r->tracker);
    r->mon_left = 0;
    r->mon_right = 1;
    r->state = ST_STATE_STOPPED;
    if (cfg->demo) {
        r->a_channels = cfg->demo_channels > 0 ? cfg->demo_channels : 2;
        r->pixfmt = ST_PIXFMT_UYVP;
        r->pgroup = 5;
    } else {
        r->a_channels = cfg->has_audio ? (cfg->audio.channels > 0 ? cfg->audio.channels : 1) : 0;
        r->a_bytes_per_sample = (cfg->has_audio && strcasecmp(cfg->audio.encoding, "L16") == 0) ? 2 : 3;
        r->pixfmt = (cfg->has_video && cfg->video.depth == 8) ? ST_PIXFMT_UYVY : ST_PIXFMT_UYVP;
        r->pgroup = (cfg->has_video && cfg->video.depth == 8) ? 4 : 5;
    }
    if (r->a_channels > ST_MAX_AUDIO_CHANNELS) r->a_channels = ST_MAX_AUDIO_CHANNELS;
    r->a_rate = (!cfg->demo && cfg->has_audio && cfg->audio.clock_rate > 0) ? cfg->audio.clock_rate : 48000;
    if (r->a_channels < 2) r->mon_right = -1;
    return r;
}

static gpointer monitor_thread(gpointer user)
{
    st_receiver *r = user;
    while (!g_atomic_int_get(&r->monitor_stop)) {
        g_usleep(250000);
        if (g_atomic_int_get(&r->monitor_stop)) break;
        int64_t now = g_get_monotonic_time();
        st_state want;
        g_mutex_lock(&r->lock);
        stream_stats *ss[2] = { &r->vs, &r->as };
        int64_t newest = 0;
        for (int i = 0; i < 2; i++) {
            stream_stats *s = ss[i];
            if (s->last_packet_us > newest) newest = s->last_packet_us;
            if (s->rate_t_prev) {
                double dt = (now - s->rate_t_prev) / 1e6;
                if (dt > 0) s->rate_mbps = (double)(s->bytes - s->rate_bytes_prev) * 8.0 / dt / 1e6;
            }
            s->rate_t_prev = now;
            s->rate_bytes_prev = s->bytes;
        }
        st_state cur = r->state;
        int64_t raise_to = 0;
        if (r->late_win_start_us == 0) r->late_win_start_us = now;
        if (now - r->late_win_start_us >= 1000000) {
            r->v_late_show = r->v_late_win;
            r->a_late_show = r->a_late_win;
            int64_t worst = r->v_late_win > r->a_late_win ? r->v_late_win : r->a_late_win;
            r->v_late_win = r->a_late_win = INT64_MIN;
            r->late_win_start_us = now;
            if (r->cfg.auto_latency && !r->cfg.demo && r->active != ST_SYNC_PREVIEW &&
                worst != INT64_MIN && worst > r->lat_ns - 15 * NS_PER_MS && r->lat_ns < 1000 * NS_PER_MS) {
                int64_t want = worst + 40 * NS_PER_MS;
                want = ((want + 10 * NS_PER_MS - 1) / (10 * NS_PER_MS)) * 10 * NS_PER_MS;
                if (want > 1000 * NS_PER_MS) want = 1000 * NS_PER_MS;
                if (want > r->lat_ns) { r->lat_ns = want; r->lat_raised++; raise_to = want; }
            }
        }
        int ptp_fb = r->ptp_fallback_pending;
        double ptp_far = r->ptp_far_seconds;
        r->ptp_fallback_pending = 0;
        g_mutex_unlock(&r->lock);
        if (ptp_fb)
            emit(r, ST_EVENT_PTP, 2,
                 "Die Zeitstempel des Senders liegen %.1f s neben der PTP-Zeit dieses Grandmasters. Vermutlich ist der Sender nicht auf "
                 "denselben Grandmaster bzw. dieselbe Domain synchronisiert. Wiedergabe läuft jetzt zeitlich abgestimmt (RTP) weiter.",
                 ptp_far);
        if (raise_to && r->pipeline) {
            gst_pipeline_set_latency(GST_PIPELINE(r->pipeline), (GstClockTime)raise_to);
            emit(r, ST_EVENT_WARNING, 2,
                 "Daten kamen später als der Wiedergabepuffer erlaubt. Puffer automatisch auf %d ms erhöht.",
                 (int)(raise_to / NS_PER_MS));
        }
        if (cur == ST_STATE_ERROR || cur == ST_STATE_STOPPED) continue;
        if (r->cfg.demo) want = ST_STATE_RECEIVING;
        else if (newest == 0) want = ST_STATE_WAITING;
        else if (now - newest < 1000000) want = ST_STATE_RECEIVING;
        else want = ST_STATE_STALLED;
        if (want != cur) set_state(r, want);
    }
    return NULL;
}

int st_receiver_start(st_receiver *r, char *err, size_t err_len)
{
    if (r->running) return 0;
    set_state(r, ST_STATE_STARTING);
    r->start_us = g_get_monotonic_time();
    memset(&r->vs, 0, sizeof r->vs);
    memset(&r->as, 0, sizeof r->as);
    st_offset_init(&r->tracker);
    r->sync_vinfo_ok = 0;
    r->ptp_far_count = 0;
    r->ptp_fallback_pending = 0;
    r->silent_run = 0;
    r->flash_bright = 0;
    r->last_flash_valid = r->last_onset_valid = 0;
    r->sync_n = r->flashes = r->onsets = 0;
    r->sync_last_ms = r->sync_avg_ms = 0;
    r->active = r->cfg.demo ? ST_SYNC_PREVIEW : r->cfg.sync_mode;

    /* PTP-Uhr */
    if (!r->cfg.demo && r->cfg.sync_mode == ST_SYNC_PTP) {
        int dom = r->cfg.ptp_domain;
        if (dom < 0) dom = (r->cfg.has_video && r->cfg.video.ptp_domain >= 0) ? r->cfg.video.ptp_domain
                         : (r->cfg.has_audio && r->cfg.audio.ptp_domain >= 0) ? r->cfg.audio.ptp_domain : 127;
        r->ptp_domain = dom;
        char perr[512];
        if (ptp_setup(r, perr, sizeof perr) != 0) {
            emit(r, ST_EVENT_PTP, 0, "%s Es wird ohne PTP zeitlich abgestimmt wiedergegeben.", perr);
            ptp_release(r);
            r->active = ST_SYNC_RTP_ALIGNED;
        } else {
            int timeout = r->cfg.ptp_timeout_ms > 0 ? r->cfg.ptp_timeout_ms : 6000;
            if (!gst_clock_wait_for_sync(r->ptp_clock, (GstClockTime)timeout * GST_MSECOND)) {
                emit(r, ST_EVENT_PTP, 0,
                     "Kein PTP-Grandmaster in Domain %d innerhalb von %d s gefunden. Wiedergabe läuft zeitlich abgestimmt ohne PTP. "
                     "Mögliche Ursachen: kein Grandmaster im Netz, andere Domain, falsche Schnittstelle oder Firewall.",
                     dom, timeout / 1000);
                ptp_release(r);
                r->active = ST_SYNC_RTP_ALIGNED;
            } else {
                emit(r, ST_EVENT_PTP, 1, "PTP-synchronisiert (Domain %d).", dom);
            }
        }
    }

    gchar *desc = build_description(r);
    GError *e = NULL;
    r->pipeline = gst_parse_launch(desc, &e);
    if (!r->pipeline || e) {
        snprintf(err, err_len, "Empfangskette konnte nicht aufgebaut werden: %s", e ? e->message : "?");
        if (e) g_error_free(e);
        g_free(desc);
        if (r->pipeline) { gst_object_unref(r->pipeline); r->pipeline = NULL; }
        ptp_release(r);
        set_state(r, ST_STATE_ERROR);
        return -1;
    }
    g_free(desc);

    /* Sockets */
    if (!r->cfg.demo) {
        struct { int use; const st_sdp_media *m; const char *name; int *fd; } socks[2] = {
            { r->cfg.has_video, &r->cfg.video, "vsrc", &r->vfd },
            { r->cfg.has_audio, &r->cfg.audio, "asrc", &r->afd },
        };
        for (int i = 0; i < 2; i++) {
            if (!socks[i].use) continue;
            const st_sdp_media *m = socks[i].m;
            int got = 0;
            *socks[i].fd = st_socket_open(m->dest_addr, m->port,
                                          r->cfg.use_source_filter ? m->source_addr : NULL,
                                          r->cfg.iface_name, r->cfg.iface_addr,
                                          r->cfg.socket_buffer_bytes, &got, err, err_len);
            if (*socks[i].fd < 0) {
                st_receiver_stop(r);
                set_state(r, ST_STATE_ERROR);
                return -1;
            }
            if (i == 0 || r->rcvbuf == 0) r->rcvbuf = got;
            GError *ge = NULL;
            GSocket *gs = g_socket_new_from_fd(*socks[i].fd, &ge);
            if (!gs) {
                snprintf(err, err_len, "Socket-Übergabe an GStreamer fehlgeschlagen: %s", ge ? ge->message : "?");
                if (ge) g_error_free(ge);
                st_receiver_stop(r);
                set_state(r, ST_STATE_ERROR);
                return -1;
            }
            GstElement *src = gst_bin_get_by_name(GST_BIN(r->pipeline), socks[i].name);
            g_object_set(src, "socket", gs, "close-socket", FALSE, "auto-multicast", FALSE, NULL);
            gst_object_unref(src);
            g_object_unref(gs);
        }
        if (r->cfg.has_video) add_probe(r->pipeline, "vsrc", "src", video_probe, r);
        if (r->cfg.has_audio) add_probe(r->pipeline, "asrc", "src", audio_probe, r);
    } else {
        add_probe(r->pipeline, "dvid", "src", demo_video_probe, r);
    }
    if (r->cfg.demo || r->cfg.has_audio) add_probe(r->pipeline, "apcm", "src", pcm_probe, r);
    if (r->cfg.demo || r->cfg.has_video) add_probe(r->pipeline, "vsink", "sink", vsink_probe, r);
    if (!r->cfg.demo && r->cfg.has_video) add_probe(r->pipeline, "vdepay", "src", vlate_probe, r);
    if (!r->cfg.demo && r->cfg.has_audio) add_probe(r->pipeline, "adepay", "src", alate_probe, r);

    r->vsink = gst_bin_get_by_name(GST_BIN(r->pipeline), "vsink");
    r->asink = gst_bin_get_by_name(GST_BIN(r->pipeline), "asink");
    r->volume = gst_bin_get_by_name(GST_BIN(r->pipeline), "vol");
    if (r->vsink && GST_IS_APP_SINK(r->vsink)) {
        GstAppSinkCallbacks cbs;
        memset(&cbs, 0, sizeof cbs);
        cbs.new_sample = on_new_sample;
        gst_app_sink_set_callbacks(GST_APP_SINK(r->vsink), &cbs, r, NULL);
    }

    /* Uhr und Latenz */
    if (r->active == ST_SYNC_PTP && r->ptp_clock) {
        r->clock = gst_object_ref(r->ptp_clock);
    } else {
        r->clock = gst_system_clock_obtain();
    }
    gst_pipeline_use_clock(GST_PIPELINE(r->pipeline), r->clock);
    int lat = r->cfg.latency_ms > 0 ? r->cfg.latency_ms : 120;
    r->lat_ns = (int64_t)lat * NS_PER_MS;
    r->v_late_win = r->a_late_win = r->v_late_show = r->a_late_show = INT64_MIN;
    r->late_win_start_us = 0;
    r->lat_raised = 0;
    if (!r->cfg.demo) gst_pipeline_set_latency(GST_PIPELINE(r->pipeline), (GstClockTime)lat * GST_MSECOND);

    GstBus *bus = gst_element_get_bus(r->pipeline);
    gst_bus_set_sync_handler(bus, bus_sync, r, NULL);
    gst_object_unref(bus);

    /* Basiszeit selbst festlegen, damit die Sonden sie ab dem ersten Paket kennen. */
    gst_element_set_start_time(r->pipeline, GST_CLOCK_TIME_NONE);
    r->base_time = gst_clock_get_time(r->clock);
    gst_element_set_base_time(r->pipeline, r->base_time);

    r->running = 1;
    if (gst_element_set_state(r->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        snprintf(err, err_len, "Die Empfangskette konnte nicht gestartet werden (z. B. Audioausgabegerät nicht verfügbar).");
        st_receiver_stop(r);
        set_state(r, ST_STATE_ERROR);
        return -1;
    }
    g_atomic_int_set(&r->monitor_stop, 0);
    r->monitor = g_thread_new("st-monitor", monitor_thread, r);
    set_state(r, r->cfg.demo ? ST_STATE_RECEIVING : ST_STATE_WAITING);
    return 0;
}

void st_receiver_stop(st_receiver *r)
{
    if (r->monitor) {
        g_atomic_int_set(&r->monitor_stop, 1);
        g_thread_join(r->monitor);
        r->monitor = NULL;
    }
    if (r->pipeline) {
        gst_element_set_state(r->pipeline, GST_STATE_NULL);
        if (r->vsink) { gst_object_unref(r->vsink); r->vsink = NULL; }
        if (r->asink) { gst_object_unref(r->asink); r->asink = NULL; }
        if (r->volume) { gst_object_unref(r->volume); r->volume = NULL; }
        gst_object_unref(r->pipeline);
        r->pipeline = NULL;
    }
    st_socket_close(r->vfd);
    st_socket_close(r->afd);
    r->vfd = r->afd = -1;
    if (r->clock) { gst_object_unref(r->clock); r->clock = NULL; }
    ptp_release(r);
    r->running = 0;
    g_mutex_lock(&r->lock);
    int changed = r->state != ST_STATE_STOPPED;
    r->state = ST_STATE_STOPPED;
    g_mutex_unlock(&r->lock);
    if (changed) emit(r, ST_EVENT_STATE, ST_STATE_STOPPED, "%s", st_state_name(ST_STATE_STOPPED));
}

void st_receiver_free(st_receiver *r)
{
    if (!r) return;
    st_receiver_stop(r);
    g_mutex_clear(&r->lock);
    g_free(r);
}

static void sink_stats(GstElement *sink, uint64_t *rendered, uint64_t *dropped)
{
    *rendered = *dropped = 0;
    if (!sink) return;
    GstStructure *s = NULL;
    g_object_get(sink, "stats", &s, NULL);
    if (s) {
        guint64 v = 0;
        if (gst_structure_get_uint64(s, "rendered", &v)) *rendered = v;
        if (gst_structure_get_uint64(s, "dropped", &v)) *dropped = v;
        gst_structure_free(s);
    }
}

void st_receiver_get_stats(st_receiver *r, st_stats *o)
{
    memset(o, 0, sizeof *o);
    uint64_t vr, vd, ar, ad;
    sink_stats(r->vsink, &vr, &vd);
    sink_stats(r->asink, &ar, &ad);
    int64_t now = g_get_monotonic_time();
    g_mutex_lock(&r->lock);
    o->state = r->state;
    o->sync_requested = r->cfg.sync_mode;
    o->sync_active = r->active;
    o->v_packets = r->vs.packets;
    o->v_bytes = r->vs.bytes;
    o->v_lost = r->vs.lost;
    o->v_reordered = r->vs.reordered;
    o->v_frames = r->vs.frames;
    o->v_frames_rendered = vr;
    o->v_frames_dropped = vd;
    o->v_wrong_pt = r->vs.wrong_pt;
    o->v_age_ms = r->vs.last_packet_us ? (now - r->vs.last_packet_us) / 1000.0 : -1;
    o->v_rate_mbps = r->vs.rate_mbps;
    o->v_fps_measured = r->vs.fps;
    o->v_width_seen = r->vs.seen_w;
    o->v_height_seen = r->vs.seen_interlace ? r->vs.seen_h * 2 : r->vs.seen_h;
    o->v_interlace_seen = r->vs.seen_interlace;
    o->v_ssrc = r->vs.ssrc;
    o->v_transit_ms = r->vs.transit_show / 1e6;
    o->a_packets = r->as.packets;
    o->a_lost = r->as.lost;
    o->a_reordered = r->as.reordered;
    o->a_wrong_pt = r->as.wrong_pt;
    o->a_buffers_rendered = ar;
    o->a_buffers_dropped = ad;
    o->a_age_ms = r->as.last_packet_us ? (now - r->as.last_packet_us) / 1000.0 : -1;
    o->a_ptime_measured_ms = r->as.ptime_ms;
    o->a_payload_bytes = r->as.payload_bytes;
    o->a_ssrc = r->as.ssrc;
    o->a_transit_ms = r->as.transit_show / 1e6;
    if (r->vs.packets && r->as.packets)
        o->av_capture_delta_ms = o->v_transit_ms - o->a_transit_ms;
    o->latency_ms = r->cfg.demo ? 0 : (double)r->lat_ns / 1e6;
    o->v_late_max_ms = r->v_late_show == INT64_MIN ? 0 : (double)r->v_late_show / 1e6;
    o->a_late_max_ms = r->a_late_show == INT64_MIN ? 0 : (double)r->a_late_show / 1e6;
    o->latency_auto_raised = r->lat_raised;
    o->offset_drift_ppm = r->tracker.drift_ppm;
    o->resyncs = r->tracker.resyncs > 0 ? r->tracker.resyncs : 0;
    o->ptp_enabled = r->ptp_enabled;
    o->ptp_synced = r->ptp_clock ? gst_clock_is_synced(r->ptp_clock) : 0;
    o->ptp_domain = r->ptp_domain;
    g_strlcpy(o->ptp_grandmaster, r->ptp_gm, sizeof o->ptp_grandmaster);
    g_strlcpy(o->ptp_master, r->ptp_master, sizeof o->ptp_master);
    o->ptp_path_delay_us = r->ptp_path_delay_us;
    o->ptp_rsquared = r->ptp_rsq;
    o->ptp_domains_seen = r->ptp_domains_seen;
    const char *sdp_gm = r->cfg.has_video ? r->cfg.video.ptp_gmid : r->cfg.audio.ptp_gmid;
    if (!r->ptp_gm[0] || !sdp_gm[0]) o->ptp_gm_matches_sdp = -1;
    else o->ptp_gm_matches_sdp = strcasecmp(r->ptp_gm, sdp_gm) == 0;
    o->socket_buffer_bytes = r->rcvbuf;
    o->sync_measurements = r->sync_n;
    o->sync_offset_last_ms = r->sync_last_ms;
    o->sync_offset_avg_ms = r->sync_avg_ms;
    o->flashes_seen = r->flashes;
    o->onsets_seen = r->onsets;
    g_mutex_unlock(&r->lock);
}

int st_receiver_get_levels(st_receiver *r, float *peak_db, int max)
{
    int n = r->a_channels;
    if (n > max) n = max;
    int64_t now = g_get_monotonic_time();
    g_mutex_lock(&r->lock);
    double dt = r->peak_t_us ? (now - r->peak_t_us) / 1e6 : 0;
    r->peak_t_us = now;
    for (int c = 0; c < n; c++) {
        float p = r->peak[c];
        peak_db[c] = p > 1e-6f ? 20.0f * log10f(p) : -120.0f;
        /* Abfall ca. 20 dB/s (wie PPM-Rücklauf grob angenähert) */
        r->peak[c] = p * powf(10.0f, (float)(-20.0 * dt / 20.0));
    }
    g_mutex_unlock(&r->lock);
    return n;
}

void st_receiver_set_volume(st_receiver *r, double v)
{
    if (r->volume) g_object_set(r->volume, "volume", v, NULL);
}

void st_receiver_set_mute(st_receiver *r, int m)
{
    if (r->volume) g_object_set(r->volume, "mute", m ? TRUE : FALSE, NULL);
}

void st_receiver_set_monitor_channels(st_receiver *r, int left, int right)
{
    g_atomic_int_set(&r->mon_left, left);
    g_atomic_int_set(&r->mon_right, right);
}

void st_receiver_set_audio_delay_ms(st_receiver *r, int ms)
{
    if (r->asink) g_object_set(r->asink, "ts-offset", (gint64)ms * GST_MSECOND, NULL);
}
