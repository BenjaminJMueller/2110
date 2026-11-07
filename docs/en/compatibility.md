# Compatibility: models, firmware, formats

[Deutsch](../02-Kompatibilitaet.md)

**Legend:** **D** = documented only (manufacturer information or standard); **S** = synthetically tested (own test sender, Linux or macOS CI); **H** = verified with Blackmagic hardware

> As of this version **nothing has been verified with Blackmagic hardware yet.** Column H fills up with your test results (see the [test plan](test-plan.md)).

## Devices

| Model | Firmware | Status |
|---|---|---|
| Blackmagic 2110 IP Converter 3x3G | still to be recorded (Blackmagic Converters Setup › Setup › Software) | D (manual 09/2026, tech specs), H pending |
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
| NMOS IS-04 peer-to-peer (mDNS `_nmos-node._tcp`) | D (Blackmagic information), client S (unit tests with simulated IS-04 responses), H pending |
| NMOS registry (Query API) | D, S (same code as the Node API) |
| Grouping video/audio (BCP-002-01) | D, S |
| SDP via `manifest_href` or IS-05 `transportfile` | S |
| IS-05 enable sender / set destination | D, implemented, only after it is enabled in settings, H pending |
| Manual device address / address range scan | S (parser), H pending |
| SDP file, drag and drop, text entry, separate video/audio SDP | S |

## Network and time

| Function | Status |
|---|---|
| Multicast join ASM and SSM on the chosen interface | S (Linux), macOS path (IP_BOUND_IF) H pending |
| PTP passive slave, domain from SDP or configurable | S (software grandmaster linuxptp, Linux), H pending |
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
| IS-05: connecting a receiver on the 3x3G | D, implemented, **H pending** (T11) |
| Analysis of pcap/pcapng: formats, loss, Cinst/VRX, TS-DF, PTP, IGMP | S |

## Recommended device settings (3x3G)

* **Video format:** progressive on the SDI source device, 1080p25 or 1080p50, YUV 4:2:2 10-bit.
* **PTP:** with a grandmaster on the network, enable “PTP follower only” and use the grandmaster’s domain (usually 127). Without a grandmaster exactly one device may be master. The app never becomes master.
* **Multicast:** a unique address per stream (Converters Setup › 2110 › Multicast Address). On the switch, IGMPv3 snooping **with a querier**.
* **NMOS:** peer-to-peer (mDNS) is enough for the app. A registry is optional.
* **Network:** Mac and 3x3G in the same IP subnet so that mDNS and IGMP work.
