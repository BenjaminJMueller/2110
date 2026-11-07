/*
 * st2110analyze – Analyse von Paketmitschnitten (pcap, pcapng) mit
 * ST-2110-Verkehr. Angelehnt an den Funktionsumfang von EBU LIST, aber
 * eigenständig implementiert (kein übernommener Code).
 *
 * Ergebnisse als JSON (für App und Kommandozeile) sowie Vorschaubilder.
 */
#ifndef ST2110ANALYZE_H
#define ST2110ANALYZE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct st_analysis st_analysis;

/* Fortschritt 0..1; Rückgabe != 0 bricht ab. */
typedef int (*st_progress_fn)(void *user, double fraction);

/* sdp_texts: optionale SDPs (z. B. vom Gerät), um Ströme eindeutig
 * zuzuordnen; NULL-terminiertes Feld oder NULL. */
st_analysis *st_analyze_file(const char *path, const char *const *sdp_texts,
                             st_progress_fn progress, void *user,
                             char *err, size_t err_len);
/* Vollständiger Bericht als JSON (gehört der Analyse). */
const char *st_analysis_json(st_analysis *a);
/* Vorschaubild eines Videostroms (Index wie im JSON) als BGRA, Größe tw×th.
 * Rückgabe 0 bei Erfolg. */
int st_analysis_thumbnail(st_analysis *a, int stream_index, uint8_t *bgra, int tw, int th);
void st_analysis_free(st_analysis *a);

#ifdef __cplusplus
}
#endif
#endif
