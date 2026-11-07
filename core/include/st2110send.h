/*
 * st2110send – Sender für ST 2110-20 (Video) und ST 2110-30 (Audio).
 *
 * Eigener Paketierer (RFC 4175 / ST 2110-20 GPM, YCbCr 4:2:2 10 Bit) mit
 * gleichmäßiger Paketverteilung über die aktive Bildzeit (ST 2110-21
 * „Narrow Linear“, softwaregetaktet) und L24-Audio (ST 2110-30). RTP-
 * Zeitstempel sind auf die SMPTE-Epoche ausgerichtet (ST 2059-1): PTP-Zeit,
 * wenn verfügbar, sonst Systemzeit + 37 s als TAI-Näherung.
 *
 * Bildquelle: Bilder werden über st_sender_push_video() geliefert (z. B. aus
 * AVFoundation: Datei oder Kamera); ohne Bilder sendet der Sender ein Testbild.
 */
#ifndef ST2110SEND_H
#define ST2110SEND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ST_SRCFMT_UYVY8 = 1,   /* gepackt 8 Bit (CoreVideo '2vuy') */
    ST_SRCFMT_X422 = 2,    /* 2 Ebenen, 16 Bit je Wert, 10 Bit oben ('x422') */
    ST_SRCFMT_UYVP = 3,    /* bereits ST-2110-pgroup (10 Bit) */
    ST_SRCFMT_BGRA8 = 4    /* BGRA 8 Bit (wird nach BT.709 umgerechnet) */
} st_src_format;

typedef enum {
    ST_PATTERN_BARS = 0,   /* 75-%-Farbbalken, Laufbalken, 1 kHz −18 dBFS */
    ST_PATTERN_SYNC = 1    /* Schwarz, weißer Blitz + Piep je Sekunde (Lippensynchrontest) */
} st_pattern;

typedef struct {
    char iface_name[32];
    char iface_addr[64];       /* Quelladresse (SDP, Multicast-Schnittstelle) */
    char local_mac[32];        /* für a=ts-refclk:localmac (ohne PTP) */
    char session_name[128];
    int ttl;                   /* Standard 16 */

    int has_video;
    char video_addr[64];
    int video_port;
    int width, height;
    int fps_num, fps_den;
    int video_pt;              /* 96 */
    int video_dscp;            /* 34 = AF41 */

    int has_audio;
    char audio_addr[64];
    int audio_port;
    int audio_channels;        /* 1..16 */
    int audio_ptime_us;        /* 1000 oder 125 */
    int audio_pt;              /* 97 */
    int audio_dscp;            /* 46 = EF */

    int use_ptp;               /* 1 = PTP-Zeit als Zeitbezug (passiver Slave) */
    int ptp_domain;            /* 127 */
    st_pattern pattern;        /* Testbild, solange keine Bilder kommen */
    uint32_t ssrc_video, ssrc_audio; /* 0 = zufällig */
} st_sender_config;

typedef struct {
    int running;
    int ptp_locked;
    char ptp_grandmaster[32];
    uint64_t frames_sent;
    uint64_t video_packets;
    uint64_t audio_packets;
    uint64_t frames_from_source;   /* über push_video gelieferte Bilder */
    uint64_t frames_repeated;      /* Bild wiederholt (Quelle langsamer) */
    uint64_t audio_underruns;      /* Stille eingefügt */
    uint64_t late_packets;         /* > 200 µs nach Sollzeit gesendet */
    double max_late_us;
    double video_mbps;
    double audio_fill_ms;          /* Audiopuffer */
    uint64_t send_errors;
    char last_error[256];
} st_sender_stats;

typedef struct st_sender st_sender;

st_sender *st_sender_new(const st_sender_config *cfg, char *err, size_t err_len);
int st_sender_start(st_sender *s, char *err, size_t err_len);
void st_sender_stop(st_sender *s);
void st_sender_free(st_sender *s);

/* Bild liefern (beliebiger Thread). Größe muss width×height entsprechen. */
int st_sender_push_video(st_sender *s, st_src_format fmt,
                         const uint8_t *plane0, int stride0,
                         const uint8_t *plane1, int stride1,
                         int width, int height);
/* Audio liefern: Float, verschachtelt, 48 kHz. Kanäle über audio_channels werden verworfen. */
int st_sender_push_audio(st_sender *s, const float *interleaved, int frames, int channels);
/* Quelle beendet: wieder Testbild senden */
void st_sender_clear_source(st_sender *s);

/* SDP für Video (video=1) bzw. Audio (video=0). Rückgabe Länge oder -1. */
int st_sender_sdp(st_sender *s, int video, char *out, size_t out_len);
void st_sender_get_stats(st_sender *s, st_sender_stats *out);

#ifdef __cplusplus
}
#endif
#endif
