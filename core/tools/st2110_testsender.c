/*
 * st2110-testsender – synthetischer Sender für Tests ohne Blackmagic-Hardware.
 *
 * Erzeugt RFC-4175-/ST-2110-20-ähnliches Video (YCbCr 4:2:2 10 Bit) und
 * ST-2110-30-ähnliches L24-Audio. Die RTP-Zeitstempel beider Ströme werden
 * wie bei ST 2059 aus derselben Uhr (Systemzeit als TAI-Näherung) abgeleitet.
 * Zur Lippensynchronprüfung blitzt das Bild jede Sekunde weiß, zeitgleich
 * erklingt ein Ton-Einsatz (1 kHz, 20 ms).
 *
 * WICHTIG: Dies ist KEIN normkonformer ST-2110-Sender (kein 2110-21-Pacing,
 * kein PTP). Er dient nur dazu, den Empfangskern reproduzierbar zu prüfen.
 * Tests damit gelten als „synthetisch getestet“, nicht als Hardware-Nachweis.
 */
#include <gst/gst.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int fps, width, height, channels;
    double ptime_ms;
    int audio_offset_ms;      /* absichtlicher Versatz der Audio-Zeitstempel */
    int content_offset_ms;    /* absichtlicher Versatz des Ton-Einsatzes (Inhalt) */
    int no_video;
    GstClockTime v0;
    int have_v0;
    GMutex lock;
} sender;

static void fill_white(uint8_t *data, int stride, int x0, int y0, int w, int h)
{
    uint64_t v = ((uint64_t)512 << 30) | ((uint64_t)940 << 20) | ((uint64_t)512 << 10) | 940;
    uint8_t pg[5] = { (uint8_t)(v >> 32), (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    for (int y = y0; y < y0 + h; y++)
        for (int x = x0 & ~1; x < x0 + w; x += 2) memcpy(data + (size_t)y * stride + (size_t)(x / 2) * 5, pg, 5);
}

static GstPadProbeReturn vprobe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    sender *s = user;
    GstBuffer *b = gst_buffer_make_writable(GST_PAD_PROBE_INFO_BUFFER(info));
    GST_PAD_PROBE_INFO_DATA(info) = b;
    GstClockTime pts = GST_BUFFER_PTS(b);
    g_mutex_lock(&s->lock);
    if (!s->have_v0) { s->v0 = pts; s->have_v0 = 1; }
    GstClockTime v0 = s->v0;
    g_mutex_unlock(&s->lock);
    guint64 n = gst_util_uint64_scale_round(pts - v0, s->fps, GST_SECOND);
    if (n % (guint64)s->fps == 0) {
        GstMapInfo m;
        if (gst_buffer_map(b, &m, GST_MAP_WRITE)) {
            int stride = s->width / 2 * 5;
            fill_white(m.data, stride, s->width / 2 - 100, s->height / 2 - 100, 200, 200);
            gst_buffer_unmap(b, &m);
        }
    }
    return GST_PAD_PROBE_OK;
}

static GstPadProbeReturn aprobe(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad;
    sender *s = user;
    GstBuffer *b = gst_buffer_make_writable(GST_PAD_PROBE_INFO_BUFFER(info));
    GST_PAD_PROBE_INFO_DATA(info) = b;
    /* audiotestsrc markiert Stille als GAP; audioconvert würde sie sonst verwerfen */
    GST_BUFFER_FLAG_UNSET(b, GST_BUFFER_FLAG_GAP);
    g_mutex_lock(&s->lock);
    if (s->no_video && !s->have_v0) { s->v0 = GST_BUFFER_PTS(b); s->have_v0 = 1; }
    int have = s->have_v0;
    GstClockTime v0 = s->v0;
    g_mutex_unlock(&s->lock);
    GstMapInfo m;
    if (!gst_buffer_map(b, &m, GST_MAP_WRITE)) return GST_PAD_PROBE_OK;
    float *f = (float *)m.data;
    size_t frames = m.size / sizeof(float) / (size_t)s->channels;
    memset(m.data, 0, m.size);
    if (getenv("ST_DEBUG")) fprintf(stderr, "aprobe have=%d pts=%" G_GUINT64_FORMAT " v0=%" G_GUINT64_FORMAT " frames=%zu size=%zu\n", have, GST_BUFFER_PTS(b), v0, frames, m.size);
    if (have) {
        GstClockTime pts = GST_BUFFER_PTS(b);
        for (size_t i = 0; i < frames; i++) {
            gint64 t = (gint64)(pts + gst_util_uint64_scale(i, GST_SECOND, 48000)) - (gint64)v0
                       - (gint64)s->content_offset_ms * GST_MSECOND;
            if (t < 0) continue;
            gint64 in_sec = t % GST_SECOND;
            if (in_sec < 20 * GST_MSECOND) {
                float v = 0.5f * sinf(2.0f * (float)M_PI * 1000.0f * (float)in_sec / 1e9f);
                for (int c = 0; c < s->channels; c++) f[i * s->channels + c] = v * (c % 2 ? 0.5f : 1.0f);
            }
        }
    }
    gst_buffer_unmap(b, &m);
    return GST_PAD_PROBE_OK;
}

static void write_file(const char *dir, const char *name, const char *text)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (f) { fputs(text, f); fclose(f); }
}

