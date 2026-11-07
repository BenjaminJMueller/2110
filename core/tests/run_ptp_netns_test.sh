#!/usr/bin/env bash
# PTP-Test unter Linux (root, iproute2, linuxptp): Software-Grandmaster (ptp4l)
# und synthetischer Sender in Namespace „gm“, Empfänger in Namespace „rx“,
# verbunden über ein virtuelles Ethernet. Ergebnis: „synthetisch getestet“.
#
# Hinweis: ptp4l mit Software-Zeitstempeln sendet die Systemzeit (UTC) als
# PTP-Zeit. Echte ST-2059-Grandmaster senden TAI. Der Sender wird deshalb einmal
# mit passender Zeitskala (Lock erwartet) und einmal mit TAI (+37 s, Rückfall
# erwartet) betrieben.
set -u
cd "$(dirname "$0")/.."
B=$PWD/build
OUT=${OUT:-$(mktemp -d)}
pass=0; fail=0
cleanup() { pkill -f "ptp4l -i vgm" 2>/dev/null; pkill -f st2110-testsender 2>/dev/null; ip netns del gm 2>/dev/null; ip netns del rx 2>/dev/null; }
trap cleanup EXIT
cleanup
ip netns add gm && ip netns add rx
ip link add vgm type veth peer name vrx
ip link set vgm netns gm; ip link set vrx netns rx
ip -n gm addr add 10.77.0.1/24 dev vgm; ip -n rx addr add 10.77.0.2/24 dev vrx
for n in gm rx; do ip -n $n link set lo up; done
ip -n gm link set vgm up; ip -n rx link set vrx up
ip -n gm route add 224.0.0.0/4 dev vgm; ip -n rx route add 224.0.0.0/4 dev vrx
cat > "$OUT/ptp4l.cfg" <<'CFG'
[global]
domainNumber 127
priority1 10
logAnnounceInterval 0
logSyncInterval -3
time_stamping software
clockClass 6
CFG
ip netns exec gm ptp4l -i vgm -f "$OUT/ptp4l.cfg" -m > "$OUT/ptp4l.log" 2>&1 &
sleep 5
j() { python3 -I -c "import json,sys; d=json.loads([l for l in open(sys.argv[1]) if l.startswith('{')][-1]); print(eval(sys.argv[2], {}, d))" "$1" "$2"; }
ok() { if [ "$(j "$2" "$3")" = True ]; then echo "  OK    $1"; pass=$((pass+1)); else echo "  FEHLER $1 ($3)"; fail=$((fail+1)); fi; }

echo "== PTP-Lock, Sender auf Grandmaster-Zeitskala"
ip netns exec gm $B/st2110-testsender --sdp-dir "$OUT" --tai-offset-s 0 --fps 25 --channels 8 --width 1280 --height 720 --duration 25 > "$OUT/s1.log" 2>&1 &
SP=$!
sleep 1
if command -v tcpdump >/dev/null; then
  ip netns exec rx timeout 12 tcpdump -i vrx -s 1600 -w "$OUT/ptp.pcap" "igmp or udp port 319 or udp port 320" > /dev/null 2>&1 &
fi
ip netns exec rx $B/st2110-probe --sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --iface vrx --iface-addr 10.77.0.2 --mode ptp --duration 20 --json > "$OUT/p1.txt" 2>&1
wait $SP
if [ -f "$OUT/ptp.pcap" ]; then
  $B/st2110-analyze "$OUT/ptp.pcap" > "$OUT/ptp.json" 2>/dev/null
  if python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); p=[x for x in d['ptp'] if x['domain']==127]; g=d['igmp']['groups']; sys.exit(0 if p and p[0]['grandmaster'] and p[0]['sync']>10 and any(x['joins']>0 for x in g) else 1)" "$OUT/ptp.json"; then
    echo "  OK    Analyse: PTP-Domain 127 mit Grandmaster und IGMP-Joins erkannt"; pass=$((pass+1))
  else
    echo "  FEHLER Analyse PTP/IGMP"; fail=$((fail+1))
  fi
fi
ok "PTP gelockt und aktiv" "$OUT/p1.txt" "ptp_synced==1 and sync_active==2"
ok "Lippensynchron |A/V| < 2 ms" "$OUT/p1.txt" "sync_n>=10 and abs(sync_avg_ms)<2"
ok "Bilder >= 90 %" "$OUT/p1.txt" "v_rendered >= 0.9*25*19"

echo "== Sender nicht auf Grandmaster (TAI vs. UTC): Rückfall auf RTP-Abstimmung"
ip netns exec gm $B/st2110-testsender --sdp-dir "$OUT" --fps 25 --channels 8 --width 1280 --height 720 --duration 16 > "$OUT/s2.log" 2>&1 &
SP=$!
sleep 1
ip netns exec rx $B/st2110-probe --sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --iface vrx --iface-addr 10.77.0.2 --mode ptp --duration 12 --json > "$OUT/p2.txt" 2>&1
wait $SP
if grep -q "neben der PTP-Zeit" "$OUT/p2.txt"; then echo "  OK    Rückfall gemeldet"; pass=$((pass+1)); else echo "  FEHLER Rückfall nicht gemeldet"; fail=$((fail+1)); fi
ok "Wiedergabe läuft lippensynchron weiter" "$OUT/p2.txt" "sync_active==1 and abs(sync_avg_ms)<2 and v_rendered>200"

echo "Ergebnis: $pass bestanden, $fail fehlgeschlagen (Protokolle: $OUT)"
[ $fail -eq 0 ]
