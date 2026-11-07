/*
 * st2110-send – sendet Testbild und Testton als ST 2110-20/-30 (Kommandozeile).
 * Schreibt die SDPs in Dateien, damit Empfänger (Essenz, Blackmagic per IS-05)
 * sie verwenden können.
 */
#include "st2110send.h"
#include "st2110core.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

int main(int argc, char **argv)
{
    st_sender_config c;
    memset(&c, 0, sizeof c);
    c.has_video = c.has_audio = 1;
    snprintf(c.video_addr, sizeof c.video_addr, "239.20.0.1");
    snprintf(c.audio_addr, sizeof c.audio_addr, "239.20.0.2");
    c.video_port = c.audio_port = 5004;
    c.width = 1920; c.height = 1080; c.fps_num = 25; c.fps_den = 1;
    c.audio_channels = 2; c.audio_ptime_us = 1000;
    c.ttl = 16;
    snprintf(c.session_name, sizeof c.session_name, "Essenz Testsignal");
    int duration = 0;
    const char *sdp_dir = NULL;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(n) (strcmp(a, n) == 0 && ++i)
        if (OPT("--video-addr")) snprintf(c.video_addr, sizeof c.video_addr, "%s", v);
        else if (OPT("--audio-addr")) snprintf(c.audio_addr, sizeof c.audio_addr, "%s", v);
        else if (OPT("--video-port")) c.video_port = atoi(v);
        else if (OPT("--audio-port")) c.audio_port = atoi(v);
        else if (OPT("--iface")) snprintf(c.iface_name, sizeof c.iface_name, "%s", v);
        else if (OPT("--iface-addr")) snprintf(c.iface_addr, sizeof c.iface_addr, "%s", v);
        else if (OPT("--size")) sscanf(v, "%dx%d", &c.width, &c.height);
        else if (OPT("--fps")) { if (sscanf(v, "%d/%d", &c.fps_num, &c.fps_den) < 2) c.fps_den = 1; }
        else if (OPT("--channels")) c.audio_channels = atoi(v);
        else if (OPT("--ptime-us")) c.audio_ptime_us = atoi(v);
        else if (OPT("--duration")) duration = atoi(v);
        else if (OPT("--sdp-dir")) sdp_dir = v;
        else if (OPT("--ptp-domain")) { c.use_ptp = 1; c.ptp_domain = atoi(v); }
        else if (strcmp(a, "--ptp") == 0) c.use_ptp = 1;
        else if (strcmp(a, "--sync-pattern") == 0) c.pattern = ST_PATTERN_SYNC;
        else if (strcmp(a, "--no-video") == 0) c.has_video = 0;
        else if (strcmp(a, "--no-audio") == 0) c.has_audio = 0;
        else {
            fprintf(stderr, "st2110-send [--video-addr A --audio-addr A --video-port P --audio-port P]\n"
                            "            [--iface en7 --iface-addr IP] [--size 1920x1080] [--fps 25|50|30000/1001]\n"
                            "            [--channels N --ptime-us 1000|125] [--ptp [--ptp-domain N]] [--sync-pattern]\n"
                            "            [--sdp-dir DIR] [--duration S]\n");
            return 2;
        }
#undef OPT
    }
    char err[512];
    st_sender *s = st_sender_new(&c, err, sizeof err);
    if (!s || st_sender_start(s, err, sizeof err) != 0) { fprintf(stderr, "%s\n", err); return 1; }
    char sdp[2048];
    for (int v = 1; v >= 0; v--) {
        if (st_sender_sdp(s, v, sdp, sizeof sdp) < 0) continue;
        if (sdp_dir) {
            char path[1024];
            snprintf(path, sizeof path, "%s/%s.sdp", sdp_dir, v ? "send-video" : "send-audio");
            FILE *f = fopen(path, "w");
            if (f) { fputs(sdp, f); fclose(f); }
        } else {
            printf("%s\n", sdp);
        }
    }
    fflush(stdout);
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    for (int t = 0; !g_stop && (duration <= 0 || t < duration); t++) {
        sleep(1);
        st_sender_stats st;
        st_sender_get_stats(s, &st);
        fprintf(stderr, "%3ds Bilder %llu  Pakete V/A %llu/%llu  %.0f Mbit/s  verspätet %llu (max %.0f µs)  PTP %s\n", t + 1,
                (unsigned long long)st.frames_sent, (unsigned long long)st.video_packets, (unsigned long long)st.audio_packets,
                st.video_mbps, (unsigned long long)st.late_packets, st.max_late_us, st.ptp_locked ? "gelockt" : "aus");
    }
    st_sender_free(s);
    return 0;
}
