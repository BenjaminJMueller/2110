/*
 * Multicast-Empfangssocket.
 *
 * Warum eigener Code statt udpsrc-Multicast? GLib tritt unter macOS
 * IPv4-Gruppen ohne ip_mreqn bei und kann die Schnittstelle dabei nicht
 * zuverlässig festlegen. Bei mehreren Netzwerkanschlüssen (WLAN + 10-GbE-
 * Adapter) landet der Beitritt sonst womöglich auf der falschen Schnittstelle.
 * Hier wird der Beitritt explizit über die IPv4-Adresse der gewählten
 * Schnittstelle durchgeführt (macOS und Linux), unter macOS zusätzlich mit
 * IP_BOUND_IF auf die Schnittstelle beschränkt.
 */
#include "st_internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int st_is_multicast(const char *addr)
{
    struct in_addr a;
    if (inet_pton(AF_INET, addr, &a) != 1) return 0;
    return IN_MULTICAST(ntohl(a.s_addr));
}

int st_socket_open(const char *group, int port, const char *source,
                   const char *iface_name, const char *iface_addr,
                   int want_rcvbuf, int *got_rcvbuf,
                   char *err, size_t err_len)
{
    struct in_addr grp, src, ifa;
    if (inet_pton(AF_INET, group, &grp) != 1) {
        snprintf(err, err_len, "Ungültige Zieladresse „%s“ (nur IPv4 wird unterstützt).", group);
        return -1;
    }
    int mcast = IN_MULTICAST(ntohl(grp.s_addr));
    int have_src = source && *source && inet_pton(AF_INET, source, &src) == 1;
    int have_ifa = iface_addr && *iface_addr && inet_pton(AF_INET, iface_addr, &ifa) == 1;

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        snprintf(err, err_len, "UDP-Socket konnte nicht erzeugt werden: %s", strerror(errno));
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#endif

    /* Empfangspuffer: so groß wie möglich (1080p50 ≈ 2,1 Gbit/s). */
    int want = want_rcvbuf > 0 ? want_rcvbuf : 64 * 1024 * 1024;
    int got = 0;
    for (int sz = want; sz >= 256 * 1024; sz /= 2) {
        if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz) == 0) {
            socklen_t l = sizeof got;
            getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &got, &l);
            break;
        }
    }
    if (got_rcvbuf) *got_rcvbuf = got;

#if defined(__APPLE__) && defined(IP_BOUND_IF)
    if (iface_name && *iface_name) {
        unsigned idx = if_nametoindex(iface_name);
        if (idx > 0) setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx);
    }
#else
    (void)iface_name;
#endif

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    /* An die Gruppenadresse binden filtert andere Gruppen auf demselben Port. */
    sa.sin_addr = mcast ? grp : (struct in_addr){ .s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        int e = errno;
        /* Fallback: an INADDR_ANY binden */
        sa.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
            snprintf(err, err_len, "Port %d konnte nicht geöffnet werden: %s", port, strerror(e));
            close(fd);
            return -1;
        }
    }

    if (mcast) {
        int ok = -1;
        int e = 0;
#ifdef IP_ADD_SOURCE_MEMBERSHIP
        if (have_src) {
            struct ip_mreq_source mreqs;
            memset(&mreqs, 0, sizeof mreqs);
            mreqs.imr_multiaddr = grp;
            mreqs.imr_sourceaddr = src;
            mreqs.imr_interface = have_ifa ? ifa : (struct in_addr){ .s_addr = htonl(INADDR_ANY) };
            ok = setsockopt(fd, IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, &mreqs, sizeof mreqs);
            if (ok != 0) e = errno;
        }
#endif
        if (ok != 0) {
            struct ip_mreq mreq;
            memset(&mreq, 0, sizeof mreq);
            mreq.imr_multiaddr = grp;
            mreq.imr_interface = have_ifa ? ifa : (struct in_addr){ .s_addr = htonl(INADDR_ANY) };
            ok = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof mreq);
            if (ok != 0) e = errno;
        }
        if (ok != 0) {
            snprintf(err, err_len,
                     "Beitritt zur Multicast-Gruppe %s auf Schnittstelle %s fehlgeschlagen: %s. "
                     "Möglicherweise hat die Schnittstelle keine IPv4-Adresse oder keine Verbindung.",
                     group, (iface_name && *iface_name) ? iface_name : "(Standard)", strerror(e));
            close(fd);
            return -1;
        }
    }
    return fd;
}

void st_socket_close(int fd)
{
    if (fd >= 0) close(fd);
}
