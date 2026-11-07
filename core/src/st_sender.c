/*
 * ST 2110-20/-30 Sender mit Software-Pacing. Siehe st2110send.h.
 */
#include "st2110send.h"
#include "st2110core.h"
#include "st_internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <gst/gst.h>
#include <gst/net/gstptpclock.h>
#include <math.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define NS 1000000000ULL
#define MAX_PAYLOAD 1200        /* Nutzdaten je Paket (Vielfaches von 5 und 4) */
#define AUDIO_RING_FRAMES 48000 /* 1 s */

struct st_sender {
    st_sender_config cfg;
    pthread_t vthread, athread;
    int vthread_ok, athread_ok;
    volatile int stop;
    int vfd, afd;

    /* Zeit */
    GstClock *ptp;
    int ptp_locked;
    char gm[32];
    gulong ptp_cb;

    /* Video: drei Puffer (senden / bereit / schreiben) */
    pthread_mutex_t vlock;
    uint8_t *frame_base;        /* Testbild ohne Overlay */
    uint8_t *send_buf;
    uint8_t *ready_buf;
    uint8_t *write_buf;
    int ready_new;
    int64_t last_push_us;
    size_t line_bytes, frame_bytes;
    int segs_per_line;

    /* Audio-Ringpuffer */
    pthread_mutex_t alock;
    float *ring;
    size_t ring_r, ring_w, ring_fill;
    int64_t last_audio_push_us;

    /* Statistik */
    pthread_mutex_t slock;
    st_sender_stats st;
    uint64_t vbytes, vbytes_prev;
    int64_t rate_t_prev;
    uint16_t vseq, aseq;
    uint32_t vseq_ext;
    uint32_t ssrc_v, ssrc_a;
};

/* ------------------------------------------------------------------ */
/* Zeit                                                               */

static int64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * (int64_t)NS + ts.tv_nsec;
}

static uint64_t media_now(st_sender *s)
{
    if (s->ptp_locked && s->ptp) return gst_clock_get_time(s->ptp);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * NS + (uint64_t)ts.tv_nsec + (uint64_t)ST_TAI_UTC_OFFSET_S * NS;
}

/* Wartet bis zur Medienzeit t. spin_ns: so lange vor dem Ziel wird aktiv
 * gewartet (Schlafen ist auf Desktop-Systemen auf ~50–100 µs ungenau). */
static void wait_until_spin(st_sender *s, uint64_t t, uint64_t spin_ns)
{
    for (;;) {
        if (s->stop) return;
        uint64_t now = media_now(s);
        if (now >= t) return;
        uint64_t d = t - now;
        if (d > spin_ns) {
            uint64_t sl = d - spin_ns;
            if (sl > 20000000ULL) sl = 20000000ULL;
            struct timespec ts = { (time_t)(sl / NS), (long)(sl % NS) };
            nanosleep(&ts, NULL);
        }
    }
}

/* Video: letzte 0,5 ms aktiv warten (gleichmäßige Paketabstände) */
static void wait_until(st_sender *s, uint64_t t) { wait_until_spin(s, t, 500000ULL); }

static void format_id(guint64 id, char *out, size_t len)
{
    snprintf(out, len, "%02X-%02X-%02X-%02X-%02X-%02X-%02X-%02X",
             (unsigned)(id >> 56) & 0xff, (unsigned)(id >> 48) & 0xff, (unsigned)(id >> 40) & 0xff,
             (unsigned)(id >> 32) & 0xff, (unsigned)(id >> 24) & 0xff, (unsigned)(id >> 16) & 0xff,
             (unsigned)(id >> 8) & 0xff, (unsigned)id & 0xff);
}

