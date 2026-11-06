/*
 * st2110-probe – Kommandozeilen-Empfänger (Prototyp und Abnahmewerkzeug).
 *
 * Empfängt einen Video- und/oder Audiostrom anhand von SDP-Dateien mit
 * demselben Empfangskern wie die App, gibt jede Sekunde eine Statuszeile aus
 * und am Ende eine Zusammenfassung (wahlweise JSON). Mit einem Blitz/Piep-
 * Testsignal misst es den Lippensynchron-Versatz an den Ausgabezeitstempeln.
 *
 * Beispiel:
 *   st2110-probe --video-sdp cam1-video.sdp --audio-sdp cam1-audio.sdp \
 *                --iface en7 --iface-addr 192.168.10.50 --mode ptp --duration 60
 */
#include "st2110core.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1);
    if (!b) { fclose(f); return NULL; }
    size_t got = fread(b, 1, (size_t)n, f);
    b[got] = '\0';
    fclose(f);
    return b;
}

static int load_media(const char *path, st_receiver_config *cfg)
{
    char *txt = read_file(path);
    if (!txt) { fprintf(stderr, "Datei %s nicht lesbar\n", path); return -1; }
    st_sdp_media m[8];
    char err[512];
    int n = st_sdp_parse(txt, m, 8, err, sizeof err);
    free(txt);
    if (n < 0) { fprintf(stderr, "%s: %s\n", path, err); return -1; }
    for (int i = 0; i < n; i++) {
        char msg[512];
        st_support sup = st_check_media(&m[i], msg, sizeof msg);
        const char *kind = m[i].kind == ST_MEDIA_VIDEO ? "Video" : m[i].kind == ST_MEDIA_AUDIO ? "Audio" : "Daten";
        printf("[SDP] %s %s:%d %s%s%s\n", kind, m[i].dest_addr, m[i].port,
               sup == ST_SUPPORT_OK ? "unterstützt" : sup == ST_SUPPORT_WARNING ? "Hinweis: " : "NICHT unterstützt: ", msg, "");
        if (sup == ST_SUPPORT_NO) continue;
        if (m[i].kind == ST_MEDIA_VIDEO && !cfg->has_video) { cfg->video = m[i]; cfg->has_video = 1; }
        else if (m[i].kind == ST_MEDIA_AUDIO && !cfg->has_audio) { cfg->audio = m[i]; cfg->has_audio = 1; }
    }
    return 0;
}

static void on_event(void *user, st_event ev, int code, const char *message)
{
    (void)user; (void)code;
    const char *t = ev == ST_EVENT_ERROR ? "FEHLER" : ev == ST_EVENT_WARNING ? "Hinweis" :
                    ev == ST_EVENT_STATE ? "Zustand" : ev == ST_EVENT_FORMAT_MISMATCH ? "Format" :
                    ev == ST_EVENT_SENDER_RESTART ? "Sender" : "PTP";
    fprintf(stdout, "[%s] %s\n", t, message);
    fflush(stdout);
}

static uint64_t g_frames = 0;
static void on_frame(void *user, const st_video_frame *f) { (void)user; (void)f; g_frames++; }

int main(int argc, char **argv)
{
    st_receiver_config cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.sync_mode = ST_SYNC_RTP_ALIGNED;
    cfg.ptp_domain = -1;
    cfg.latency_ms = 120;
    cfg.auto_latency = 1;
    cfg.use_source_filter = 1;
    int duration = 10, json = 0;
    cfg.audio_null_sink = 1;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(n) (strcmp(a, n) == 0 && ++i)
        if (OPT("--video-sdp") || OPT("--audio-sdp") || OPT("--sdp")) { if (load_media(v, &cfg)) return 2; }
        else if (OPT("--iface")) snprintf(cfg.iface_name, sizeof cfg.iface_name, "%s", v);
        else if (OPT("--iface-addr")) snprintf(cfg.iface_addr, sizeof cfg.iface_addr, "%s", v);
        else if (OPT("--mode")) cfg.sync_mode = strcmp(v, "preview") == 0 ? ST_SYNC_PREVIEW : strcmp(v, "ptp") == 0 ? ST_SYNC_PTP : ST_SYNC_RTP_ALIGNED;
        else if (OPT("--duration")) duration = atoi(v);
        else if (OPT("--latency")) cfg.latency_ms = atoi(v);
        else if (OPT("--ptp-domain")) cfg.ptp_domain = atoi(v);
        else if (strcmp(a, "--fixed-latency") == 0) cfg.auto_latency = 0;
        else if (strcmp(a, "--audio-out") == 0) cfg.audio_null_sink = 0;
        else if (strcmp(a, "--no-ssm") == 0) cfg.use_source_filter = 0;
        else if (strcmp(a, "--json") == 0) json = 1;
        else if (strcmp(a, "--selftest") == 0) {
            static char rep[8192];
            int f = st_selftest(5, rep, sizeof rep);
            fputs(rep, stdout);
            return f ? 1 : 0;
        }
        else if (strcmp(a, "--demo") == 0) { cfg.demo = 1; cfg.demo_fps = 25; cfg.demo_channels = 16; }
        else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            printf("st2110-probe --video-sdp DATEI --audio-sdp DATEI [--iface en7 --iface-addr IP]\n"
                   "             [--mode preview|rtp|ptp] [--ptp-domain N] [--latency MS] [--fixed-latency] [--duration S]\n"
                   "             [--audio-out] [--no-ssm] [--json] [--demo] [--selftest]\n");
            return 0;
        } else { fprintf(stderr, "Unbekannte Option %s (--help)\n", a); return 2; }
