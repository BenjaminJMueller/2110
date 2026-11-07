/*
 * Selbsttest für die ausgelieferte App (2110 Viewer --selftest) und CI:
 *  1. GStreamer startet, alle benötigten Plugins sind vorhanden
 *  2. Demo-Pipeline liefert Bild und Ton
 *  3. Loopback: ein interner RFC-4175-/L24-Sender schickt per UDP (Unicast
 *     127.0.0.1) an den Empfangskern; Bilder, Audio und Lippensynchronität
 *     werden geprüft
 *  4. PTP-Hilfsprogramm lässt sich starten (ohne Grandmaster: nur Start)
 *
 * Alles synthetisch – ersetzt nicht den Test mit Blackmagic-Hardware.
 */
#include "st2110core.h"
#include "st_internal.h"

#include <gst/gst.h>
#include <gst/net/gstptpclock.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static void say(char *out, size_t len, const char *fmt, ...)
{
    size_t l = strlen(out);
    if (l >= len) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(out + l, len - l, fmt, ap);
    va_end(ap);
}

static uint64_t g_frames;
static void count_frame(void *u, const st_video_frame *f) { (void)u; (void)f; g_frames++; }

static GstPadProbeReturn flash_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    GstClockTime *v0 = user;
    GstBuffer *b = gst_buffer_make_writable(GST_PAD_PROBE_INFO_BUFFER(info));
    GST_PAD_PROBE_INFO_DATA(info) = b;
    GstClockTime pts = GST_BUFFER_PTS(b);
    if (*v0 == GST_CLOCK_TIME_NONE) *v0 = pts;
    guint64 n = gst_util_uint64_scale_round(pts - *v0, 25, GST_SECOND);
    GstMapInfo m;
    if (gst_buffer_map(b, &m, GST_MAP_WRITE)) {
        /* 640x360 UYVP: Mitte weiß bei jedem 25. Bild, sonst schwarz */
        int w = 640, h = 360, stride = w / 2 * 5;
        int white = (n % 25) == 0;
        uint64_t v = white ? (((uint64_t)512 << 30) | ((uint64_t)940 << 20) | ((uint64_t)512 << 10) | 940)
                           : (((uint64_t)512 << 30) | ((uint64_t)64 << 20) | ((uint64_t)512 << 10) | 64);
        uint8_t pg[5] = { (uint8_t)(v >> 32), (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
        for (int y = h / 2 - 40; y < h / 2 + 40; y++)
            for (int x = w / 2 - 40; x < w / 2 + 40; x += 2)
                if ((size_t)(y * stride + x / 2 * 5 + 5) <= m.size) memcpy(m.data + y * stride + x / 2 * 5, pg, 5);
        gst_buffer_unmap(b, &m);
    }
    return GST_PAD_PROBE_OK;
}

typedef struct { GstClockTime *v0; } tick_ctx;
static GstPadProbeReturn tick_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    GstClockTime *v0 = user;
    GstBuffer *b = gst_buffer_make_writable(GST_PAD_PROBE_INFO_BUFFER(info));
    GST_PAD_PROBE_INFO_DATA(info) = b;
    GST_BUFFER_FLAG_UNSET(b, GST_BUFFER_FLAG_GAP);
    GstMapInfo m;
    if (!gst_buffer_map(b, &m, GST_MAP_WRITE)) return GST_PAD_PROBE_OK;
    float *f = (float *)m.data;
    size_t frames = m.size / sizeof(float) / 2;
    memset(m.data, 0, m.size);
    if (*v0 != GST_CLOCK_TIME_NONE) {
        for (size_t i = 0; i < frames; i++) {
            gint64 t = (gint64)(GST_BUFFER_PTS(b) + gst_util_uint64_scale(i, GST_SECOND, 48000)) - (gint64)*v0;
            if (t >= 0 && t % GST_SECOND < 20 * GST_MSECOND) f[2 * i] = f[2 * i + 1] = 0.5f;
        }
    }
    gst_buffer_unmap(b, &m);
    return GST_PAD_PROBE_OK;
}

