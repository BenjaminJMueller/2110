/*
 * st2110core – Empfangskern für SMPTE ST 2110-20 (Video) und ST 2110-30 (Audio)
 *
 * Diese C-Schnittstelle kapselt GStreamer vollständig. Die macOS-Oberfläche
 * (Swift) sieht keine GStreamer-Typen, nur diese Strukturen und Funktionen.
 * Der Kern ist plattformneutral (macOS, Linux) und wird unter Linux mit
 * synthetischen Streams getestet.
 *
 * Alle Texte für Endanwender sind deutsch und UTF-8-kodiert.
 */
#ifndef ST2110CORE_H
#define ST2110CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ST_STR_SHORT 32
#define ST_STR 64
#define ST_STR_LONG 256
#define ST_MAX_AUDIO_CHANNELS 64

/* ------------------------------------------------------------------ */
/* SDP                                                                */
/* ------------------------------------------------------------------ */

typedef enum {
    ST_MEDIA_UNKNOWN = 0,
    ST_MEDIA_VIDEO = 1,
    ST_MEDIA_AUDIO = 2,
    ST_MEDIA_DATA = 3 /* ST 2110-40 Ancillary oder anderes */
} st_media_kind;

typedef struct {
    st_media_kind kind;
    char encoding[ST_STR_SHORT];   /* "raw", "L24", "L16", "smpte291", "jxsv" ... */
    int payload_type;
    int clock_rate;
    int port;
    char dest_addr[ST_STR];        /* Zieladresse aus c= (ohne /TTL) */
    int ttl;
    char source_addr[ST_STR];      /* Quelladresse aus a=source-filter (SSM) */
    char origin_addr[ST_STR];      /* Adresse aus o= */
    char session_name[ST_STR_LONG];
    char media_title[ST_STR_LONG]; /* i= */
    char mid[ST_STR_SHORT];
    int dup_group;                 /* gehört zu a=group:DUP (ST 2022-7) */

    /* Video (ST 2110-20 fmtp) */
    char sampling[ST_STR_SHORT];
    int depth;
    int width;
    int height;
    int fps_num;
    int fps_den;
    int interlaced;
    int segmented;
    char colorimetry[ST_STR_SHORT];
    char tcs[ST_STR_SHORT];
    char range[ST_STR_SHORT];
    char pm[ST_STR_SHORT];
    char ssn[ST_STR_SHORT];
    char tp[ST_STR_SHORT];

    /* Audio (ST 2110-30) */
    int channels;
    double ptime_ms;
    char channel_order[ST_STR_LONG];

    /* Zeitbezug (RFC 7273 / ST 2110-10) */
    int has_ptp_refclk;
    char ptp_gmid[ST_STR_SHORT];   /* z. B. "08-00-11-FF-FE-21-E1-B0" */
    int ptp_domain;                /* -1 = nicht angegeben */
    int refclk_localmac;           /* a=ts-refclk:localmac=... */
    char refclk_raw[ST_STR_LONG];
    int has_mediaclk;
    int mediaclk_direct;
    long long mediaclk_offset;
} st_sdp_media;

/* Parst SDP-Text. Liefert die Anzahl gefundener m=-Abschnitte (>=0)
 * oder -1 bei einem Fehler (Text in err). */
int st_sdp_parse(const char *text, st_sdp_media *out, int max_media,
                 char *err, size_t err_len);

typedef enum {
    ST_SUPPORT_OK = 0,
    ST_SUPPORT_WARNING = 1,  /* wird empfangen, aber mit Hinweis */
    ST_SUPPORT_NO = 2        /* wird nicht unterstützt */
} st_support;

/* Prüft, ob die Medienbeschreibung empfangen werden kann. msg erhält eine
 * verständliche Begründung mit Abhilfe (deutsch). */
st_support st_check_media(const st_sdp_media *m, char *msg, size_t msg_len);

/* Erzeugt aus Parametern ein SDP (für die manuelle Experteneingabe). */
int st_sdp_write(const st_sdp_media *m, char *out, size_t out_len);

/* ------------------------------------------------------------------ */
/* Medienuhr (reine Funktionen, separat getestet)                      */
/* ------------------------------------------------------------------ */

/* Erweitert einen 32-Bit-RTP-Zeitstempel auf 64 Bit, sodass er dem
 * Referenzzeitpunkt ref_ns (Nanosekunden im PTP-/TAI-Zeitmaßstab) am nächsten liegt. */
