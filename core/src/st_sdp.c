/*
 * SDP-Parser für ST 2110 (RFC 4566, RFC 4175, RFC 3190, RFC 7273,
 * SMPTE ST 2110-10/-20/-30). Bewusst tolerant: unbekannte Zeilen werden
 * ignoriert, damit herstellerspezifische Erweiterungen nicht stören.
 */
#include "st2110core.h"
#include "st_internal.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static void copy_str(char *dst, size_t len, const char *src, size_t n)
{
    if (len == 0) return;
    if (n >= len) n = len - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static const char *skip_ws(const char *s)
{
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static void trim(char *s)
{
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' ||
                     s[n - 1] == ';'))
        s[--n] = '\0';
    char *p = s;
    while (*p == ' ' || *p == '\t') p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
}

/* Liest "a/b" oder "a" als Bruch. */
static void parse_rate(const char *v, int *num, int *den)
{
    *num = 0;
    *den = 1;
    char *end = NULL;
    long a = strtol(v, &end, 10);
    if (end && *end == '/') {
        long b = strtol(end + 1, NULL, 10);
        if (b > 0) {
            *num = (int)a;
            *den = (int)b;
            return;
        }
    }
    if (end && *end == '.') {
        /* z. B. 29.97 -> 30000/1001 */
        double d = strtod(v, NULL);
        if (d > 29.96 && d < 29.98) { *num = 30000; *den = 1001; return; }
        if (d > 59.93 && d < 59.95) { *num = 60000; *den = 1001; return; }
        if (d > 23.97 && d < 23.99) { *num = 24000; *den = 1001; return; }
        *num = (int)(d * 1000.0 + 0.5);
        *den = 1000;
        return;
    }
    *num = (int)a;
    *den = 1;
}

/* c=IN IP4 239.1.1.1/64[/n] */
static void parse_connection(const char *v, char *addr, size_t addr_len, int *ttl)
{
    char nettype[16] = {0}, addrtype[16] = {0}, a[128] = {0};
    if (sscanf(v, "%15s %15s %127s", nettype, addrtype, a) == 3) {
        char *slash = strchr(a, '/');
        if (slash) {
            *slash = '\0';
            if (ttl) *ttl = atoi(slash + 1);
        }
        copy_str(addr, addr_len, a, strlen(a));
    }
}

/* a=source-filter: incl IN IP4 <dest> <src> */
static void parse_source_filter(const char *v, char *src, size_t src_len)
{
    char mode[16] = {0}, nt[16] = {0}, at[16] = {0}, dest[128] = {0}, s[128] = {0};
    if (sscanf(v, " %15s %15s %15s %127s %127s", mode, nt, at, dest, s) == 5) {
        if (strcasecmp(mode, "incl") == 0) copy_str(src, src_len, s, strlen(s));
    }
}

/* a=ts-refclk:ptp=IEEE1588-2008:08-00-11-FF-FE-21-E1-B0:127 */
static void parse_refclk(const char *v, st_sdp_media *m)
{
    copy_str(m->refclk_raw, sizeof m->refclk_raw, v, strlen(v));
    if (strncasecmp(v, "ptp=", 4) == 0) {
        m->has_ptp_refclk = 1;
        m->refclk_localmac = 0;
        const char *p = v + 4;
        const char *c1 = strchr(p, ':');
        if (!c1) return;
        const char *gm = c1 + 1;
        const char *c2 = strchr(gm, ':');
        if (c2) {
            copy_str(m->ptp_gmid, sizeof m->ptp_gmid, gm, (size_t)(c2 - gm));
            m->ptp_domain = atoi(c2 + 1);
        } else {
            copy_str(m->ptp_gmid, sizeof m->ptp_gmid, gm, strlen(gm));
        }
        if (strcasecmp(m->ptp_gmid, "traceable") == 0) m->ptp_gmid[0] = '\0';
    } else if (strncasecmp(v, "localmac=", 9) == 0) {
        m->refclk_localmac = 1;
        m->has_ptp_refclk = 0;
    }
}

static void parse_mediaclk(const char *v, st_sdp_media *m)
{
    m->has_mediaclk = 1;
    if (strncasecmp(v, "direct=", 7) == 0) {
        m->mediaclk_direct = 1;
        m->mediaclk_offset = atoll(v + 7);
    }
}

