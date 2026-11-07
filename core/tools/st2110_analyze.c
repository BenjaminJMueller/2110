/*
 * st2110-analyze – Analyse eines Paketmitschnitts (pcap/pcapng) mit
 * ST-2110-Verkehr. Ausgabe: lesbare Zusammenfassung oder JSON.
 *
 *   st2110-analyze mitschnitt.pcapng [--sdp video.sdp ...] [--json] [--thumb INDEX bild.ppm]
 */
#include "st2110analyze.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *slurp(const char *p)
{
    FILE *f = fopen(p, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1);
    size_t r = fread(b, 1, (size_t)n, f);
    b[r] = 0;
    fclose(f);
    return b;
}

static int prog(void *u, double f)
{
    (void)u;
    fprintf(stderr, "\r%3.0f %%", f * 100);
    return 0;
}

int main(int argc, char **argv)
{
    const char *file = NULL, *thumb_out = NULL;
    int json = 0, thumb_idx = -1;
    const char *sdps[33] = { 0 };
    int ns = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--sdp") == 0 && i + 1 < argc && ns < 32) sdps[ns++] = slurp(argv[++i]);
        else if (strcmp(argv[i], "--json") == 0) json = 1;
        else if (strcmp(argv[i], "--thumb") == 0 && i + 2 < argc) { thumb_idx = atoi(argv[++i]); thumb_out = argv[++i]; }
        else if (argv[i][0] != '-') file = argv[i];
        else { fprintf(stderr, "st2110-analyze DATEI [--sdp SDP ...] [--json] [--thumb INDEX ausgabe.ppm]\n"); return 2; }
    }
    if (!file) { fprintf(stderr, "Keine Datei angegeben.\n"); return 2; }
    char err[512];
    st_analysis *a = st_analyze_file(file, sdps, json ? NULL : prog, NULL, err, sizeof err);
    if (!json) fprintf(stderr, "\n");
    if (!a) { fprintf(stderr, "%s\n", err); return 1; }
    puts(st_analysis_json(a));
    if (thumb_out) {
        int w = 480, h = 270;
        unsigned char *b = malloc((size_t)w * h * 4);
        if (st_analysis_thumbnail(a, thumb_idx, b, w, h) == 0) {
            FILE *f = fopen(thumb_out, "wb");
            fprintf(f, "P6\n%d %d\n255\n", w, h);
            for (int i = 0; i < w * h; i++) { fputc(b[i * 4 + 2], f); fputc(b[i * 4 + 1], f); fputc(b[i * 4], f); }
            fclose(f);
            fprintf(stderr, "Vorschaubild: %s\n", thumb_out);
        } else {
            fprintf(stderr, "Kein Vorschaubild für Strom %d.\n", thumb_idx);
        }
        free(b);
    }
    st_analysis_free(a);
    return 0;
}