#undef OPT
    }
    char err[1024];
    if (st_init(err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    char missing[512];
    if (st_check_plugins(missing, sizeof missing)) fprintf(stderr, "Fehlende GStreamer-Elemente: %s\n", missing);
    printf("[Info] GStreamer %s, Modus: %s\n", st_gstreamer_version(), st_sync_mode_name(cfg.sync_mode));

    st_callbacks cb = { .user = NULL, .video_frame = on_frame, .event = on_event };
    st_receiver *r = st_receiver_new(&cfg, &cb, err, sizeof err);
    if (!r) { fprintf(stderr, "%s\n", err); return 1; }
    if (st_receiver_start(r, err, sizeof err)) { fprintf(stderr, "%s\n", err); st_receiver_free(r); return 1; }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    st_stats s;
    for (int t = 0; (duration <= 0 || t < duration) && !g_stop; t++) {
        sleep(1);
        st_receiver_get_stats(r, &s);
        float lv[ST_MAX_AUDIO_CHANNELS];
        int n = st_receiver_get_levels(r, lv, ST_MAX_AUDIO_CHANNELS);
        printf("%3ds %-20s V: %6.0f Mbit/s %5.2f B/s verl=%llu gezeigt=%llu verworfen=%llu | A: Pakete=%llu verl=%llu ptime=%.3f ms | L1=%.0f dB | Sync: %s",
               t + 1, st_state_name(s.state), s.v_rate_mbps, s.v_fps_measured,
               (unsigned long long)s.v_lost, (unsigned long long)s.v_frames_rendered, (unsigned long long)s.v_frames_dropped,
               (unsigned long long)s.a_packets, (unsigned long long)s.a_lost, s.a_ptime_measured_ms,
               n > 0 ? lv[0] : -120.0, st_sync_mode_name(s.sync_active));
        if (s.sync_measurements) printf(" A/V=%+.1f ms (Ø %+.1f, n=%llu)", s.sync_offset_last_ms, s.sync_offset_avg_ms, (unsigned long long)s.sync_measurements);
        if (s.ptp_enabled) printf(" PTP=%s GM=%s", s.ptp_synced ? "lock" : "frei", s.ptp_grandmaster);
        printf("\n");
        fflush(stdout);
    }
    st_receiver_get_stats(r, &s);
    if (json) {
        printf("{\"state\":\"%s\",\"sync_active\":%d,\"v_packets\":%llu,\"v_lost\":%llu,\"v_frames\":%llu,"
               "\"v_rendered\":%llu,\"v_dropped\":%llu,\"v_fps\":%.3f,\"v_width\":%d,\"v_height\":%d,"
               "\"a_packets\":%llu,\"a_lost\":%llu,\"a_rendered\":%llu,\"a_ptime_ms\":%.4f,"
               "\"sync_n\":%llu,\"sync_avg_ms\":%.3f,\"sync_last_ms\":%.3f,\"flashes\":%llu,\"onsets\":%llu,"
               "\"latency_ms\":%.0f,\"v_late_max_ms\":%.1f,\"a_late_max_ms\":%.1f,\"v_transit_ms\":%.2f,\"a_transit_ms\":%.2f,\"resyncs\":%llu,\"drift_ppm\":%.3f,\"ptp_synced\":%d,\"rcvbuf\":%d,\"callback_frames\":%llu}\n",
               st_state_name(s.state), s.sync_active, (unsigned long long)s.v_packets, (unsigned long long)s.v_lost,
               (unsigned long long)s.v_frames, (unsigned long long)s.v_frames_rendered, (unsigned long long)s.v_frames_dropped,
               s.v_fps_measured, s.v_width_seen, s.v_height_seen, (unsigned long long)s.a_packets, (unsigned long long)s.a_lost,
               (unsigned long long)s.a_buffers_rendered, s.a_ptime_measured_ms, (unsigned long long)s.sync_measurements,
               s.sync_offset_avg_ms, s.sync_offset_last_ms, (unsigned long long)s.flashes_seen, (unsigned long long)s.onsets_seen,
               s.latency_ms, s.v_late_max_ms, s.a_late_max_ms, s.v_transit_ms, s.a_transit_ms, (unsigned long long)s.resyncs, s.offset_drift_ppm, s.ptp_synced, s.socket_buffer_bytes, (unsigned long long)g_frames);
    }
    st_receiver_free(r);
    return 0;
}
