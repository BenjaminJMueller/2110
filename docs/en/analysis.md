# Analyzing packet captures

[Deutsch](../08-Analyse.md)

2110 Viewer analyzes pcap and pcapng files with ST 2110 traffic. The feature set is modeled on EBU LIST; the code is independent. The focus is troubleshooting, not playback.

## Where does the capture come from?

| Source | Timing accuracy | Suitable for |
|---|---|---|
| Hardware capture (capture NIC with PTP timestamps, mirror port + measurement device) | ns | all values, including ST 2110-21 |
| Wireshark/tcpdump on a Mac or PC | µs, software | loss, formats, PTP, IGMP; timing values only approximate |
| 2110 Viewer: Receive › Diagnostics › Record | software, ns resolution | as above; the file is marked as a software capture |

For picture reconstruction capture at least 1600 bytes per packet (snaplen).

## What is evaluated

| Area | Measurements |
|---|---|
| Capture | format, link type (Ethernet, VLAN, Linux cooked, loopback), duration, time resolution, IP fragments, truncated packets |
| Every RTP stream | source/destination, SSRC, payload type, data rate, loss, duplicates, reordering, SSRC changes, packet intervals (statistics, histogram, over time) |
| Video (ST 2110-20) | frame size and bit depth **without an SDP** from the line headers, frame rate from the RTP timestamps, packets per frame, marker, packet spread duration, RTP latency, **Cinst** and **VRX** with limits for Narrow and Wide, thumbnail |
| Audio (ST 2110-30) | packet time, channel count (from SDP or estimated), **TS-DF** per second, RTP latency |
| Ancillary data (ST 2110-40) | DID/SDID, e.g. timecode, captions |
| PTP | domains, grandmaster, number of active masters (warning if more than one), priority, clock class, Sync/Announce rates, Delay_Req/Resp, UTC offset |
| IGMP | querier, queries (v2/v3), joins and leaves per group |

SDP files can be passed in (`st2110-analyze --sdp`); in the app the source’s SDPs are used automatically when recording.

## Formulas (ST 2110-21:2017)

* Cinst: bucket model, +1 per packet, draining one packet every `TDRAIN = (TFRAME/NPACKETS)/1.1`.
  Limits: `CMAX(N) = max(4, ⌊NPACKETS/(43200·RACTIVE·TFRAME)⌋)`, `CMAX(W) = max(16, ⌊NPACKETS/(21600·TFRAME)⌋)`.
* VRX: from the first packet of a frame the receiver reads one packet every `TRS = TFRAME·RACTIVE/NPACKETS`.
  Limits: `VRX_FULL(N) = max(8, ⌊NPACKETS/(27000·TFRAME)⌋)`, `VRX_FULL(W) = max(720, ⌊NPACKETS/(300·TFRAME)⌋)`.
  2110 Viewer aligns the VRX model to the first packet (TRO from the capture), not to the absolute frame time, because that would require a PTP-synchronized capture.
* `RACTIVE` = active lines / total lines (1080/1125, 720/750).

## Command line

```bash
st2110-analyze capture.pcapng --sdp video.sdp --sdp audio.sdp --json > report.json
st2110-analyze capture.pcapng --thumb 1 frame.ppm
```

## Tested

Synthetic: captures of the app’s own sender (software capture and tcpdump, also with artificial loss and IP fragments), PTP and IGMP with linuxptp in a network namespace. With Blackmagic captures: **pending** (test plan A1–A3).