static void parse_fmtp_params(const char *params, st_sdp_media *m)
{
    char buf[2048];
    copy_str(buf, sizeof buf, params, strlen(params));
    char *save = NULL;
    for (char *tok = strtok_r(buf, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
        trim(tok);
        if (!*tok) continue;
        char *eq = strchr(tok, '=');
        char key[64] = {0};
        const char *val = "";
        if (eq) {
            copy_str(key, sizeof key, tok, (size_t)(eq - tok));
            val = eq + 1;
        } else {
            copy_str(key, sizeof key, tok, strlen(tok));
        }
        trim(key);
        if (strcasecmp(key, "sampling") == 0) copy_str(m->sampling, sizeof m->sampling, val, strlen(val));
        else if (strcasecmp(key, "width") == 0) m->width = atoi(val);
        else if (strcasecmp(key, "height") == 0) m->height = atoi(val);
        else if (strcasecmp(key, "depth") == 0) m->depth = atoi(val);
        else if (strcasecmp(key, "exactframerate") == 0 || strcasecmp(key, "framerate") == 0)
            parse_rate(val, &m->fps_num, &m->fps_den);
        else if (strcasecmp(key, "colorimetry") == 0) copy_str(m->colorimetry, sizeof m->colorimetry, val, strlen(val));
        else if (strcasecmp(key, "TCS") == 0) copy_str(m->tcs, sizeof m->tcs, val, strlen(val));
        else if (strcasecmp(key, "RANGE") == 0) copy_str(m->range, sizeof m->range, val, strlen(val));
        else if (strcasecmp(key, "PM") == 0) copy_str(m->pm, sizeof m->pm, val, strlen(val));
        else if (strcasecmp(key, "SSN") == 0) copy_str(m->ssn, sizeof m->ssn, val, strlen(val));
        else if (strcasecmp(key, "TP") == 0) copy_str(m->tp, sizeof m->tp, val, strlen(val));
        else if (strcasecmp(key, "interlace") == 0) m->interlaced = (eq == NULL) ? 1 : (atoi(val) != 0 || *val == '\0');
        else if (strcasecmp(key, "segmented") == 0) m->segmented = (eq == NULL) ? 1 : (atoi(val) != 0 || *val == '\0');
        else if (strcasecmp(key, "channel-order") == 0) copy_str(m->channel_order, sizeof m->channel_order, val, strlen(val));
    }
}

typedef struct {
    char conn_addr[ST_STR];
    int ttl;
    char source_addr[ST_STR];
    char origin_addr[ST_STR];
    char session_name[ST_STR_LONG];
    char refclk[ST_STR_LONG];
    char mediaclk[ST_STR];
    int dup;
} session_defaults;

static void media_init(st_sdp_media *m, const session_defaults *s)
{
    memset(m, 0, sizeof *m);
    m->payload_type = -1;
    m->ptp_domain = -1;
    m->fps_den = 1;
    m->ttl = s->ttl;
    copy_str(m->dest_addr, sizeof m->dest_addr, s->conn_addr, strlen(s->conn_addr));
    copy_str(m->source_addr, sizeof m->source_addr, s->source_addr, strlen(s->source_addr));
    copy_str(m->origin_addr, sizeof m->origin_addr, s->origin_addr, strlen(s->origin_addr));
    copy_str(m->session_name, sizeof m->session_name, s->session_name, strlen(s->session_name));
    if (s->refclk[0]) parse_refclk(s->refclk, m);
    if (s->mediaclk[0]) parse_mediaclk(s->mediaclk, m);
    m->dup_group = s->dup;
}

int st_sdp_parse(const char *text, st_sdp_media *out, int max_media,
                 char *err, size_t err_len)
{
    if (err && err_len) err[0] = '\0';
    if (!text || !*text) {
        if (err) snprintf(err, err_len, "Die SDP-Beschreibung ist leer.");
        return -1;
    }
    session_defaults sd;
    memset(&sd, 0, sizeof sd);

    int count = -1; /* Index des aktuellen m=-Abschnitts */
    int saw_v = 0;
    int pending_fmtp_pt = -1;
    (void)pending_fmtp_pt;

    const char *p = text;
    /* UTF-8 BOM überspringen */
    if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) p += 3;

    while (*p) {
        const char *eol = p;
        while (*eol && *eol != '\n') eol++;
        char line[2048];
        copy_str(line, sizeof line, p, (size_t)(eol - p));
        p = (*eol) ? eol + 1 : eol;
        size_t ln = strlen(line);
        while (ln && (line[ln - 1] == '\r' || line[ln - 1] == ' ')) line[--ln] = '\0';
        const char *l = skip_ws(line);
        if (strlen(l) < 2 || l[1] != '=') continue;
        char type = l[0];
        const char *v = l + 2;
        st_sdp_media *cur = (count >= 0 && count < max_media) ? &out[count] : NULL;

        switch (type) {
        case 'v':
            saw_v = 1;
            break;
        case 'o': {
            /* o=<user> <sess-id> <sess-version> IN IP4 <addr> */
            char u[128], id[64], ver[64], nt[16], at[16], a[128];
            if (sscanf(v, "%127s %63s %63s %15s %15s %127s", u, id, ver, nt, at, a) == 6)
                copy_str(sd.origin_addr, sizeof sd.origin_addr, a, strlen(a));
            break;
        }
        case 's':
            if (count < 0) copy_str(sd.session_name, sizeof sd.session_name, v, strlen(v));
            break;
        case 'i':
            if (cur) copy_str(cur->media_title, sizeof cur->media_title, v, strlen(v));
            break;
        case 'c':
            if (count < 0) parse_connection(v, sd.conn_addr, sizeof sd.conn_addr, &sd.ttl);
            else if (cur) parse_connection(v, cur->dest_addr, sizeof cur->dest_addr, &cur->ttl);
            break;
        case 'm': {
            count++;
            if (count >= max_media) break;
            cur = &out[count];
            media_init(cur, &sd);
            char media[32] = {0}, port[32] = {0}, proto[64] = {0};
            int pt = -1;
            sscanf(v, "%31s %31s %63s %d", media, port, proto, &pt);
            cur->port = atoi(port);
            cur->payload_type = pt;
            if (strcasecmp(media, "video") == 0) cur->kind = ST_MEDIA_VIDEO;
            else if (strcasecmp(media, "audio") == 0) cur->kind = ST_MEDIA_AUDIO;
            else cur->kind = ST_MEDIA_DATA;
            break;
        }
        case 'a': {
            const char *colon = strchr(v, ':');
            char attr[64] = {0};
            const char *val = "";
            if (colon) {
                copy_str(attr, sizeof attr, v, (size_t)(colon - v));
                val = colon + 1;
            } else {
                copy_str(attr, sizeof attr, v, strlen(v));
            }
            if (count < 0) {
                if (strcasecmp(attr, "source-filter") == 0)
                    parse_source_filter(val, sd.source_addr, sizeof sd.source_addr);
                else if (strcasecmp(attr, "ts-refclk") == 0)
                    copy_str(sd.refclk, sizeof sd.refclk, val, strlen(val));
                else if (strcasecmp(attr, "mediaclk") == 0)
                    copy_str(sd.mediaclk, sizeof sd.mediaclk, val, strlen(val));
                else if (strcasecmp(attr, "group") == 0 && strncasecmp(val, "DUP", 3) == 0)
                    sd.dup = 1;
                break;
            }
            if (!cur) break;
            if (strcasecmp(attr, "rtpmap") == 0) {
                /* <pt> <enc>/<rate>[/<ch>] */
                int pt = atoi(val);
                if (cur->payload_type < 0 || pt == cur->payload_type) {
                    const char *sp = strchr(val, ' ');
                    if (sp) {
                        sp = skip_ws(sp);
                        char enc[64] = {0};
                        copy_str(enc, sizeof enc, sp, strlen(sp));
                        char *s1 = strchr(enc, '/');
                        if (s1) {
                            *s1 = '\0';
                            cur->clock_rate = atoi(s1 + 1);
                            char *s2 = strchr(s1 + 1, '/');
                            if (s2) cur->channels = atoi(s2 + 1);
                        }
                        copy_str(cur->encoding, sizeof cur->encoding, enc, strlen(enc));
                        if (strcasecmp(cur->encoding, "smpte291") == 0) cur->kind = ST_MEDIA_DATA;
                    }
                }
            } else if (strcasecmp(attr, "fmtp") == 0) {
                int pt = atoi(val);
                if (cur->payload_type < 0 || pt == cur->payload_type) {
                    const char *sp = strchr(val, ' ');
                    if (sp) parse_fmtp_params(sp + 1, cur);
                }
            } else if (strcasecmp(attr, "ptime") == 0) {
                cur->ptime_ms = strtod(val, NULL);
            } else if (strcasecmp(attr, "source-filter") == 0) {
                parse_source_filter(val, cur->source_addr, sizeof cur->source_addr);
            } else if (strcasecmp(attr, "ts-refclk") == 0) {
                cur->has_ptp_refclk = 0;
                cur->ptp_gmid[0] = '\0';
                cur->ptp_domain = -1;
                parse_refclk(val, cur);
            } else if (strcasecmp(attr, "mediaclk") == 0) {
                parse_mediaclk(val, cur);
            } else if (strcasecmp(attr, "mid") == 0) {
                copy_str(cur->mid, sizeof cur->mid, val, strlen(val));
            }
            break;
        }
        default:
            break;
        }
    }

    if (!saw_v && count < 0) {
        if (err) snprintf(err, err_len, "Der Text ist keine gültige SDP-Beschreibung (keine Zeilen „v=“ oder „m=“ gefunden).");
        return -1;
    }
    if (count < 0) {
        if (err) snprintf(err, err_len, "Die SDP-Beschreibung enthält keinen Medienabschnitt („m=“).");
        return -1;
    }
    int n = count + 1;
    if (n > max_media) n = max_media;
    return n;
}