int st_selftest(int seconds, int strict_licenses, char *out, size_t len)
{
    out[0] = '\0';
    int fails = 0;
    char err[1024];
    if (st_init(err, sizeof err) != 0) {
        say(out, len, "FEHLER GStreamer-Start: %s\n", err);
        return 1;
    }
    say(out, len, "OK    GStreamer %s gestartet\n", st_gstreamer_version());
    char missing[512];
    if (st_check_plugins(missing, sizeof missing) > 0) {
        say(out, len, "FEHLER fehlende Elemente: %s\n", missing);
        return 1;
    }
    say(out, len, "OK    alle benötigten Elemente vorhanden\n");

    /* Lizenzen aller geladenen Plugins (im ausgelieferten Bundle: nur LGPL/BSD/MIT) */
    {
        GList *plugins = gst_registry_get_plugin_list(gst_registry_get());
        int n = 0, bad = 0;
        for (GList *l = plugins; l; l = l->next) {
            GstPlugin *pl = l->data;
            const char *lic = gst_plugin_get_license(pl);
            n++;
            int ok = lic && (g_str_equal(lic, "LGPL") || g_str_equal(lic, "BSD") || g_str_equal(lic, "MIT/X11") || g_str_equal(lic, "MIT"));
            if (!ok) {
                bad++;
                if (strict_licenses) say(out, len, "FEHLER Plugin %s hat Lizenz „%s“\n", gst_plugin_get_name(pl), lic ? lic : "?");
            }
        }
        gst_plugin_list_free(plugins);
        if (strict_licenses && bad) fails++;
        else say(out, len, "%s %d Plugins geladen%s\n", bad ? "INFO " : "OK   ", n,
                 bad ? (strict_licenses ? "" : " (nicht-LGPL-Plugins der Systeminstallation, im Bundle nicht enthalten)") : ", alle LGPL/BSD/MIT");
    }

    /* 2. Demo */
    {
        st_receiver_config cfg;
        memset(&cfg, 0, sizeof cfg);
        cfg.demo = 1;
        cfg.demo_fps = 25;
        cfg.demo_channels = 16;
        cfg.audio_null_sink = 1;
        st_callbacks cb = { NULL, count_frame, NULL };
        g_frames = 0;
        st_receiver *r = st_receiver_new(&cfg, &cb, err, sizeof err);
        if (!r || st_receiver_start(r, err, sizeof err) != 0) {
            say(out, len, "FEHLER Demo-Start: %s\n", err);
            fails++;
        } else {
            g_usleep(2 * G_USEC_PER_SEC);
            float lv[16];
            int n = st_receiver_get_levels(r, lv, 16);
            st_receiver_free(r);
            r = NULL;
            if (g_frames >= 30 && n == 16 && lv[0] > -20) say(out, len, "OK    Demo: %llu Bilder, Pegel %.0f dBFS\n", (unsigned long long)g_frames, lv[0]);
            else { say(out, len, "FEHLER Demo: %llu Bilder, %d Kanäle, Pegel %.0f\n", (unsigned long long)g_frames, n, n > 0 ? lv[0] : -999.0); fails++; }
        }
        if (r) st_receiver_free(r);
    }

    /* 3. Loopback */
    {
        const int vport = 47004, aport = 47006;
        GstClockTime v0 = GST_CLOCK_TIME_NONE;
        gchar *desc = g_strdup_printf(
            "videotestsrc is-live=true pattern=black ! videoconvert ! video/x-raw,format=UYVP,width=640,height=360,framerate=25/1 "
            "! identity name=vtap silent=true ! rtpvrawpay pt=96 mtu=1400 timestamp-offset=%u ! udpsink host=127.0.0.1 port=%d sync=false async=false "
            "audiotestsrc is-live=true wave=silence samplesperbuffer=48 ! audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved "
            "! identity name=atap silent=true ! audioconvert ! audio/x-raw,format=S24BE ! rtpL24pay pt=97 min-ptime=1000000 max-ptime=1000000 timestamp-offset=%u "
            "! udpsink host=127.0.0.1 port=%d sync=false async=false",
            (guint32)((ST_TAI_UTC_OFFSET_S * 90000ULL) & 0xffffffffULL), vport,
            (guint32)((ST_TAI_UTC_OFFSET_S * 48000ULL) & 0xffffffffULL), aport);
        GError *e = NULL;
        GstElement *snd = gst_parse_launch(desc, &e);
        g_free(desc);
        if (!snd || e) {
            say(out, len, "FEHLER Testsender: %s\n", e ? e->message : "?");
            if (e) g_error_free(e);
            return fails + 1;
        }
        GstElement *vt = gst_bin_get_by_name(GST_BIN(snd), "vtap");
        GstElement *at = gst_bin_get_by_name(GST_BIN(snd), "atap");
        GstPad *vp = gst_element_get_static_pad(vt, "src");
        GstPad *apd = gst_element_get_static_pad(at, "src");
        gst_pad_add_probe(vp, GST_PAD_PROBE_TYPE_BUFFER, flash_probe, &v0, NULL);
        gst_pad_add_probe(apd, GST_PAD_PROBE_TYPE_BUFFER, tick_probe, &v0, NULL);
        gst_object_unref(vp); gst_object_unref(apd); gst_object_unref(vt); gst_object_unref(at);
        GstClock *clk = g_object_new(GST_TYPE_SYSTEM_CLOCK, "clock-type", GST_CLOCK_TYPE_REALTIME, NULL);
        gst_pipeline_use_clock(GST_PIPELINE(snd), clk);
        gst_element_set_start_time(snd, GST_CLOCK_TIME_NONE);
        gst_element_set_base_time(snd, 0);

        st_receiver_config cfg;
        memset(&cfg, 0, sizeof cfg);
        char sdp_v[1024], sdp_a[1024];
        snprintf(sdp_v, sizeof sdp_v,
                 "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Selbsttest\r\nt=0 0\r\nm=video %d RTP/AVP 96\r\nc=IN IP4 127.0.0.1\r\n"
                 "a=rtpmap:96 raw/90000\r\na=fmtp:96 sampling=YCbCr-4:2:2; width=640; height=360; exactframerate=25; depth=10; colorimetry=BT709\r\n"
                 "a=mediaclk:direct=0\r\n", vport);
        snprintf(sdp_a, sizeof sdp_a,
                 "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Selbsttest\r\nt=0 0\r\nm=audio %d RTP/AVP 97\r\nc=IN IP4 127.0.0.1\r\n"
                 "a=rtpmap:97 L24/48000/2\r\na=ptime:1\r\na=mediaclk:direct=0\r\n", aport);
        st_sdp_parse(sdp_v, &cfg.video, 1, err, sizeof err);
        st_sdp_parse(sdp_a, &cfg.audio, 1, err, sizeof err);
        cfg.has_video = cfg.has_audio = 1;
        cfg.sync_mode = ST_SYNC_RTP_ALIGNED;
        cfg.latency_ms = 150;
        cfg.auto_latency = 1;
        cfg.audio_null_sink = 1;
        snprintf(cfg.iface_addr, sizeof cfg.iface_addr, "127.0.0.1");
        st_callbacks cb = { NULL, count_frame, NULL };
        g_frames = 0;
        st_receiver *r = st_receiver_new(&cfg, &cb, err, sizeof err);
        if (!r || st_receiver_start(r, err, sizeof err) != 0) {
            say(out, len, "FEHLER Loopback-Empfänger: %s\n", err);
            fails++;
        } else {
            gst_element_set_state(snd, GST_STATE_PLAYING);
            g_usleep((gulong)(seconds > 3 ? seconds : 3) * G_USEC_PER_SEC);
            st_stats s;
            st_receiver_get_stats(r, &s);
            gst_element_set_state(snd, GST_STATE_NULL);
            st_receiver_free(r);
            r = NULL;
            int ok = s.v_frames_rendered >= 25 && s.a_packets >= 1000 && s.v_width_seen == 640 && s.v_height_seen == 360;
            say(out, len, "%s Loopback: %llu Bilder gezeigt, %llu Audiopakete, %d×%d, %.2f B/s, verloren V/A %llu/%llu\n",
                ok ? "OK   " : "FEHLER", (unsigned long long)s.v_frames_rendered, (unsigned long long)s.a_packets,
                s.v_width_seen, s.v_height_seen, s.v_fps_measured, (unsigned long long)s.v_lost, (unsigned long long)s.a_lost);
            if (!ok) fails++;
            if (s.sync_measurements >= 2) {
                int sync_ok = s.sync_offset_avg_ms > -5 && s.sync_offset_avg_ms < 5;
                say(out, len, "%s Lippensynchron (RTP-abgestimmt): %+.2f ms (n=%llu)\n", sync_ok ? "OK   " : "FEHLER",
                    s.sync_offset_avg_ms, (unsigned long long)s.sync_measurements);
                if (!sync_ok) fails++;
            } else {
                say(out, len, "FEHLER Lippensynchron: zu wenige Messungen (%llu Blitze, %llu Toneinsätze)\n",
                    (unsigned long long)s.flashes_seen, (unsigned long long)s.onsets_seen);
                fails++;
            }
        }
        if (r) st_receiver_free(r);
        gst_object_unref(snd);
        gst_object_unref(clk);
    }

    /* 4. PTP-Hilfsprogramm */
    {
        if (gst_ptp_is_initialized() || gst_ptp_init(GST_PTP_CLOCK_ID_NONE, NULL)) {
            say(out, len, "OK    PTP-Hilfsprogramm gestartet (ohne Grandmaster erwartungsgemäß nicht synchron)\n");
        } else {
            say(out, len, "WARN  PTP-Hilfsprogramm konnte nicht starten (Ports 319/320 belegt oder nicht erlaubt)\n");
        }
    }
    say(out, len, "%s\n", fails ? "SELBSTTEST FEHLGESCHLAGEN" : "SELBSTTEST BESTANDEN");
    return fails;
}