int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    sender s = { .fps = 25, .width = 1920, .height = 1080, .channels = 16, .ptime_ms = 1.0 };
    g_mutex_init(&s.lock);
    const char *vaddr = "239.10.10.1", *aaddr = "239.10.10.2", *iface_addr = NULL, *sdp_dir = NULL;
    int vport = 5004, aport = 5004, duration = 0, no_video = 0, no_audio = 0, tai = 37;
    double loss = 0;
    unsigned ssrc_v = 0, ssrc_a = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(n) (strcmp(a, n) == 0 && ++i)
        if (OPT("--fps")) s.fps = atoi(v);
        else if (OPT("--width")) s.width = atoi(v);
        else if (OPT("--height")) s.height = atoi(v);
        else if (OPT("--channels")) s.channels = atoi(v);
        else if (OPT("--ptime")) s.ptime_ms = atof(v);
        else if (OPT("--video-addr")) vaddr = v;
        else if (OPT("--audio-addr")) aaddr = v;
        else if (OPT("--video-port")) vport = atoi(v);
        else if (OPT("--audio-port")) aport = atoi(v);
        else if (OPT("--iface-addr")) iface_addr = v;
        else if (OPT("--duration")) duration = atoi(v);
        else if (OPT("--audio-ts-offset-ms")) s.audio_offset_ms = atoi(v);
        else if (OPT("--audio-content-offset-ms")) s.content_offset_ms = atoi(v);
        else if (OPT("--loss")) loss = atof(v);
        else if (OPT("--tai-offset-s")) tai = atoi(v);
        else if (OPT("--sdp-dir")) sdp_dir = v;
        else if (OPT("--ssrc-video")) ssrc_v = (unsigned)strtoul(v, NULL, 0);
        else if (OPT("--ssrc-audio")) ssrc_a = (unsigned)strtoul(v, NULL, 0);
        else if (strcmp(a, "--no-video") == 0) no_video = 1;
        else if (strcmp(a, "--no-audio") == 0) no_audio = 1;
        else { fprintf(stderr, "Unbekannte Option %s\n", a); return 2; }
