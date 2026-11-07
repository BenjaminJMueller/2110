# Synchronizing picture and sound

[Deutsch](../03-Synchronisation.md)

## Basics

Per ST 2110-10 and ST 2059-1, the RTP timestamp of a packet is
`floor(PTP time of capture × clock rate) mod 2³²`. Video runs at 90 kHz, audio at 48 kHz. The SDP points to this with
`a=ts-refclk:ptp=IEEE1588-2008:<GM>:<domain>` and `a=mediaclk:direct=0`.
Video and audio packets from the same sender therefore carry timestamps from **the same clock**, and the capture time of every packet can be calculated back. The timestamp only wraps after 13.2 h (video) or 24.8 h (audio); a rough reference time is enough to make it unambiguous.

## The app’s three modes

| Mode | What happens | Lip sync? |
|---|---|---|
| **Simple preview** | Each stream is played as it arrives (like two independent players). | **No.** Different delays remain; in synthetic tests, for example, 25–200 ms. |
| **Time-aligned (RTP)** | The capture time of every packet is calculated from its RTP timestamp. Both streams get **the same** offset to the Mac’s clock and the same fixed latency. The drift between the sender’s and the Mac’s clock is tracked slowly (jointly for both streams). | **Yes**, as long as the sender stamps both streams from the same clock, which ST 2110 requires. |
| **PTP-synchronized** (default “Automatic”) | The Mac runs as a passive PTP slave. The playback clock is the grandmaster’s PTP time; output time = capture time + latency. | **Yes**, and aligned to the studio clock. |

“Automatic” waits up to 4 s for a grandmaster and otherwise falls back to “Time-aligned”; the app reports this. If the sender’s timestamps are more than 1 s off PTP time, the sender is synchronized to another grandmaster, another domain or another time scale. In that case too the app falls back with a message instead of freezing the picture.

## Role in the PTP network

The app uses GStreamer’s PTP client, a pure **slave-only participant**:
it evaluates Announce, Sync and Follow_Up messages and sends only Delay_Req.
It never sends Announce and **cannot become master**. The timing of the production network is not changed.

## Latency

A video frame is complete only after its last packet. With ST 2110-21 “Narrow” that is about one frame duration after capture (40 ms at 25p). The default is 120 ms. If data arrives later, the app raises the buffer automatically up to at most 1000 ms and reports it. Video and audio are always delayed together.

## Manual audio offset

Under “Advanced › Audio” the sound can be delayed by 0–500 ms, for example to compensate for a display’s processing time. It **does not replace synchronization** and is not included in the measurement below.

## Measuring lip sync

The app measures objectively with a test signal fed into the SDI input of the 3x3G: a white flash in the middle of the picture and a simultaneous tone onset, for example from a test signal generator or a suitable clip on a HyperDeck. It measures the gap between flash and tone onset at the pipeline’s **output timestamps**. Display and audio device latency are not included. For the whole chain (including the display) the test plan adds a recording with a high-speed camera (phone slow motion).

Synthetic results (Linux, test sender with ST 2059-style timestamps):

| Case | Result |
|---|---|
| RTP-aligned, 1080p25 + 16 ch | +0.0 … +0.1 ms |
| PTP (software grandmaster) | +0.02 ms |
| Audio timestamps deliberately offset by +40 ms | +40.0 ms measured: the app follows the timestamps and does not compensate anything “silently”. |
| Simple preview, same sender | −25 … −216 ms: **not in sync**, as expected |
