# Device inventory and feasibility study

[Deutsch](../01-Machbarkeit.md)

As of 6 November 2026

## Recorded inventory

| Item | Status |
|---|---|
| Device | **Blackmagic 2110 IP Converter 3x3G** |
| Firmware | **still open**: please read it in “Blackmagic Converters Setup” and enter it in the test record |
| Video formats in use | **still open**; target formats 1080p25 and 1080p50, YCbCr 4:2:2 10-bit |
| Network | addresses and ranges must be configurable in the app (implemented) |
| PTP grandmaster, switch, NMOS registry | **still open**; see the test plan, section 0 |
| Apple Developer account | **none**; consequences see [build and distribution](build-and-distribution.md) |

## Sources

Reviewed:

* **[H]** Blackmagic Design, *Installation and Operation Manual – Blackmagic 2110 IP Converters*, September 2026 edition, retrieved from documents.blackmagicdesign.com/UserManuals/Blackmagic2110IPConvertersManual.pdf.
* **[T]** Blackmagic Design, tech specs “Blackmagic 2110 IP Converter 3x3G”, blackmagicdesign.com/products/blackmagic2110ipconverter/techspecs, retrieved 6 Nov 2026.
* **[G]** Official GStreamer packages for macOS 1.28.8 (gstreamer.freedesktop.org/data/pkg/osx/1.28.8/). The packages were unpacked and the binaries examined (architectures, dependencies, plugin capabilities).
* AMWA NMOS IS-04 v1.3, IS-05 v1.1, BCP-002-01; SMPTE ST 2110-10/-20/-21/-30, ST 2059-1/-2; RFC 4175, RFC 7273.

## What the 3x3G sends according to the manufacturer

| Question | Result | Source |
|---|---|---|
| Video formats | 720p50/59.94/60, 1080i50/59.94/60, 1080p23.98 … 1080p60 (no SD, no UHD) | [T] |
| Sampling | “8, 10 RGB 4:4:4 in all modes up to 1080p30 and 8, 10-bit YUV 4:2:2 in all modes” | [T] |
| Colorimetry | Rec. 709 | [T] |
| Video coding | **SMPTE 2110-20 (uncompressed)**. The 3x3G has no codec entry. Blackmagic names **IP10** only for 12G models (“used when converting 2160p59.94 and 2160p60”), so not for the 3x3G. | [T], [H] p. 33 |
| Sender profile | ST 2110-21 sender **Narrow** | [T] |
| Audio | ST 2110-30, **Level C**, 48 kHz, 24-bit, up to 16 embedded channels per SDI channel | [T] |
| Number of streams | 3 video input and 3 video output channels up to 1080p60, each with audio and ancillary data | [T] |
| Ancillary | ST 2110-40 (timecode, captions, HDR metadata) | [T] |
| Ethernet | 1 × 10 Gbit/s RJ-45 (10GBASE-T, PoE+), point-to-point or via a switch | [T], [H] p. 80 f. |
| Multicast | IGMPv3, “managed 10G switch that supports IGMP version 3 snooping”; addresses and ports per stream automatic or manual | [H] p. 24, 32 |
| PTP | IEEE 1588-2008, ST 2059-1/-2; domain “commonly 127”; the device **can become master itself** if “PTP follower only” is not set | [T], [H] p. 25, 31 |
| NMOS | IS-04 v1.3.2 **peer-to-peer via mDNS/DNS-SD**, IS-05 v1.1.2, BCP-002-01 (natural grouping), BCP-004-01 | [T] |
| NMOS registry | optional: “can be entered manually or check auto to automatically discover” | [H] p. 32 |
| ST 2022-7 | not on the 3x3G (only SDI to HDMI 12G-10 and SDI Expander 8x12G) | [H] p. 26 |
| Other control | REST API, configuration via USB-C with “Blackmagic Converters Setup” | [T], [H] p. 27 |

**Not found in the documentation** (to be determined on the device in the test plan):

* whether one 16-channel audio stream at 125 µs or two 8-channel streams at 1 ms are sent. Arithmetically, 16 × 48 samples × 3 bytes = 2304 bytes at 1 ms do not fit into a standard Ethernet packet, so 16 channels in one stream require 125 µs (ST 2110-30 Level C).
* how the devices name senders and groups in NMOS, and whether every sender has a `manifest_href` (SDP),
* the port of the NMOS Node API (announced via mDNS, so not critical),
* the packet size (standard MTU or jumbo frames) and the behavior with 1080i.