static gboolean ptp_cb(guint8 domain, const GstStructure *st, gpointer user)
{
    st_sender *s = user;
    if (domain == s->cfg.ptp_domain && g_str_equal(gst_structure_get_name(st), GST_PTP_STATISTICS_BEST_MASTER_CLOCK_SELECTED)) {
        guint64 gm = 0;
        if (gst_structure_get_uint64(st, "grandmaster-clock-id", &gm)) {
            pthread_mutex_lock(&s->slock);
            format_id(gm, s->gm, sizeof s->gm);
            pthread_mutex_unlock(&s->slock);
        }
    }
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* Netzwerk                                                           */

static int open_tx(const char *dst, int port, const st_sender_config *c, int dscp, char *err, size_t len)
{
    struct in_addr d, ifa;
    if (inet_pton(AF_INET, dst, &d) != 1) {
        snprintf(err, len, "Ungültige Zieladresse „%s“.", dst);
        return -1;
    }
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        snprintf(err, len, "Socket: %s", strerror(errno));
        return -1;
    }
    int sz = 8 * 1024 * 1024;
    while (sz >= 256 * 1024 && setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz) != 0) sz /= 2;
    int tos = dscp << 2;
    setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof tos);
    if (c->iface_addr[0] && inet_pton(AF_INET, c->iface_addr, &ifa) == 1) {
        struct sockaddr_in src = { .sin_family = AF_INET, .sin_addr = ifa, .sin_port = 0 };
        bind(fd, (struct sockaddr *)&src, sizeof src);
        if (IN_MULTICAST(ntohl(d.s_addr))) setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifa, sizeof ifa);
    }
#if defined(__APPLE__) && defined(IP_BOUND_IF)
    if (c->iface_name[0]) {
        unsigned idx = if_nametoindex(c->iface_name);
        if (idx) setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx);
    }
#endif
    unsigned char ttl = (unsigned char)(c->ttl > 0 ? c->ttl : 16), loop = 1;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof loop);
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr = d, .sin_port = htons((uint16_t)port) };
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        snprintf(err, len, "Ziel %s:%d nicht erreichbar: %s", dst, port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static void tx(st_sender *s, int fd, const uint8_t *p, size_t n)
{
    for (int tries = 0; tries < 50; tries++) {
        ssize_t r = send(fd, p, n, 0);
        if (r == (ssize_t)n) return;
        if (r < 0 && (errno == ENOBUFS || errno == EAGAIN)) {
            struct timespec ts = { 0, 20000 };
            nanosleep(&ts, NULL);
            continue;
        }
        break;
    }
    pthread_mutex_lock(&s->slock);
    s->st.send_errors++;
    snprintf(s->st.last_error, sizeof s->st.last_error, "Senden fehlgeschlagen: %s", strerror(errno));
    pthread_mutex_unlock(&s->slock);
}

/* ------------------------------------------------------------------ */
/* Bildformate                                                        */

static inline void put_pgroup(uint8_t *p, int cb, int y0, int cr, int y1)
{
    uint64_t v = ((uint64_t)(cb & 0x3ff) << 30) | ((uint64_t)(y0 & 0x3ff) << 20) |
                 ((uint64_t)(cr & 0x3ff) << 10) | (uint64_t)(y1 & 0x3ff);
    p[0] = (uint8_t)(v >> 32); p[1] = (uint8_t)(v >> 24); p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 8);  p[4] = (uint8_t)v;
}

static void fill_rect(st_sender *s, uint8_t *f, int x0, int y0, int w, int h, int Y, int Cb, int Cr)
{
    int W = s->cfg.width, H = s->cfg.height;
    int xs = x0 < 0 ? 0 : (x0 & ~1), xe = x0 + w > W ? W : x0 + w;
    int ys = y0 < 0 ? 0 : y0, ye = y0 + h > H ? H : y0 + h;
    for (int y = ys; y < ye; y++) {
        uint8_t *row = f + (size_t)y * s->line_bytes;
        for (int x = xs; x + 2 <= xe; x += 2) put_pgroup(row + (size_t)(x / 2) * 5, Cb, Y, Cr, Y);
    }
}

/* 75-%-Farbbalken nach BT.709 (10 Bit, begrenzter Bereich) */
static void make_bars(st_sender *s, uint8_t *f)
{
    static const int bars[8][3] = {
        { 721, 512, 512 }, { 674, 176, 543 }, { 581, 589, 176 }, { 534, 253, 207 },
        { 251, 771, 817 }, { 204, 435, 848 }, { 111, 848, 481 }, { 64, 512, 512 },
    };
    int W = s->cfg.width, H = s->cfg.height;
    if (s->cfg.pattern == ST_PATTERN_SYNC) {
        fill_rect(s, f, 0, 0, W, H, 64, 512, 512);
        return;
    }
    int bw = W / 7;
    for (int i = 0; i < 7; i++)
        fill_rect(s, f, i * bw, 0, (i == 6 ? W - 6 * bw : bw), H * 2 / 3, bars[i][0], bars[i][1], bars[i][2]);
    fill_rect(s, f, 0, H * 2 / 3, W, H - H * 2 / 3, 64, 512, 512);
    /* Graustufen unten (10 Bit Rampe in 16 Stufen) */
    for (int i = 0; i < 16; i++)
        fill_rect(s, f, i * W / 16, H * 3 / 4, W / 16 + 2, H / 12, 64 + i * 876 / 15, 512, 512);
}

