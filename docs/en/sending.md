# Sending

[Deutsch](../09-Senden.md)

2110 Viewer sends ST 2110-20 (YCbCr 4:2:2, 10-bit) and ST 2110-30 (L24, 1–16 channels). Receivers can be Blackmagic devices or any other ST 2110 device.

## Sources

| Source | Notes |
|---|---|
| Test pattern | 75 % color bars, gray scale, moving bar; 1 kHz tone at −18 dBFS |
| Lip-sync test | Black picture, white flash and beep at every full second (by timestamp). You can check it at the converter’s SDI output with a monitor and a phone’s slow-motion camera; 2110 Viewer’s receiver measures it automatically. |
| Video file | Anything macOS can play (e.g. H.264, HEVC, ProRes; audio AAC/PCM). Decoded with AVFoundation, scaled to the send format (aspect ratio kept), in real time and looped. 2110 Viewer ships no codecs of its own. |
| Camera | Built-in or USB camera, Continuity Camera; sound from the chosen microphone. macOS asks for camera and microphone access. |

## Formats

1080p25, 1080p50, 1080p29.97, 1080p59.94, 720p25, 720p50, 720p59.94. The 3x3G outputs these progressive HD formats on its SDI output (according to its tech specs). Audio: up to 8 channels at 1 ms, more channels at 0.125 ms (ST 2110-30 Level C).

## Time reference

With the “Time from PTP grandmaster” switch, 2110 Viewer synchronizes passively to the grandmaster (follower only) and sets the RTP timestamps to PTP time. This is what lets receivers match picture and sound correctly in time. Without a grandmaster the system clock serves as an approximation; the SDP then says `ts-refclk:localmac`.

## Packet pacing

The packets of a frame are spread evenly over the active frame time (profile “Narrow Linear”, `TP=2110TPNL`). 2110 Viewer paces in software. On a heavily loaded computer this can be burstier than ST 2110-21 allows for Narrow; according to its tech specs the Blackmagic 2110 IP Converter 3x3G accepts Narrow, Wide and Asynchronous senders. The analysis shows how even your own stream really is (record a capture and look at Cinst/VRX).

## Getting it to the device

1. **NMOS (recommended):** 2110 Viewer announces itself as an NMOS node via mDNS (IS-04 Node API, and IS-05 for its senders). According to the Blackmagic manual, the 3x3G lists the 2110 streams available on the network in its LCD menu under *Outputs* and in Converters Setup; whether the 2110 Viewer stream appears there is checked in test T10. An NMOS controller sees it as well. With a registry: enter its address under Advanced › NMOS, and 2110 Viewer registers there.
2. **IS-05 directly from 2110 Viewer:** under “Send to a Device” choose the receiver (e.g. “SDI Out 1”) and click “Connect”. 2110 Viewer sends the SDP to the receiver via IS-05.
3. **SDP file:** copy or save the SDP and load it into the target device or software.

## Data rates

| Format | Video | with 16 audio channels |
|---|---|---|
| 1080p25 | about 1.07 Gbit/s | + 19 Mbit/s |
| 1080p50 | about 2.14 Gbit/s | + 19 Mbit/s |

Sending only makes sense over wired Ethernet; 2110 Viewer warns about Wi-Fi.

## Tested

Synthetic: 2110 Viewer’s sender and receiver against each other (format, frame rate incl. 29.97, 125 µs/1 ms, lip sync < 1 ms), analysis of a capture of the app’s own stream. NMOS resources are read by the app’s own IS-04 client in unit tests. With Blackmagic hardware: **pending** (test plan T9–T12).