## Consequences for the app

| Topic | Decision |
|---|---|
| Video | Uncompressed ST 2110-20, YCbCr 4:2:2 10 and 8-bit, progressive: **supported**. Verified target formats are 1080p25 and 1080p50; 720p and 1080p at other frame rates are received but not verified. |
| 1080i, PsF | **Not supported.** GStreamer’s depayloader `rtpvrawdepay` 1.28 reports “interlaced formats not supported yet” (confirmed in the binary [G]). The app detects this from the SDP and the packet headers (F bit) and reports it with a fix: **set a progressive format on the SDI source device** (e.g. camera or ATEM to 1080p25/1080p50). The 3x3G passes on the format of its SDI input; it has no format converter. |
| RGB 4:4:4 | **Not supported** (GStreamer handles RGB only at 8-bit, untested). Message with a fix: set the source device to YUV 4:2:2. |
| IP10 / JPEG XS | Not supported, detected and reported. Not relevant for the 3x3G according to the manufacturer. |
| Audio | ST 2110-30 L24/L16, 1–64 channels, any packet time (1 ms and 125 µs tested). Channel count and packet time are taken from the SDP and **measured again on the received packets**. |
| Discovery | NMOS IS-04 peer-to-peer via mDNS (`_nmos-node._tcp`). **No registry is needed.** In addition: registry (mDNS `_nmos-query._tcp` or manual), manual device address, scanning a configurable address range. |
| Pairing video/audio | via BCP-002-01 group tags; otherwise via the number in the label (marked “suspected”); audio can be assigned freely. |
| Connection control | IS-05: read status. Enabling a sender or setting a destination only after explicit permission, because it affects every receiver. Receiving on the Mac needs no IS-05 receiver: the Mac joins the multicast group itself. |
| PTP | The Mac takes part only as a **passive slave** (GStreamer PTP client, never master, sends no Announce messages, only Delay_Req). Production timing is not changed. **Important:** if no grandmaster is running and “PTP follower only” is not set on the 3x3G, the 3x3G becomes master itself [H]. |
| Interface | 10GBASE-T on the 3x3G matches Thunderbolt 10GbE adapters (RJ-45) directly, also point-to-point without a switch. |

## GStreamer on macOS / Apple silicon (checked on the package [G])

| Check | Result |
|---|---|
| Architecture | universal (x86_64 + arm64), minimum macOS 10.13, built with SDK 26.2 |
| Relocatability | all libraries via `@rpath`, plugins with `@loader_path/../lib`, so they can be embedded in the app without installing to `/Library/Frameworks` |
| `rtpvrawdepay` | YCbCr 4:2:2 with `depth=10` → output `UYVP` (pgroup format); 8-bit → `UYVY`; **no interlaced** |
| `rtpL24depay`/`rtpL16depay` | available (plugin `rtp`) |
| `udpsrc` | available (plugin `udp`). The app joins multicast itself (see below). |
| Audio output | `osxaudiosink` (CoreAudio), device selectable |
| PTP | `gst-ptp-helper` (Rust) included for macOS, without further library dependencies |
| Picture output | own Metal renderer: 10-bit output, BT.709 color management, no OpenGL dependency |
| License | required plugins and libraries: LGPL/BSD/MIT/zlib. No GPL components. Embedded size about 17 MB (arm64). |

**Own code where GStreamer alone is not enough:**

1. *Multicast join on a specific interface.* On macOS GLib joins IPv4 groups without reliable interface selection. The app therefore opens the socket itself (join via the IPv4 address of the chosen interface, `IP_BOUND_IF`, SSM when a source is given) and hands it to `udpsrc`.
2. *Lip sync.* Instead of two independent players, the app sets the output time of every RTP packet from its RTP timestamp (see [synchronization](synchronization.md)).

## Result

Receiving 1080p25/50, YCbCr 4:2:2 10-bit, with ST 2110-30 audio from the 3x3G is **technically feasible** with GStreamer on macOS on Apple silicon. No capture card or paid SDK is needed. Limitations:

* **1080i is not supported.** The source device must be set to progressive.
* 1080p50 produces about 2.2 Gbit/s and roughly 190,000 packets per second. Whether a Mac with a Thunderbolt 10GbE adapter receives this without loss over long periods depends on the adapter and driver. macOS limits the socket buffer to 8 MB without administrator changes. **This has to be measured on the device** (test plan T4).
* Without an Apple Developer account notarization is not possible. The first launch needs “Open Anyway” once.
