# Test report: first test with Blackmagic hardware

[Deutsch](../10-Testbericht.md)

**Date:** 25 November 2026  
**Result:** successful. 2110 Viewer receives ST 2110 from the Blackmagic 2110 IP Converter 3x3G and sends ST 2110 to it; PTP and NMOS work together with the device.

## Setup

| Component | Device | Details |
|---|---|---|
| ST 2110 device | Blackmagic 2110 IP Converter 3x3G (“3x3G Stage #3”) | software: latest at the time of the test, Blackmagic Converters 12.4.2 (4 November 2026); PTP grandmaster of the setup (domain 123, “PTP Follower Only” off); IP 192.168.88.3 |
| Switch | MikroTik CRS305-1G-4S+ | 4 × SFP+; factory settings (bridge, no IGMP snooping); multi-rate 10GBASE-T copper modules and one 1 Gbit copper module |
| Mac | MacBook Pro 16″ (Mac16,7), Apple M4 Pro, 24 GB memory | macOS 26.2 (25C56) |
| Network adapter on the Mac | USB 10/100/1G/2.5G LAN (Realtek) | 2.5 Gbit/s negotiated; IP 192.168.88.2/16 |
| SDI source | on input SDI 1 of the 3x3G | 1080p25 and 1080p60, YCbCr 4:2:2, 10 bit |
| Software | 2110 Viewer 1.2.6/1.2.7 | Converters Setup to check the device values |

Before that, the 3x3G was also connected directly (without a switch) to the 2.5G adapter.

## Results

| Check | Result |
|---|---|
| Discovery via NMOS IS-04 (mDNS, no registry) | ✔ all three senders and receivers of the 3x3G appear |
| Loading the SDP via NMOS | ✔ |
| PTP: Mac as passive follower | ✔ synchronized to the 3x3G (grandmaster 7C-2E-0D-FF-FE-20-96-EA, domain 123) |
| Turning on the device's sender via IS-05 | ✔ “Active: yes”, then the 3x3G sends |
| Receiving from the 3x3G (1080p25) | ✔ video arrives; losses while part of the path ran at only 1 Gbit/s |
| Sending from the app to the 3x3G | ✔ 1080p25 test pattern at the 3x3G output (receiver chosen in Converters Setup) |
| IS-05 “Connect” of a receiver on the 3x3G | ✔ technically; the device refuses 720p25 (“SDP format refused”) |

## Findings

1. **Senders off out of the box:** the 3x3G's senders reported `master_enable: false` in NMOS and the display showed “N/C”. Packets only arrived after turning them on via IS-05. Since 1.2.8 the app offers “Turn On…” right below the picture.
2. **Bandwidth:** a 1 Gbit SFP module in the switch limited the path to 1 Gbit/s. 1080p25 needs about 1.1 Gbit/s, 1080p60 about 2.6 Gbit/s. According to the data sheet the 3x3G's port supports 10M/100M/1G/10G. Since 1.2.8 the app warns when a stream does not fit through the connection.
3. **Formats:** the 3x3G only accepts standard SDI formats; 720p25 is not one of them.
4. **PTP domain:** the 3x3G ran on domain 123 instead of 127. Since 1.2.4 the app detects the domain automatically.

## App bugs found and fixed during the test

| Version | Bug | Fix |
|---|---|---|
| 1.2.4 | PTP helper aborted without root rights (“Failed to set process priority”), so no PTP | own build of the helper that keeps running at normal priority |
| 1.2.4 | domain 123 not selectable; SDP with `localmac=00-00-…` | domain free or automatic; real MAC address |
| 1.2.5 | SDP said “traceable” instead of the grandmaster ID | ID read directly from the PTP clock |
| 1.2.6 | crash when sending and receiving at the same time | PTP shared by sender and receiver |
| 1.2.7 | “Activate sender” only turned on video | video and audio |

## Still open

* Check receiving 1080p50/60 and lip sync with 10 Gbit/s throughout or 2.5 Gbit/s to the Mac.
* Further items from the [test plan](test-plan.md).
