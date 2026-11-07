# Test plan with Blackmagic hardware

[Deutsch](../06-Testplan.md)

Goal: verification with **real Blackmagic hardware**. Please report every row with the result (✔/✘), the date and, where requested, the **diagnostics report** (Diagnostics › Copy Report). Template: section 8.

## 0 Inventory (fill in before testing)

| # | Item | Value |
|---|---|---|
| 0.1 | Number and serial numbers of the 2110 IP Converter 3x3G units | |
| 0.2 | Firmware (Converters Setup › Setup › Software) | |
| 0.3 | Version of “Blackmagic Converters Setup” | |
| 0.4 | SDI sources and their format (camera/ATEM …, e.g. 1080p50 YUV 4:2:2 10-bit) | |
| 0.5 | Switch (make/model), IGMPv3 snooping on? Querier on? | |
| 0.6 | PTP grandmaster (model, domain, profile) or “none” | |
| 0.7 | On the 3x3G: “PTP follower only” on/off, domain | |
| 0.8 | NMOS registry available? Which one? | |
| 0.9 | Mac: model, chip (M4 …), macOS version | |
| 0.10 | Network adapter (make/model, 10GBASE-T?) | |
| 0.11 | IP address of Mac / 3x3G, subnet, DHCP or static | |

## 1 Installation on a Mac without developer tools

| # | Step | Expected |
|---|---|---|
| I1 | Copy the DMG from the release to a Mac **without Xcode, Homebrew or GStreamer** (check: `/Library/Frameworks/GStreamer.framework` does not exist) | |
| I2 | Drag the app to Applications, open it, “Open Anyway” if needed | app starts, introduction appears |
| I3 | Local Network prompt | appears; no further prompt after “Allow” |
| I4 | Demo mode | color bars, flash + tick every second, “Demo without network” visible, level about −6 dBFS |
| I5 | Help › Getting Started, Advanced › About | GStreamer 1.28.8 “(included in the app)”, no missing components |
| I6 | Set the system language to English and German in turn (System Settings › General › Language & Region) | app appears completely in that language |

## 2 Discovery and formats

| # | Step | Expected / to record |
|---|---|---|
| T1 | Mac on the switch, open the app, wait 30 s | 3x3G inputs appear under “On the Network” (mDNS). Record labels, format and number of audio senders. |
| T1b | If nothing appears: add the device by address | appears; tell us: is mDNS blocked on the network? |
| T1c | With a registry (if available): enter it under Advanced › Registry | sources also via the registry |
| T2 | Select source SDI 1 with **1080p25** | picture + sound; Diagnostics: 1920×1080, 25.000 fps; record the audio channel count and the **measured packet time**; attach the report |
| T3 | Step through channels (⌘]), single channel, custom pair, change the output device (e.g. USB headphones) | the right channel is audible each time (put different content on the source’s channels, e.g. a voice saying “channel 3”) |
| T4 | **1080p50** | smooth picture; after 10 min Diagnostics: video packet loss (%)? Dropped frames? Attach the report |
| T5 | Set the source device to **1080i50** | message “interlaced … not supported” with a fix |
| T6 | Switch the format from 1080p25 to 1080p50 during playback | the app loads the new SDP via NMOS (event “sender changed its parameters”) and keeps playing; with an SDP source: format message |
| T7 | SDP file: save it from the NMOS URL (e.g. browser: `http://<3x3G>/x-nmos/…`) or Converters Setup, drag it into the window; assign separate video and audio SDPs | source plays and is still there after restarting the app |
| T8 | Manual entry (expert) with addresses from Converters Setup › 2110 | plays |

## 2b Sending to the Blackmagic device

| # | Step | Expected |
|---|---|---|
| T9 | Send mode, test pattern 1080p25, 2 channels, “Time from PTP grandmaster” on, “Offer as NMOS source” on, “Send” | status “PTP, grandmaster …”, data rate about 1.1 Gbit/s |
| T10 | On the 3x3G, look in the LCD menu under *Outputs* or Converters Setup › 2110 › Receiver | the 2110 Viewer stream appears in the list; after selecting it, color bars and 1 kHz at the SDI output |
| T11 | Alternatively, in 2110 Viewer “Send to a Device › Connect” (IS-05) | SDI output shows color bars; record the result and any error message |
| T12 | Send the lip-sync test, SDI output to a monitor with speaker, film in slow motion | flash and beep together (± 1 frame) |
| T13 | Send a video file (H.264 MP4) and the camera | smooth playback at the SDI output; record “Sent late” and “Audio buffer” |
| T14 | Send 1080p50, capture it with 2110 Viewer (second Mac) or an analyzer | record ST 2110-21 class, Cmax, loss |