/* ------------------------------------------------------------------ */

static int is_fps(const st_sdp_media *m, int num, int den)
{
    return m->fps_den > 0 && (long long)m->fps_num * den == (long long)num * m->fps_den;
}

st_support st_check_media(const st_sdp_media *m, char *msg, size_t len)
{
    if (msg && len) msg[0] = '\0';
    st_support res = ST_SUPPORT_OK;
#define SAY(level, ...) do { if ((level) >= res) { res = (level); if (msg) snprintf(msg, len, __VA_ARGS__); } } while (0)

    if (m->dest_addr[0] == '\0' || m->port <= 0) {
        SAY(ST_SUPPORT_NO, "Die SDP enthält keine Zieladresse oder keinen Port (Zeilen „c=“ bzw. „m=“).");
        return res;
    }

    if (m->kind == ST_MEDIA_VIDEO) {
        if (strcasecmp(m->encoding, "raw") != 0) {
            if (strcasecmp(m->encoding, "jxsv") == 0)
                SAY(ST_SUPPORT_NO, "JPEG XS (ST 2110-22) wird nicht unterstützt. Der Blackmagic 2110 IP Converter 3x3G sendet unkomprimiertes ST 2110-20 – bitte den unkomprimierten Videostrom wählen.");
            else
                SAY(ST_SUPPORT_NO, "Videokodierung „%s“ wird nicht unterstützt. Unterstützt wird unkomprimiertes ST 2110-20 („raw“). Blackmagic IP10 wird ausdrücklich nicht unterstützt; der 2110 IP Converter 3x3G verwendet IP10 laut Hersteller nicht.", m->encoding[0] ? m->encoding : "(leer)");
            return res;
        }
        if (m->clock_rate != 90000) {
            SAY(ST_SUPPORT_NO, "Ungewöhnliche Video-Taktrate %d Hz (ST 2110-20 verlangt 90000 Hz).", m->clock_rate);
            return res;
        }
        if (m->width <= 0 || m->height <= 0) {
            SAY(ST_SUPPORT_NO, "Bildgröße fehlt in der SDP (width/height in „a=fmtp“).");
            return res;
        }
        if (m->width % 2 != 0) {
            SAY(ST_SUPPORT_NO, "Ungerade Bildbreite %d wird nicht unterstützt.", m->width);
            return res;
        }
        if (strcasecmp(m->sampling, "YCbCr-4:2:2") != 0) {
            SAY(ST_SUPPORT_NO, "Farbabtastung „%s“ wird nicht unterstützt. Unterstützt wird YCbCr 4:2:2 (8 oder 10 Bit). Abhilfe: Am SDI-Quellgerät (Kamera, Mischer) YUV/YCbCr 4:2:2 statt RGB 4:4:4 ausgeben; der 3x3G überträgt das Format des SDI-Eingangs.", m->sampling[0] ? m->sampling : "(leer)");
            return res;
        }
        if (m->depth != 10 && m->depth != 8) {
            SAY(ST_SUPPORT_NO, "Bittiefe %d wird nicht unterstützt (nur 8 und 10 Bit bei YCbCr 4:2:2).", m->depth);
            return res;
        }
        if (m->interlaced || m->segmented) {
            SAY(ST_SUPPORT_NO, "%s wird in dieser Version nicht unterstützt (der verwendete GStreamer-Depayloader kann keine Halbbilder). Abhilfe: Am SDI-Quellgerät ein progressives Format einstellen, z. B. 1080p25 oder 1080p50 – der 2110 IP Converter 3x3G übernimmt das Videoformat des SDI-Eingangs.",
                m->segmented ? "Segmentierte Vollbilder (PsF)" : "Zeilensprung (interlaced, z. B. 1080i50)");
            return res;
        }
        if (m->fps_num <= 0) {
            SAY(ST_SUPPORT_WARNING, "Die SDP nennt keine Bildrate (exactframerate). Die Bildrate wird aus den Zeitstempeln ermittelt.");
        }
        if (m->dup_group)
            SAY(ST_SUPPORT_WARNING, "Die SDP beschreibt redundante Ströme (ST 2022-7). Diese Version empfängt nur den ersten Pfad.");
        if (m->colorimetry[0] && strncasecmp(m->colorimetry, "BT709", 5) != 0 && strncasecmp(m->colorimetry, "BT601", 5) != 0)
            SAY(ST_SUPPORT_WARNING, "Farbraum „%s“ wird wie BT.709 dargestellt. Für die Bildbeurteilung ist die Darstellung dann nicht farbverbindlich.", m->colorimetry);
        if (m->tcs[0] && strcasecmp(m->tcs, "SDR") != 0)
            SAY(ST_SUPPORT_WARNING, "Übertragungskennlinie „%s“ (HDR) wird wie SDR dargestellt.", m->tcs);
        int target = m->width == 1920 && m->height == 1080 && (is_fps(m, 25, 1) || is_fps(m, 50, 1));
        if (!target && res == ST_SUPPORT_OK) {
            SAY(ST_SUPPORT_WARNING, "Format %d×%d mit %.2f B/s gehört nicht zu den geprüften Zielformaten (1080p25/1080p50). Der Empfang sollte funktionieren, ist aber nicht abgenommen.",
                m->width, m->height, m->fps_den ? (double)m->fps_num / m->fps_den : 0.0);
        }
        return res;
    }

    if (m->kind == ST_MEDIA_AUDIO) {
        if (strcasecmp(m->encoding, "L24") != 0 && strcasecmp(m->encoding, "L16") != 0) {
            if (strcasecmp(m->encoding, "AM824") == 0)
                SAY(ST_SUPPORT_NO, "AES3-Transparenz (ST 2110-31, AM824) wird nicht unterstützt. Bitte einen PCM-Audiostrom nach ST 2110-30 (L24) wählen.");
            else
                SAY(ST_SUPPORT_NO, "Audiokodierung „%s“ wird nicht unterstützt (nur PCM L24/L16 nach ST 2110-30).", m->encoding[0] ? m->encoding : "(leer)");
            return res;
        }
        if (m->clock_rate <= 0) {
            SAY(ST_SUPPORT_NO, "Abtastrate fehlt in der SDP („a=rtpmap“).");
            return res;
        }
        if (m->channels <= 0) {
            /* RFC 3190: ohne Angabe 1 Kanal */
        } else if (m->channels > ST_MAX_AUDIO_CHANNELS) {
            SAY(ST_SUPPORT_NO, "%d Audiokanäle werden nicht unterstützt (maximal %d).", m->channels, ST_MAX_AUDIO_CHANNELS);
            return res;
        }
        if (m->clock_rate != 48000)
            SAY(ST_SUPPORT_WARNING, "Abtastrate %d Hz ist ungewöhnlich für ST 2110-30 (48000 Hz). Der Ton wird umgerechnet.", m->clock_rate);
        if (m->ptime_ms > 0 && !(m->ptime_ms > 0.124 && m->ptime_ms < 0.126) && !(m->ptime_ms > 0.99 && m->ptime_ms < 1.01))
            SAY(ST_SUPPORT_WARNING, "Paketzeit %.3f ms ist ungewöhnlich (ST 2110-30: 1 ms oder 0,125 ms).", m->ptime_ms);
        if (m->dup_group)
            SAY(ST_SUPPORT_WARNING, "Die SDP beschreibt redundante Ströme (ST 2022-7). Diese Version empfängt nur den ersten Pfad.");
        return res;
    }

    if (m->kind == ST_MEDIA_DATA) {
        SAY(ST_SUPPORT_NO, "Dieser Strom enthält Zusatzdaten (z. B. ST 2110-40 Ancillary) und wird nicht wiedergegeben.");
        return res;
    }
    SAY(ST_SUPPORT_NO, "Unbekannter Medientyp.");
    return res;
#undef SAY
}