static int convert_into(st_sender *s, uint8_t *dst, st_src_format fmt, const uint8_t *p0, int s0,
                        const uint8_t *p1, int s1)
{
    int W = s->cfg.width, H = s->cfg.height;
    for (int y = 0; y < H; y++) {
        uint8_t *o = dst + (size_t)y * s->line_bytes;
        switch (fmt) {
        case ST_SRCFMT_UYVP:
            memcpy(o, p0 + (size_t)y * s0, s->line_bytes);
            break;
        case ST_SRCFMT_UYVY8: {
            const uint8_t *r = p0 + (size_t)y * s0;
            for (int x = 0; x < W; x += 2, r += 4, o += 5)
                put_pgroup(o, r[0] << 2, r[1] << 2, r[2] << 2, r[3] << 2);
            break;
        }
        case ST_SRCFMT_X422: {
            const uint16_t *yl = (const uint16_t *)(p0 + (size_t)y * s0);
            const uint16_t *cl = (const uint16_t *)(p1 + (size_t)y * s1);
            for (int x = 0; x < W; x += 2, o += 5)
                put_pgroup(o, cl[x] >> 6, yl[x] >> 6, cl[x + 1] >> 6, yl[x + 1] >> 6);
            break;
        }
        case ST_SRCFMT_BGRA8: {
            const uint8_t *r = p0 + (size_t)y * s0;
            for (int x = 0; x < W; x += 2, r += 8, o += 5) {
                /* BT.709, begrenzter Bereich, 10 Bit */
                double R0 = r[2] / 255.0, G0 = r[1] / 255.0, B0 = r[0] / 255.0;
                double R1 = r[6] / 255.0, G1 = r[5] / 255.0, B1 = r[4] / 255.0;
                double Y0 = 0.2126 * R0 + 0.7152 * G0 + 0.0722 * B0;
                double Y1 = 0.2126 * R1 + 0.7152 * G1 + 0.0722 * B1;
                double R = (R0 + R1) / 2, G = (G0 + G1) / 2, B = (B0 + B1) / 2;
                double Ya = 0.2126 * R + 0.7152 * G + 0.0722 * B;
                double Cb = (B - Ya) / 1.8556, Cr = (R - Ya) / 1.5748;
                put_pgroup(o, (int)lround(512 + 896 * Cb), (int)lround(64 + 876 * Y0),
                           (int)lround(512 + 896 * Cr), (int)lround(64 + 876 * Y1));
            }
            break;
        }
        default:
            return -1;
        }
    }
    return 0;
}

int st_sender_push_video(st_sender *s, st_src_format fmt, const uint8_t *p0, int s0,
                         const uint8_t *p1, int s1, int w, int h)
{
    if (!s || w != s->cfg.width || h != s->cfg.height || !p0) return -1;
    if (fmt == ST_SRCFMT_X422 && !p1) return -1;
    /* Schreibpuffer ist nur für diesen Aufrufer: ohne Lock umrechnen */
    pthread_mutex_lock(&s->vlock);
    uint8_t *w_buf = s->write_buf;
    pthread_mutex_unlock(&s->vlock);
    if (convert_into(s, w_buf, fmt, p0, s0, p1, s1) != 0) return -1;
    pthread_mutex_lock(&s->vlock);
    uint8_t *t = s->ready_buf;
    s->ready_buf = s->write_buf;
    s->write_buf = t;
    s->ready_new = 1;
    s->last_push_us = mono_ns() / 1000;
    pthread_mutex_unlock(&s->vlock);
    pthread_mutex_lock(&s->slock);
    s->st.frames_from_source++;
    pthread_mutex_unlock(&s->slock);
    return 0;
}

