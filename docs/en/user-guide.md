# 2110 Viewer – Quick Guide

[Deutsch](../05-Nutzeranleitung.md)

For anyone who wants to watch and listen to Blackmagic ST 2110 devices on a Mac. No programming knowledge needed.

## Install (once)

1. Double-click `2110-Viewer-….dmg`.
2. Drag **2110 Viewer** onto **Applications**.
3. Open the app from Applications. If macOS says the app cannot be verified, click **“Open Anyway”** in **System Settings › Privacy & Security**. This is only needed the first time.
4. If macOS asks about the **local network**, please allow it. Without this permission the app finds no devices and receives nothing.

The app follows the system language and appears in English or German.

## Watch and listen

1. Connect the Mac to the ST 2110 switch with a 10GbE adapter (for example a Thunderbolt one) and a network cable, or directly to the “10G Ethernet” port of the 2110 IP Converter 3x3G.
2. Open the app.
3. The Blackmagic inputs appear on the left under **“On the Network”**, for example “Studio Converter – SDI 1”. Click one.
4. Picture and sound now play. In the bar at the bottom a green dot shows “Receiving, PTP-synchronized” or “Receiving, time-aligned”.

| Control | Function | Keyboard |
|---|---|---|
| Play/Stop | playback | Space, ⌘↩ |
| Headphones menu | channel pair (1+2, 3+4 …), single channel or custom pair | ⌘[ / ⌘] |
| Speaker symbol, slider | mute, volume | M, ⌘↑ / ⌘↓ |
| Hi-fi symbol | audio output device (default: system output) | |
| Arrows | full screen (Esc exits) | ⌃⌘F |
| Second Display (toolbar) | full-screen picture on a monitor or projector, controls stay in the main window | ⌘⇧B |
| Diagnostics (toolbar) | formats, packet loss, synchronization, PTP, recording | ⌘I |
| Mode | Receive, Send, Analyze | ⌘1, ⌘2, ⌘3 |
| “?” (toolbar) | introduction “How ST 2110 Works” | |
| Advanced (toolbar) | network, synchronization, NMOS, address ranges | ⌘, |

The level meter shows all channels; monitored channels are outlined.

## Output on a second display

Connect a monitor or projector and choose “Extend” (not “Mirror”) in *System Settings › Displays*. In the toolbar choose **Second Display** and pick the display. It shows only the video picture, full screen, without a pointer, in the correct aspect ratio with black bars. Play, channels, volume and diagnostics stay in the main window. ⌘⇧B turns the output on and off (last used display). If the display is disconnected, the output turns off.

## Send

Choose **Send** in the toolbar (⌘2). Pick a source (test pattern, lip-sync test, video file or camera), set the format and audio channels, then click **Send**. Under “Send to a Device” you can connect a Blackmagic output directly; otherwise select the 2110 Viewer stream on the device. Details: [Sending](sending.md).

## Analyze

**Analyze** (⌘3) opens pcap or pcapng captures (for example from Wireshark). While receiving, **Diagnostics › Record 10 s and Analyze** makes a capture and opens it right away. The streams found are listed on the left; on the right are key figures, a chart and plain-language findings. Details: [Analysis](analysis.md).

## Appearance

Light, Dark or System: Settings (⌘,) › General. The video picture stays the same.

## If no source appears

* **“Add Device by Address…”** (plus menu): enter the IP address of the 3x3G. It is shown on the device’s LCD menu under Setup › Network.
* Or drag an **SDP file** into the window. Separate video and audio SDPs can be dragged in together, or assigned to the **Video SDP** and **Audio SDP** fields in the “New Source” window.
* Under **Advanced › NMOS & Addresses** you can scan an address range (for example `192.168.10.1-254`).

Saved sources appear under “Saved” the next time you start the app.

## If there is no picture

The app shows in the picture and below the bar what it has **measured** (for example “No data received”) and what the cause **probably** is (marked “suspected”). Common causes:

| Message | What to do |
|---|---|
| Possibly the wrong network interface | Advanced › Network › choose the interface in the Blackmagic devices’ network |
| Wi-Fi selected | use a wired connection (10GbE) |
| No data received | check IGMP snooping with a querier on the switch; is the sender active? Is Local Network access allowed? |
| Interlaced (1080i) not supported | set the camera or switcher to **1080p25** or **1080p50** |
| RGB 4:4:4 not supported | set the source device to YUV 4:2:2 |
| Playing without PTP | picture and sound stay in lip sync; only the alignment to the studio clock is missing |

For feedback: **Diagnostics › Copy Report** and send the text to the person looking after the setup.

## Demo mode

**“Test Pattern and Tone”** (sidebar, under “Try It”) shows color bars and a tone tick once a second, together with a white flash. The top left corner says “Demo without network”. This lets you check display, sound and controls without a network.

## For teaching: preview vs. synchronized

Under Advanced › Synchronization you can choose “Simple preview”. Each stream is then played as it arrives. With a flash-and-beep test signal, Diagnostics shows that picture and sound are then **not** in lip sync; in “Automatic” mode they are.