## 2c Analysis

| # | Step | Expected |
|---|---|---|
| A1 | Receive from 3x3G › Diagnostics › “Record 10 s and Analyze” | the analysis shows the video and audio streams, the format is detected correctly without SDP, the thumbnail is correct |
| A2 | Open a Wireshark capture from a mirror port (if available) | PTP domain, grandmaster, IGMP querier visible; record the result |
| A3 | ST 2110-21 class of the 3x3G sender (“Narrow” according to the manufacturer) with a hardware capture | class “Narrow”; with a software capture only approximate |

## 3 Synchronization

| # | Step | Expected |
|---|---|---|
| S1 | With a grandmaster: mode “Automatic” | status “PTP-synchronized”; Diagnostics: GM ID = GM in SDP, domain, path delay |
| S2 | Without a grandmaster or with the wrong domain | fallback “time-aligned (without PTP)” with an understandable message |
| S3 | **Lip sync (objective):** flash/beep test signal at the SDI input (test signal generator, ATEM media player or HyperDeck clip with a white flash in the middle of the picture and a simultaneous tone) | Diagnostics › lip-sync measurement: mean within **±5 ms** (output timestamps), in both “Automatic” and “RTP” modes |
| S4 | Same signal in “Simple preview” mode | record the value (shows the difference for teaching) |
| S5 | **Lip sync (whole chain):** film display and speaker with a phone in slow motion (240 fps) | offset flash ↔ tone onset ≤ 1 frame (EBU R37: sound at most 40 ms early, 60 ms late); set the audio offset if needed and record the value |
| S6 | PTP role: check on the grandmaster or switch that the Mac does **not** appear as master | Mac visible only as slave/follower |

## 4 Reliability

| # | Step | Expected |
|---|---|---|
| R1 | **8-hour run** 1080p50 with audio | app responsive; report at the end: loss, dropped frames, realignments, drift, memory (Activity Monitor) |
| R2 | **Sender restart:** switch the 3x3G off and on | “Signal lost”, then picture and sound return automatically, in lip sync (repeat S3) |
| R3 | **Link interruption:** unplug the Mac’s network cable for 10 s and plug it back in | message, automatic reconnect |
| R4 | Unplug the SDI cable at the 3x3G | understandable message, resumes after plugging back in |
| R5 | **Wrong interface** (Advanced › choose Wi-Fi) | note “Possibly the wrong network interface” or “Wi-Fi selected” with a suggestion |
| R6 | **No multicast:** turn off the IGMP querier on the switch or use a wrong group | “No data received” + list of possible causes (marked as suspected) |
| R7 | **High load:** run a CPU-heavy app during 1080p50, resize the window, full screen, open Diagnostics | interface stays responsive; record loss |
| R8 | Deny Local Network in System Settings, restart the app | understandable message or note; works again after allowing |

## 5 Usability and accessibility

| # | Step | Expected |
|---|---|---|
| B1 | Keyboard only (Tab, Space, ⌘ shortcuts) | all functions reachable |
| B2 | VoiceOver on (⌘F5) | controls, status and levels are announced |
| B3 | Light/dark mode, “Reduce transparency”, “Increase contrast” | easy to read, picture unchanged |
| B4 | macOS 26: Liquid Glass only on the controls, never over the picture (except the control bar shown in full screen) | |
| B5 | macOS 14/15 (if available) | same functions, materials instead of glass |

## 6 Picture evaluation

| # | Step | Expected |
|---|---|---|
| V1 | 75 % SMPTE color bars from the source device, compared with a reference monitor at the SDI output | plausible colors (Mac display: BT.709 color management by macOS) |
| V2 | 10-bit gray ramp | no banding beyond 8-bit level (output is 10-bit) |

## 7 Command-line check (optional, for the support team)

The self-test is inside the bundle: `"/Applications/2110 Viewer.app/Contents/MacOS/ST2110Viewer" --selftest`.
The receive core can also be built as the tool `st2110-probe` (see [build and distribution](build-and-distribution.md)); with `--json` it records machine-readable results.

## 8 Feedback template

```
Test ID:            (e.g. T4)
Date, tester:
Device/firmware:
Result:             ✔ / ✘
Observation:
Diagnostics report: (Copy Report and paste it here)
```

With this feedback the entries in [compatibility](compatibility.md) are changed from “D/S” to “H”.
