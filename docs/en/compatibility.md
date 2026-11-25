# Compatibility: models, firmware, formats

[Deutsch](../02-Kompatibilitaet.md)

**Legend:** **D** = documented only (manufacturer information or standard); **S** = synthetically tested (own test sender, Linux or macOS CI); **H** = verified with Blackmagic hardware

> **First hardware test (November 2026):** 2110 IP Converter 3x3G, MikroTik CRS305 with SFP+ copper modules, MacBook Pro M4 with a USB 2.5 GbE adapter. Verified (**H**): discovery via NMOS, PTP (3x3G as grandmaster, domain 123), turning on the device's senders via IS-05, receiving from the 3x3G, sending from the app to the 3x3G (receiver chosen in Converters Setup). Further items fill up with test results (see the [test plan](test-plan.md)).
>
> **Findings from the test:**
> * The 3x3G's senders were **inactive** out of the box (NMOS `master_enable: false`); the display showed “N/C”. Only after “Turn on” (IS-05) does the device send.
> * According to the data sheet the Ethernet port supports 10M/100M/1G/10G, not 2.5G/5G. 1080p25 needs about 1.1 Gbit/s, 1080p50/60 about 2.2–2.6 Gbit/s; a 1 Gbit/s path (e.g. a 1G SFP module in the switch) then loses a large share of packets.
> * The 3x3G refuses **720p25** via IS-05 (“SDP format refused”); use standard formats such as 1080p25.
> * Up to version 1.2.4 the PTP helper aborted without root rights; fixed from 1.2.4.

## Devices

| Model | Firmware | Status |
|---|---|---|
| Blackmagic 2110 IP Converter 3x3G | still to be recorded (Blackmagic Converters Setup › Setup › Software) | D (manual 09/2026, tech specs), **H** (first test, see above) |
| other Blackmagic 2110 devices (Mini BiDirect, SDI to HDMI 12G …) | – | not covered by this version. At 2160p59.94/60 the 12G models send **IP10**, which is not supported. |

## Video formats (ST 2110-20, uncompressed)

| Format | Sampling | Status | Note |
|---|---|---|---|
| 1080p25 | YCbCr 4:2:2 10-bit | **S**, H pending | target format |
| 1080p50 | YCbCr 4:2:2 10-bit | **S** (synthetic up to 720p50 without loss; 1080p50 limited by the test sender in the Linux test environment), H pending | target format, about 2.2 Gbit/s |
| 1080p23.98/24/29.97/30/59.94/60 | YCbCr 4:2:2 10-bit | D, received | not verified; the app shows a note |
| 720p50/59.94/60 | YCbCr 4:2:2 10-bit | S (720p50) | not verified |
| 8-bit 4:2:2 | YCbCr 4:2:2 8-bit | D (code path implemented) | |
| **1080i50/59.94/60** | – | **not supported** | fix: set 1080p25 or 1080p50 on the SDI source device |
| RGB 4:4:4 (up to 1080p30 according to Blackmagic) | – | **not supported** | fix: set the source device to YUV/YCbCr 4:2:2 |
| Blackmagic IP10, JPEG XS (ST 2110-22) | – | **not supported** | not used by the 3x3G according to the manufacturer |

## Audio (ST 2110-30)

| Variant | Status |
|---|---|
| L24, 48 kHz, 16 channels, 125 µs | S |
| L24, 48 kHz, 8 channels, 1 ms | S |
| L24, 48 kHz, 2 channels, 1 ms | S |
| L16 | D (code path implemented) |
| AM824 (ST 2110-31) | not supported |
| Actual sender configuration of the 3x3G (channel count and packet time per stream) | **H pending** (test plan T2) |

## Discovery and control

| Function | Status |
|---|---|
| NMOS IS-04 peer-to-peer (mDNS `_nmos-node._tcp`) | D (Blackmagic information), client S (unit tests with simulated IS-04 responses), **H** |
| NMOS registry (Query API) | D, S (same code as the Node API) |
| Grouping video/audio (BCP-002-01) | D, S |
| SDP via `manifest_href` or IS-05 `transportfile` | S |
| IS-05 enable sender / set destination | D, implemented, **H** (turning on the 3x3G) |
| Manual device address / address range scan | S (parser), H pending |
| SDP file, drag and drop, text entry, separate video/audio SDP | S |

## Network and time

| Function | Status |
|---|---|
| Multicast join ASM and SSM on the chosen interface | S (Linux), macOS path (IP_BOUND_IF) H pending |
| PTP passive slave, domain from SDP or configurable | S (software grandmaster linuxptp, Linux), **H** (3x3G as grandmaster, domain 123) |
| Fallback when the sender does not match the grandmaster | S |
| RTP-aligned lip sync | S: offset < 0.2 ms at the output timestamps |
| Sender restart, interruption, format change, packet loss | S |
| Picture output on a second display (borderless window, separate renderer) | D, implemented, to be checked on a real Mac with a second display |

## Sending and analysis

| Function | Status |
|---|---|
| Sending ST 2110-20 1080p25/50/29.97/59.94, 720p50/59.94 (10-bit) | S (own receiver, Linux and macOS CI) |
| Sending ST 2110-30 L24, 1–16 channels, 1 ms/125 µs | S |
| File (AVFoundation) and camera sources | D, implemented, to be checked on a real Mac (T13) |
| NMOS node (IS-04 Node API, mDNS) and IS-05 for the sender | S (unit tests: own client reads the resources) |
| IS-05: connecting a receiver on the 3x3G | D, implemented, H partly: accepted via Converters Setup **H**; 720p25 refused by the device |
| Analysis of pcap/pcapng: formats, loss, Cinst/VRX, TS-DF, PTP, IGMP | S |

## Recommended device settings (3x3G)

* **Video format:** progressive on the SDI source device, 1080p25 or 1080p50, YUV 4:2:2 10-bit.
* **PTP:** with a grandmaster on the network, enable “PTP follower only” and use the grandmaster’s domain (usually 127). Without a grandmaster exactly one device may be master. The app never becomes master.
* **Multicast:** a unique address per stream (Converters Setup › 2110 › Multicast Address). On the switch, IGMPv3 snooping **with a querier**.
* **NMOS:** peer-to-peer (mDNS) is enough for the app. A registry is optional.
* **Network:** Mac and 3x3G in the same IP subnet so that mDNS and IGMP work.