#undef OPT
    }

    /* RTP-Zeit = (Systemzeit + 37 s) * Taktrate, wie ST 2059 (TAI). */
    guint32 voff = (guint32)(((guint64)tai * 90000ULL) & 0xffffffffULL);
    guint32 aoff = (guint32)(((guint64)tai * 48000ULL + (guint64)((gint64)s.audio_offset_ms * 48)) & 0xffffffffULL);
    int ptime_ns = (int)(s.ptime_ms * 1e6);
    int spp = (int)(48000 * s.ptime_ms / 1000.0 + 0.5);

    gchar *vssrc = ssrc_v ? g_strdup_printf("ssrc=%u", ssrc_v) : g_strdup("");
    gchar *assrc = ssrc_a ? g_strdup_printf("ssrc=%u", ssrc_a) : g_strdup("");
    gchar *netsim = loss > 0 ? g_strdup_printf("! netsim drop-probability=%g", loss) : g_strdup("");
    GString *d = g_string_new(NULL);
    if (!no_video) {
        g_string_append_printf(d,
            "videotestsrc num-buffers=1 pattern=smpte ! videoconvert ! video/x-raw,format=UYVP,width=%d,height=%d ! imagefreeze is-live=true ! video/x-raw,framerate=%d/1 "
            "! identity name=vtap silent=true ! rtpvrawpay name=vpay pt=96 mtu=1450 timestamp-offset=%u %s "
            "%s ! udpsink host=%s port=%d ttl-mc=8 auto-multicast=true sync=false async=false ",
            s.width, s.height, s.fps, voff, vssrc, netsim, vaddr, vport);
    }
    if (!no_audio) {
        g_string_append_printf(d,
            "audiotestsrc is-live=true wave=silence samplesperbuffer=%d ! audio/x-raw,format=F32LE,rate=48000,channels=%d,layout=interleaved "
            "! identity name=atap silent=true ! audioconvert ! audio/x-raw,format=S24BE "
            "! rtpL24pay name=apay pt=97 min-ptime=%d max-ptime=%d timestamp-offset=%u %s "
            "%s ! udpsink host=%s port=%d ttl-mc=8 auto-multicast=true sync=false async=false ",
            spp, s.channels, ptime_ns, ptime_ns, aoff, assrc, netsim, aaddr, aport);
    }
    g_free(vssrc);
    g_free(assrc);
    g_free(netsim);
    gchar *desc = g_string_free(d, FALSE);
    GError *e = NULL;
    GstElement *pipe = gst_parse_launch(desc, &e);
    if (!pipe || e) {
        fprintf(stderr, "Pipeline-Fehler: %s\n%s\n", e ? e->message : "?", desc);
        return 1;
    }
    g_free(desc);
    GstElement *vt = gst_bin_get_by_name(GST_BIN(pipe), "vtap");
    if (vt) {
        GstPad *p = gst_element_get_static_pad(vt, "src");
        gst_pad_add_probe(p, GST_PAD_PROBE_TYPE_BUFFER, vprobe, &s, NULL);
        gst_object_unref(p);
        gst_object_unref(vt);
    }
    GstElement *at = gst_bin_get_by_name(GST_BIN(pipe), "atap");
    if (at) {
        GstPad *p = gst_element_get_static_pad(at, "src");
        gst_pad_add_probe(p, GST_PAD_PROBE_TYPE_BUFFER, aprobe, &s, NULL);
        gst_object_unref(p);
        gst_object_unref(at);
    }
    (void)iface_addr;
    s.no_video = no_video;

    /* Echtzeituhr mit Basiszeit 0: Laufzeit = Systemzeit seit 1970. */
    GstClock *clk = g_object_new(GST_TYPE_SYSTEM_CLOCK, "clock-type", GST_CLOCK_TYPE_REALTIME, NULL);
    gst_pipeline_use_clock(GST_PIPELINE(pipe), clk);
    gst_element_set_start_time(pipe, GST_CLOCK_TIME_NONE);
    gst_element_set_base_time(pipe, 0);

    if (sdp_dir) {
        char buf[2048];
        char fps[16];
        snprintf(fps, sizeof fps, "%d", s.fps);
        snprintf(buf, sizeof buf,
                 "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Testsender Video\r\nt=0 0\r\n"
                 "m=video %d RTP/AVP 96\r\nc=IN IP4 %s/64\r\n"
                 "a=rtpmap:96 raw/90000\r\n"
                 "a=fmtp:96 sampling=YCbCr-4:2:2; width=%d; height=%d; exactframerate=%s; depth=10; TCS=SDR; colorimetry=BT709; PM=2110GPM; SSN=ST2110-20:2017; TP=2110TPN; \r\n"
                 "a=ts-refclk:localmac=00-00-00-00-00-00\r\na=mediaclk:direct=0\r\n",
                 vport, vaddr, s.width, s.height, fps);
        write_file(sdp_dir, "video.sdp", buf);
        snprintf(buf, sizeof buf,
                 "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Testsender Audio\r\nt=0 0\r\n"
                 "m=audio %d RTP/AVP 97\r\nc=IN IP4 %s/64\r\n"
                 "a=rtpmap:97 L24/48000/%d\r\na=ptime:%g\r\n"
                 "a=ts-refclk:localmac=00-00-00-00-00-00\r\na=mediaclk:direct=0\r\n",
                 aport, aaddr, s.channels, s.ptime_ms);
        write_file(sdp_dir, "audio.sdp", buf);
    }

    gst_element_set_state(pipe, GST_STATE_PLAYING);
    GstBus *bus = gst_element_get_bus(pipe);
    GstMessage *msg = gst_bus_timed_pop_filtered(bus, duration > 0 ? (GstClockTime)duration * GST_SECOND : GST_CLOCK_TIME_NONE,
                                                 GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
    int rc = 0;
    if (msg) {
        if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
            GError *err = NULL;
            gst_message_parse_error(msg, &err, NULL);
            fprintf(stderr, "Fehler: %s\n", err->message);
            g_error_free(err);
            rc = 1;
        }
        gst_message_unref(msg);
    }
    gst_object_unref(bus);
    gst_element_set_state(pipe, GST_STATE_NULL);
    gst_object_unref(pipe);
    gst_object_unref(clk);
    return rc;
}
