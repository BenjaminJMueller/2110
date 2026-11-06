#ifndef ST_INTERNAL_H
#define ST_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* Abstand TAI - UTC in Sekunden (gilt seit 2017-01-01; ST 2059 nutzt TAI). */
#define ST_TAI_UTC_OFFSET_S 37

/* Erzeugt einen UDP-Socket, bindet ihn an group:port und tritt der
 * Multicast-Gruppe auf der angegebenen Schnittstelle bei (ASM oder SSM).
 * Ist group eine Unicast-Adresse, wird nur gebunden.
 * Rückgabe: Dateideskriptor oder -1 (Text in err). */
int st_socket_open(const char *group, int port, const char *source,
                   const char *iface_name, const char *iface_addr,
                   int want_rcvbuf, int *got_rcvbuf,
                   char *err, size_t err_len);
void st_socket_close(int fd);
int st_is_multicast(const char *addr);

/* Gemeinsamer Versatz-Schätzer für die RTP-abgestimmte Wiedergabe.
 * delta = Ankunft(lokale Laufzeit) - Aufnahmezeit(Medienuhr). Der Schätzer
 * folgt dem Minimum über Zeitfenster und gleicht Drift langsam aus. */
typedef struct {
    int have;
    int64_t offset;          /* aktueller Versatz (ns) */
    int64_t win_min;         /* Minimum im laufenden Fenster */
    int have_win;
    uint64_t win_start;      /* lokale Zeit Fensterbeginn (ns) */
    uint64_t window_ns;
    int64_t snap_threshold;  /* Sprung -> sofort übernehmen */
    int64_t max_slew;        /* max. Korrektur je Fenster */
    uint64_t resyncs;
    double drift_ppm;        /* geglättete Drift */
    int64_t last_target;
    uint64_t last_target_time;
    uint64_t late_since;     /* seit wann Pakete deutlich zu spät kommen (0 = nicht) */
    int64_t late_min;
    int64_t drift_base;      /* Bezugswert für die Driftschätzung */
    uint64_t drift_base_time;
} st_offset_tracker;

void st_offset_init(st_offset_tracker *t);
/* Liefert 1, wenn dabei neu ausgerichtet wurde (Sprung). */
int st_offset_update(st_offset_tracker *t, int64_t delta, uint64_t now_local);

#endif