uint64_t st_rtp_unwrap(uint32_t rtp_ts, uint32_t clock_rate, uint64_t ref_ns);
/* Wandelt 64-Bit-RTP-Ticks in Nanosekunden. */
uint64_t st_ticks_to_ns(uint64_t ticks, uint32_t clock_rate);
/* Wandelt Nanosekunden in 64-Bit-RTP-Ticks (abgerundet, wie ST 2059-1). */
uint64_t st_ns_to_ticks(uint64_t ns, uint32_t clock_rate);

/* ------------------------------------------------------------------ */
/* Empfänger                                                          */
/* ------------------------------------------------------------------ */

typedef enum {
    /* Jeder Strom wird bei Ankunft wiedergegeben. Keine Lippensynchronität. */
    ST_SYNC_PREVIEW = 0,
    /* Zeitlich abgestimmt: Video und Audio werden über ihre RTP-Zeitstempel
     * (gemeinsamer Zeitbezug des Senders) aufeinander ausgerichtet; lokale
     * Uhr ist der Mac. Lippensynchron, solange der Sender beide Ströme aus
     * derselben Uhr stempelt. */
    ST_SYNC_RTP_ALIGNED = 1,
    /* Wie oben, aber die Wiedergabeuhr ist der PTP-Grandmaster des Netzes
     * (passiver PTP-Follower, nur Slave). */
    ST_SYNC_PTP = 2
} st_sync_mode;

typedef enum {
    ST_PIXFMT_UYVP = 1,   /* YCbCr 4:2:2 10 Bit, RFC 4175 pgroup: 5 Byte / 2 Pixel */
    ST_PIXFMT_UYVY = 2    /* YCbCr 4:2:2 8 Bit:  4 Byte / 2 Pixel */
} st_pixfmt;

typedef struct {
    const uint8_t *data;
    size_t size;
    int width;
    int height;
    int stride;
    st_pixfmt pixfmt;
    int colorimetry_bt601; /* 1 = BT.601, sonst BT.709 */
    int full_range;        /* 1 = Full Range (RANGE=FULL) */
    uint64_t pts_ns;
    uint64_t frame_number;
    int demo_flash;        /* nur Demo: Blitzbild für Lippensynchrontest */
} st_video_frame;

typedef enum {
    ST_EVENT_STATE = 1,           /* Zustandswechsel, siehe st_state */
    ST_EVENT_ERROR = 2,           /* Pipeline-Fehler (Text) */
    ST_EVENT_WARNING = 3,         /* Hinweis (Text) */
    ST_EVENT_FORMAT_MISMATCH = 4, /* Empfangene Daten passen nicht zur SDP */
    ST_EVENT_SENDER_RESTART = 5,  /* SSRC/Zeitbezug gesprungen */
    ST_EVENT_PTP = 6              /* PTP-Status geändert */
} st_event;

typedef enum {
    ST_STATE_STOPPED = 0,
    ST_STATE_STARTING = 1,
    ST_STATE_WAITING = 2,     /* läuft, aber noch keine Pakete */
    ST_STATE_RECEIVING = 3,
    ST_STATE_STALLED = 4,     /* Pakete bleiben aus */
    ST_STATE_ERROR = 5
} st_state;

typedef struct {
    void *user;
    /* Wird aus einem GStreamer-Thread zum Darstellungszeitpunkt aufgerufen.
     * Die Daten gelten nur während des Aufrufs (kopieren!). */
    void (*video_frame)(void *user, const st_video_frame *frame);
    /* Ereignisse, ebenfalls aus GStreamer-Threads. */
    void (*event)(void *user, st_event ev, int code, const char *message);
} st_callbacks;

typedef struct {
    int has_video;
    st_sdp_media video;
    int has_audio;
    st_sdp_media audio;

    char iface_name[ST_STR_SHORT];   /* BSD-Name, z. B. "en7"; leer = System */
    char iface_addr[ST_STR];         /* IPv4-Adresse dieser Schnittstelle */
    int use_source_filter;           /* SSM-Join, wenn SDP eine Quelle nennt */
    int socket_buffer_bytes;         /* 0 = automatisch */

    st_sync_mode sync_mode;
    int ptp_domain;                  /* -1 = aus SDP, sonst 127 */
    int ptp_timeout_ms;              /* Wartezeit auf PTP-Lock vor Rückfall */
    int latency_ms;                  /* Wiedergabepuffer */
    int auto_latency;                /* 1 = Puffer bei verspäteten Daten automatisch vergrößern */

    int audio_device_id;             /* macOS AudioDeviceID, 0 = Systemausgang */
    int audio_null_sink;             /* 1 = keine Tonausgabe (Tests) */
    int video_null_sink;             /* 1 = kein Callback (Tests) */

    /* Demo-Modus: Testbild + Testton, kein Netzwerk */
    int demo;
    int demo_fps;                    /* 25 oder 50 */
    int demo_channels;               /* z. B. 16 */
} st_receiver_config;