void st_sender_clear_source(st_sender *s)
{
    pthread_mutex_lock(&s->vlock);
    s->last_push_us = 0;
    pthread_mutex_unlock(&s->vlock);
    pthread_mutex_lock(&s->alock);
    s->last_audio_push_us = 0;
    s->ring_fill = s->ring_r = s->ring_w = 0;
    pthread_mutex_unlock(&s->alock);
}

int st_sender_push_audio(st_sender *s, const float *in, int frames, int channels)
{
    if (!s || !s->ring || channels <= 0) return -1;
    int N = s->cfg.audio_channels;
    pthread_mutex_lock(&s->alock);
    for (int f = 0; f < frames; f++) {
        if (s->ring_fill >= AUDIO_RING_FRAMES) { /* voll: ältesten Block verwerfen */
            s->ring_r = (s->ring_r + 1) % AUDIO_RING_FRAMES;
            s->ring_fill--;
        }
        float *dst = s->ring + s->ring_w * (size_t)N;
        for (int c = 0; c < N; c++) dst[c] = c < channels ? in[(size_t)f * channels + c] : 0.0f;
        s->ring_w = (s->ring_w + 1) % AUDIO_RING_FRAMES;
        s->ring_fill++;
    }
    s->last_audio_push_us = mono_ns() / 1000;
    pthread_mutex_unlock(&s->alock);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Video-Thread                                                       */

static void *video_thread(void *arg)
{
    st_sender *s = arg;
    const st_sender_config *c = &s->cfg;
    uint64_t frame_ns = (uint64_t)NS * (uint64_t)c->fps_den / (uint64_t)c->fps_num;
    int H = c->height;
    int total_lines = H == 1080 ? 1125 : H == 720 ? 750 : H + H / 24;
    uint64_t active_ns = frame_ns * (uint64_t)H / (uint64_t)total_lines;
    uint64_t tro = frame_ns * 43 / (uint64_t)total_lines;  /* TRO_DEFAULT (ST 2110-21) für progressiv */
    size_t npk = (size_t)H * (size_t)s->segs_per_line;
    uint8_t pkt[1500];
    uint64_t t = (media_now(s) / frame_ns + 2) * frame_ns;

    while (!s->stop) {
        wait_until(s, t);
        if (s->stop) break;
        uint64_t now = media_now(s);
        if (now > t + frame_ns) { /* weit zurück (z. B. Sprung): neu ausrichten */
            t = (now / frame_ns + 1) * frame_ns;
            continue;
        }
        /* Quelle oder Testbild */
        int64_t now_us = mono_ns() / 1000;
        int from_source = 0, repeated = 0;
        pthread_mutex_lock(&s->vlock);
        if (s->last_push_us && now_us - s->last_push_us < 500000) {
            from_source = 1;
            if (s->ready_new) {
                uint8_t *tmp = s->send_buf;
                s->send_buf = s->ready_buf;
                s->ready_buf = tmp;
                s->ready_new = 0;
            } else {
                repeated = 1;
            }
        }
        pthread_mutex_unlock(&s->vlock);
        uint64_t fnum = t / frame_ns;
        int fps_int = (int)((uint64_t)c->fps_num / (uint64_t)c->fps_den);
        if (!from_source) {
            memcpy(s->send_buf, s->frame_base, s->frame_bytes);
            int W = c->width;
            int in_sec = (int)((t % NS) / frame_ns);
            if (c->pattern == ST_PATTERN_SYNC) {
                if (t % NS < frame_ns) fill_rect(s, s->send_buf, W / 2 - W / 10, H / 2 - W / 10, W / 5, W / 5, 940, 512, 512);
            } else {
                int bar = fps_int > 0 ? (in_sec % fps_int) * (W - W / 30) / fps_int : 0;
                fill_rect(s, s->send_buf, bar, H * 2 / 3 + H / 40, W / 30, H / 20, 940, 512, 512);
            }
        }
        uint32_t rtp_ts = (uint32_t)st_ns_to_ticks(t, 90000);
        /* Pakete gleichmäßig über die aktive Zeit verteilen (Narrow Linear) */
        size_t i = 0;
        for (int line = 0; line < H && !s->stop; line++) {
            const uint8_t *row = s->send_buf + (size_t)line * s->line_bytes;
            for (int seg = 0; seg < s->segs_per_line; seg++, i++) {
                size_t off_b = (size_t)seg * MAX_PAYLOAD;
                size_t len = s->line_bytes - off_b < MAX_PAYLOAD ? s->line_bytes - off_b : MAX_PAYLOAD;
                uint64_t target = t + tro + active_ns * i / npk;
                if (media_now(s) < target) wait_until(s, target);
                uint64_t sent_at = media_now(s);
                if (sent_at > target + 200000) {
                    pthread_mutex_lock(&s->slock);
                    s->st.late_packets++;
                    double l = (double)(sent_at - target) / 1000.0;
                    if (l > s->st.max_late_us) s->st.max_late_us = l;
                    pthread_mutex_unlock(&s->slock);
                }
                int marker = (i == npk - 1);
                s->vseq_ext++;
                uint16_t seq = (uint16_t)s->vseq_ext;
                uint16_t esn = (uint16_t)(s->vseq_ext >> 16);
                pkt[0] = 0x80;
                pkt[1] = (uint8_t)((marker ? 0x80 : 0) | (c->video_pt & 0x7f));
                pkt[2] = (uint8_t)(seq >> 8); pkt[3] = (uint8_t)seq;
                pkt[4] = (uint8_t)(rtp_ts >> 24); pkt[5] = (uint8_t)(rtp_ts >> 16);
                pkt[6] = (uint8_t)(rtp_ts >> 8); pkt[7] = (uint8_t)rtp_ts;
                pkt[8] = (uint8_t)(s->ssrc_v >> 24); pkt[9] = (uint8_t)(s->ssrc_v >> 16);
                pkt[10] = (uint8_t)(s->ssrc_v >> 8); pkt[11] = (uint8_t)s->ssrc_v;
                pkt[12] = (uint8_t)(esn >> 8); pkt[13] = (uint8_t)esn;
                int px_off = (int)(off_b / 5 * 2);
                pkt[14] = (uint8_t)(len >> 8); pkt[15] = (uint8_t)len;
                pkt[16] = (uint8_t)((line >> 8) & 0x7f); pkt[17] = (uint8_t)line;   /* F=0 */
                pkt[18] = (uint8_t)((px_off >> 8) & 0x7f); pkt[19] = (uint8_t)px_off; /* C=0 */
                memcpy(pkt + 20, row + off_b, len);
                tx(s, s->vfd, pkt, 20 + len);
                s->vbytes += 20 + len;
            }
        }
        pthread_mutex_lock(&s->slock);
        s->st.frames_sent++;
        s->st.video_packets += npk;
        if (repeated) s->st.frames_repeated++;
        pthread_mutex_unlock(&s->slock);
        (void)fnum;
        t += frame_ns;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Audio-Thread                                                       */

static void *audio_thread(void *arg)
{
    st_sender *s = arg;
    const st_sender_config *c = &s->cfg;
    int N = c->audio_channels;
    uint64_t pt_ns = (uint64_t)c->audio_ptime_us * 1000ULL;
    int spp = (int)(48000ULL * (uint64_t)c->audio_ptime_us / 1000000ULL);
    uint8_t pkt[1500];
    float frame[64];
    uint64_t t = (media_now(s) / pt_ns + 2) * pt_ns;
    double phase = 0;
    int started = 0;

    while (!s->stop) {
        wait_until_spin(s, t + 50000, 0); /* Audio: schlafen genügt (Paketzeit ≥ 125 µs) */
        if (s->stop) break;
        uint64_t now = media_now(s);
        if (now > t + 100 * pt_ns) { t = (now / pt_ns + 1) * pt_ns; continue; }
        uint32_t ts = (uint32_t)st_ns_to_ticks(t, 48000);
        int64_t now_us = mono_ns() / 1000;
        pthread_mutex_lock(&s->alock);
        int from_source = s->last_audio_push_us && now_us - s->last_audio_push_us < 500000;
        if (from_source && !started && s->ring_fill < 48 * 40) from_source = 2; /* Vorpuffer 40 ms */
        else if (from_source) started = 1;
        if (!from_source) started = 0;
        uint8_t *p = pkt + 12;
        for (int f = 0; f < spp; f++) {
            if (from_source == 1) {
                if (s->ring_fill > 0) {
                    memcpy(frame, s->ring + s->ring_r * (size_t)N, sizeof(float) * (size_t)N);
                    s->ring_r = (s->ring_r + 1) % AUDIO_RING_FRAMES;
                    s->ring_fill--;
                } else {
                    memset(frame, 0, sizeof(float) * (size_t)N);
                    if (f == 0) {
                        pthread_mutex_lock(&s->slock);
                        s->st.audio_underruns++;
                        pthread_mutex_unlock(&s->slock);
                    }
                }
            } else if (from_source == 2) {
                memset(frame, 0, sizeof(float) * (size_t)N);
            } else {
                /* Testton */
                uint64_t ts_ns = t + (uint64_t)f * NS / 48000ULL;
                float v = 0;
                if (c->pattern == ST_PATTERN_SYNC) {
                    if (ts_ns % NS < 20000000ULL) v = 0.5f * (float)sin(2 * M_PI * 1000.0 * (double)(ts_ns % NS) / 1e9);
                } else {
                    v = 0.1259f * (float)sin(phase); /* −18 dBFS */
                    phase += 2 * M_PI * 1000.0 / 48000.0;
                    if (phase > 2 * M_PI) phase -= 2 * M_PI;
                }
                for (int ch = 0; ch < N; ch++) frame[ch] = v;
            }
            for (int ch = 0; ch < N; ch++) {
                float x = frame[ch];
                if (x > 1) x = 1;
                if (x < -1) x = -1;
                int32_t q = (int32_t)lrintf(x * 8388607.0f);
                *p++ = (uint8_t)(q >> 16); *p++ = (uint8_t)(q >> 8); *p++ = (uint8_t)q;
            }
        }
        size_t fill = s->ring_fill;
        pthread_mutex_unlock(&s->alock);
        s->aseq++;
        pkt[0] = 0x80;
        pkt[1] = (uint8_t)(c->audio_pt & 0x7f);
        pkt[2] = (uint8_t)(s->aseq >> 8); pkt[3] = (uint8_t)s->aseq;
        pkt[4] = (uint8_t)(ts >> 24); pkt[5] = (uint8_t)(ts >> 16); pkt[6] = (uint8_t)(ts >> 8); pkt[7] = (uint8_t)ts;
        pkt[8] = (uint8_t)(s->ssrc_a >> 24); pkt[9] = (uint8_t)(s->ssrc_a >> 16);
        pkt[10] = (uint8_t)(s->ssrc_a >> 8); pkt[11] = (uint8_t)s->ssrc_a;
        tx(s, s->afd, pkt, (size_t)(p - pkt));
        pthread_mutex_lock(&s->slock);
        s->st.audio_packets++;
        s->st.audio_fill_ms = (double)fill / 48.0;
        pthread_mutex_unlock(&s->slock);
        t += pt_ns;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */

st_sender *st_sender_new(const st_sender_config *cfg, char *err, size_t len)
{
    if (st_init(err, len) != 0) return NULL;
    st_sender_config c = *cfg;
    if (!c.has_video && !c.has_audio) { snprintf(err, len, "Weder Video noch Audio gewählt."); return NULL; }
    if (c.has_video) {
        if (c.width <= 0 || c.height <= 0 || c.width % 2 || c.fps_num <= 0 || c.fps_den <= 0) {
            snprintf(err, len, "Ungültiges Videoformat.");
            return NULL;
        }
        if (!c.video_pt) c.video_pt = 96;
        if (!c.video_dscp) c.video_dscp = 34;
    }
    if (c.has_audio) {
        if (c.audio_channels < 1 || c.audio_channels > 16) { snprintf(err, len, "1 bis 16 Audiokanäle."); return NULL; }
        if (c.audio_ptime_us != 125 && c.audio_ptime_us != 1000) c.audio_ptime_us = 1000;
        if (c.audio_channels * 3 * (48 * c.audio_ptime_us / 1000) > 1440) {
            snprintf(err, len, "%d Kanäle passen bei 1 ms nicht in ein Paket. Paketzeit 0,125 ms wählen (ST 2110-30 Level C).", c.audio_channels);
            return NULL;
        }
        if (!c.audio_pt) c.audio_pt = 97;
        if (!c.audio_dscp) c.audio_dscp = 46;
    }
    if (c.ptp_domain <= 0) c.ptp_domain = 127;
    st_sender *s = calloc(1, sizeof *s);
    s->cfg = c;
    s->vfd = s->afd = -1;
    pthread_mutex_init(&s->vlock, NULL);
    pthread_mutex_init(&s->alock, NULL);
    pthread_mutex_init(&s->slock, NULL);
    s->ssrc_v = c.ssrc_video ? c.ssrc_video : (uint32_t)g_random_int();
    s->ssrc_a = c.ssrc_audio ? c.ssrc_audio : (uint32_t)g_random_int();
    s->vseq_ext = g_random_int();
    s->aseq = (uint16_t)g_random_int();
    if (c.has_video) {
        s->line_bytes = (size_t)c.width / 2 * 5;
        s->segs_per_line = (int)((s->line_bytes + MAX_PAYLOAD - 1) / MAX_PAYLOAD);
        s->frame_bytes = s->line_bytes * (size_t)c.height;
        s->frame_base = malloc(s->frame_bytes);
        s->send_buf = malloc(s->frame_bytes);
        s->ready_buf = malloc(s->frame_bytes);
        s->write_buf = malloc(s->frame_bytes);
        if (!s->frame_base || !s->send_buf || !s->ready_buf || !s->write_buf) {
            snprintf(err, len, "Zu wenig Speicher.");
            st_sender_free(s);
            return NULL;
        }
        make_bars(s, s->frame_base);
        memcpy(s->send_buf, s->frame_base, s->frame_bytes);
    }
    if (c.has_audio) s->ring = calloc((size_t)AUDIO_RING_FRAMES * (size_t)c.audio_channels, sizeof(float));
    return s;
}

int st_sender_start(st_sender *s, char *err, size_t len)
{
    const st_sender_config *c = &s->cfg;
    if (c->use_ptp) {
        if (!gst_ptp_is_initialized()) {
            gchar *ifs[2] = { (gchar *)c->iface_name, NULL };
            gst_ptp_init(GST_PTP_CLOCK_ID_NONE, c->iface_name[0] ? ifs : NULL);
        }
        if (gst_ptp_is_initialized()) {
            s->ptp_cb = gst_ptp_statistics_callback_add(ptp_cb, s, NULL);
            s->ptp = gst_ptp_clock_new("st-send-ptp", (guint)c->ptp_domain);
            if (s->ptp && gst_clock_wait_for_sync(s->ptp, 4 * GST_SECOND)) s->ptp_locked = 1;
        }
    }
    if (c->has_video && (s->vfd = open_tx(c->video_addr, c->video_port, c, c->video_dscp, err, len)) < 0) return -1;
    if (c->has_audio && (s->afd = open_tx(c->audio_addr, c->audio_port, c, c->audio_dscp, err, len)) < 0) return -1;
    s->stop = 0;
    if (c->has_video) s->vthread_ok = pthread_create(&s->vthread, NULL, video_thread, s) == 0;
    if (c->has_audio) s->athread_ok = pthread_create(&s->athread, NULL, audio_thread, s) == 0;
    pthread_mutex_lock(&s->slock);
    s->st.running = 1;
    s->st.ptp_locked = s->ptp_locked;
    pthread_mutex_unlock(&s->slock);
    return 0;
}

void st_sender_stop(st_sender *s)
{
    if (!s) return;
    s->stop = 1;
    if (s->vthread_ok) { pthread_join(s->vthread, NULL); s->vthread_ok = 0; }
    if (s->athread_ok) { pthread_join(s->athread, NULL); s->athread_ok = 0; }
    if (s->vfd >= 0) close(s->vfd);
    if (s->afd >= 0) close(s->afd);
    s->vfd = s->afd = -1;
    if (s->ptp_cb) { gst_ptp_statistics_callback_remove(s->ptp_cb); s->ptp_cb = 0; }
    if (s->ptp) { gst_object_unref(s->ptp); s->ptp = NULL; }
    s->st.running = 0;
}

void st_sender_free(st_sender *s)
{
    if (!s) return;
    st_sender_stop(s);
    free(s->frame_base); free(s->send_buf); free(s->ready_buf); free(s->write_buf); free(s->ring);
    pthread_mutex_destroy(&s->vlock);
    pthread_mutex_destroy(&s->alock);
    pthread_mutex_destroy(&s->slock);
    free(s);
}

int st_sender_sdp(st_sender *s, int video, char *out, size_t len)
{
    const st_sender_config *c = &s->cfg;
    if ((video && !c->has_video) || (!video && !c->has_audio)) return -1;
    char refclk[128];
    pthread_mutex_lock(&s->slock);
    if (s->ptp_locked && s->gm[0]) snprintf(refclk, sizeof refclk, "ptp=IEEE1588-2008:%s:%d", s->gm, c->ptp_domain);
    else if (s->ptp_locked) snprintf(refclk, sizeof refclk, "ptp=IEEE1588-2008:traceable");
    else snprintf(refclk, sizeof refclk, "localmac=%s", c->local_mac[0] ? c->local_mac : "00-00-00-00-00-00");
    pthread_mutex_unlock(&s->slock);
    const char *src = c->iface_addr[0] ? c->iface_addr : "0.0.0.0";
    const char *dst = video ? c->video_addr : c->audio_addr;
    struct in_addr d;
    int mcast = inet_pton(AF_INET, dst, &d) == 1 && IN_MULTICAST(ntohl(d.s_addr));
    char conn[128], filt[256] = "";
    if (mcast) {
        snprintf(conn, sizeof conn, "c=IN IP4 %s/%d\r\n", dst, c->ttl > 0 ? c->ttl : 16);
        snprintf(filt, sizeof filt, "a=source-filter: incl IN IP4 %s %s\r\n", dst, src);
    } else {
        snprintf(conn, sizeof conn, "c=IN IP4 %s\r\n", dst);
    }
    uint32_t sess = video ? s->ssrc_v : s->ssrc_a;
    int n;
    if (video) {
        char fps[32];
        if (c->fps_den == 1) snprintf(fps, sizeof fps, "%d", c->fps_num);
        else snprintf(fps, sizeof fps, "%d/%d", c->fps_num, c->fps_den);
        n = snprintf(out, len,
                     "v=0\r\no=- %u 0 IN IP4 %s\r\ns=%s Video\r\nt=0 0\r\n"
                     "m=video %d RTP/AVP %d\r\n%s%s"
                     "a=rtpmap:%d raw/90000\r\n"
                     "a=fmtp:%d sampling=YCbCr-4:2:2; width=%d; height=%d; exactframerate=%s; depth=10; TCS=SDR; colorimetry=BT709; PM=2110GPM; SSN=ST2110-20:2017; TP=2110TPNL; \r\n"
                     "a=ts-refclk:%s\r\na=mediaclk:direct=0\r\n",
                     sess, src, c->session_name[0] ? c->session_name : "2110 Viewer", c->video_port, c->video_pt, conn, filt,
                     c->video_pt, c->video_pt, c->width, c->height, fps, refclk);
    } else {
        n = snprintf(out, len,
                     "v=0\r\no=- %u 0 IN IP4 %s\r\ns=%s Audio\r\nt=0 0\r\n"
                     "m=audio %d RTP/AVP %d\r\n%s%s"
                     "a=rtpmap:%d L24/48000/%d\r\na=ptime:%s\r\n"
                     "a=ts-refclk:%s\r\na=mediaclk:direct=0\r\n",
                     sess, src, c->session_name[0] ? c->session_name : "2110 Viewer", c->audio_port, c->audio_pt, conn, filt,
                     c->audio_pt, c->audio_channels, c->audio_ptime_us == 125 ? "0.125" : "1", refclk);
    }
    return (n < 0 || (size_t)n >= len) ? -1 : n;
}

void st_sender_get_stats(st_sender *s, st_sender_stats *o)
{
    int64_t now = mono_ns();
    pthread_mutex_lock(&s->slock);
    if (s->rate_t_prev) {
        double dt = (double)(now - s->rate_t_prev) / 1e9;
        if (dt > 0.2) {
            s->st.video_mbps = (double)(s->vbytes - s->vbytes_prev) * 8.0 / dt / 1e6;
            s->vbytes_prev = s->vbytes;
            s->rate_t_prev = now;
        }
    } else {
        s->rate_t_prev = now;
        s->vbytes_prev = s->vbytes;
    }
    s->st.ptp_locked = s->ptp_locked && s->ptp && gst_clock_is_synced(s->ptp);
    snprintf(s->st.ptp_grandmaster, sizeof s->st.ptp_grandmaster, "%s", s->gm);
    *o = s->st;
    pthread_mutex_unlock(&s->slock);
}