int st_sdp_write(const st_sdp_media *m, char *out, size_t len)
{
    char fps[32];
    if (m->fps_den > 1) snprintf(fps, sizeof fps, "%d/%d", m->fps_num, m->fps_den);
    else snprintf(fps, sizeof fps, "%d", m->fps_num);
    const char *src = m->source_addr[0] ? m->source_addr : (m->origin_addr[0] ? m->origin_addr : "0.0.0.0");
    char refclk[ST_STR_LONG];
    if (m->has_ptp_refclk && m->ptp_gmid[0])
        snprintf(refclk, sizeof refclk, "a=ts-refclk:ptp=IEEE1588-2008:%s:%d\r\n", m->ptp_gmid, m->ptp_domain >= 0 ? m->ptp_domain : 127);
    else if (m->has_ptp_refclk)
        snprintf(refclk, sizeof refclk, "a=ts-refclk:ptp=IEEE1588-2008:traceable\r\n");
    else
        refclk[0] = '\0';
    char srcfilter[ST_STR_LONG] = "";
    if (m->source_addr[0])
        snprintf(srcfilter, sizeof srcfilter, "a=source-filter: incl IN IP4 %s %s\r\n", m->dest_addr, m->source_addr);
    int pt = (m->payload_type >= 96 && m->payload_type <= 127) ? m->payload_type : (m->kind == ST_MEDIA_VIDEO ? 96 : 97);
    int n;
    if (m->kind == ST_MEDIA_VIDEO) {
        n = snprintf(out, len,
            "v=0\r\no=- 0 0 IN IP4 %s\r\ns=%s\r\nt=0 0\r\n"
            "m=video %d RTP/AVP %d\r\nc=IN IP4 %s/%d\r\n%s"
            "a=rtpmap:%d raw/90000\r\n"
            "a=fmtp:%d sampling=%s; width=%d; height=%d; exactframerate=%s; depth=%d; TCS=%s; colorimetry=%s; PM=2110GPM; SSN=ST2110-20:2017; TP=2110TPN; %s\r\n"
            "%sa=mediaclk:direct=0\r\n",
            src, m->session_name[0] ? m->session_name : "Manuell", m->port, pt, m->dest_addr, m->ttl > 0 ? m->ttl : 64, srcfilter,
            pt, pt, m->sampling[0] ? m->sampling : "YCbCr-4:2:2", m->width, m->height, fps, m->depth ? m->depth : 10,
            m->tcs[0] ? m->tcs : "SDR", m->colorimetry[0] ? m->colorimetry : "BT709", m->interlaced ? "interlace; " : "",
            refclk);
    } else {
        char ptime[32];
        snprintf(ptime, sizeof ptime, "%g", m->ptime_ms > 0 ? m->ptime_ms : 1.0);
        n = snprintf(out, len,
            "v=0\r\no=- 0 0 IN IP4 %s\r\ns=%s\r\nt=0 0\r\n"
            "m=audio %d RTP/AVP %d\r\nc=IN IP4 %s/%d\r\n%s"
            "a=rtpmap:%d %s/%d/%d\r\na=ptime:%s\r\n"
            "%sa=mediaclk:direct=0\r\n",
            src, m->session_name[0] ? m->session_name : "Manuell", m->port, pt, m->dest_addr, m->ttl > 0 ? m->ttl : 64, srcfilter,
            pt, m->encoding[0] ? m->encoding : "L24", m->clock_rate ? m->clock_rate : 48000, m->channels ? m->channels : 2,
            ptime, refclk);
    }
    return (n < 0 || (size_t)n >= len) ? -1 : n;
}