typedef struct {
    st_state state;
    st_sync_mode sync_requested;
    st_sync_mode sync_active;        /* tatsächlich wirksamer Modus */

    /* Video */
    uint64_t v_packets;
    uint64_t v_bytes;
    uint64_t v_lost;
    uint64_t v_reordered;
    uint64_t v_frames;               /* RTP-Marker gesehen */
    uint64_t v_frames_rendered;
    uint64_t v_frames_dropped;       /* zu spät verworfen */
    uint64_t v_wrong_pt;
    double v_age_ms;                 /* seit letztem Paket, -1 = nie */
    double v_rate_mbps;
    double v_fps_measured;           /* aus RTP-Zeitstempeln */
    int v_width_seen;
    int v_height_seen;
    int v_interlace_seen;
    uint32_t v_ssrc;
    double v_transit_ms;             /* Ankunft - Aufnahmezeit (min., Fenster) */

    /* Audio */
    uint64_t a_packets;
    uint64_t a_lost;
    uint64_t a_reordered;
    uint64_t a_wrong_pt;
    uint64_t a_buffers_rendered;
    uint64_t a_buffers_dropped;
    double a_age_ms;
    double a_ptime_measured_ms;
    int a_payload_bytes;
    uint32_t a_ssrc;
    double a_transit_ms;

    /* Synchronisation */
    double av_capture_delta_ms;      /* Abstand der zuletzt gerenderten Aufnahmezeiten */
    double latency_ms;               /* aktuell wirksamer Wiedergabepuffer */
    double v_late_max_ms;            /* größte Verspätung an der Videosenke (Fenster) */
    double a_late_max_ms;
    int latency_auto_raised;
    double offset_drift_ppm;         /* nur RTP-abgestimmt: gemessene Drift */
    uint64_t resyncs;                /* Neuausrichtungen (Senderneustart etc.) */
    /* Lippensynchron-Messung mit Testsignal (Blitz im Bild + Ton-Einsatz):
     * Abstand Ton - Bild an den Ausgabezeitstempeln. Positiv = Ton später. */
    uint64_t sync_measurements;
    double sync_offset_last_ms;
    double sync_offset_avg_ms;
    uint64_t flashes_seen;
    uint64_t onsets_seen;

    /* PTP */
    int ptp_enabled;
    int ptp_synced;
    int ptp_domain;
    char ptp_grandmaster[ST_STR_SHORT];
    char ptp_master[ST_STR_SHORT];
    double ptp_path_delay_us;
    double ptp_rsquared;
    int ptp_gm_matches_sdp;          /* -1 unbekannt, 0 nein, 1 ja */
    int ptp_domains_seen;

    int socket_buffer_bytes;         /* tatsächlich gesetzt */
} st_stats;

/* Einmalig vor allem anderen aufrufen. Liefert 0 bei Erfolg. */
int st_init(char *err, size_t err_len);
const char *st_gstreamer_version(void);
/* Prüft, ob alle benötigten GStreamer-Elemente vorhanden sind. */
int st_check_plugins(char *missing, size_t len);

typedef struct st_receiver st_receiver;

st_receiver *st_receiver_new(const st_receiver_config *cfg,
                             const st_callbacks *cb,
                             char *err, size_t err_len);
int st_receiver_start(st_receiver *r, char *err, size_t err_len);
void st_receiver_stop(st_receiver *r);
void st_receiver_free(st_receiver *r);

void st_receiver_get_stats(st_receiver *r, st_stats *out);
/* Pegel aller Audiokanäle in dBFS (Spitzenwert seit letztem Abruf, mit
 * Abfall). Liefert die Kanalzahl. */
int st_receiver_get_levels(st_receiver *r, float *peak_db, int max_channels);

void st_receiver_set_volume(st_receiver *r, double volume); /* 0..1.5 */
void st_receiver_set_mute(st_receiver *r, int mute);
/* Abhörauswahl: left/right 0-basiert. right = -1: Einzelkanal auf beide Seiten. */
void st_receiver_set_monitor_channels(st_receiver *r, int left, int right);
/* Manueller Audioversatz in Millisekunden (positiv = Ton später). */
void st_receiver_set_audio_delay_ms(st_receiver *r, int delay_ms);

/* Hilfsfunktionen für Diagnose */
const char *st_state_name(st_state s);
const char *st_sync_mode_name(st_sync_mode m);

#ifdef __cplusplus
}
#endif
#endif
