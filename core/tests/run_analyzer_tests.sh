#!/usr/bin/env bash
# Analysator-Tests mit Mitschnitten aus dem eigenen Sender (Software-Mitschnitt
# des Empfängers sowie – falls verfügbar und mit Rechten – tcpdump).
set -u
cd "$(dirname "$0")/.."
B=./build
OUT=${OUT:-$(mktemp -d)}
pass=0; fail=0
q() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); S={s['kind']:s for s in d['streams']}; print(eval(sys.argv[2], {}, {'d':d,'S':S}))" "$1" "$2"; }
ok() { if [ "$(q "$2" "$3")" = True ]; then echo "  OK    $1"; pass=$((pass+1)); else echo "  FEHLER $1 ($3)"; fail=$((fail+1)); fi; }

echo "== Software-Mitschnitt des Empfängers (pcapng)"
$B/st2110-send --size 960x540 --fps 25 --channels 8 --iface-addr 127.0.0.1 --sdp-dir "$OUT" --duration 10 > /dev/null 2>&1 &
SP=$!
sleep 2
$B/st2110-probe --sdp "$OUT/send-video.sdp" --audio-sdp "$OUT/send-audio.sdp" --iface-addr 127.0.0.1 --duration 5 --record "$OUT/rec.pcapng" > /dev/null 2>&1
kill $SP 2>/dev/null; wait $SP 2>/dev/null
$B/st2110-analyze "$OUT/rec.pcapng" --thumb 0 "$OUT/thumb.ppm" > "$OUT/a1.json" 2>/dev/null
ok "pcapng gelesen, als Software-Mitschnitt erkannt" "$OUT/a1.json" "d['capture']['format']=='pcapng' and d['capture']['software_capture']"
ok "Video ohne SDP erkannt: 960x540p25, 10 Bit" "$OUT/a1.json" "S['video']['video']['width']==960 and S['video']['video']['height']==540 and abs(S['video']['video']['fps']-25)<0.01 and S['video']['video']['pgroup_bytes']==5"
ok "Audio erkannt: 8 Kanäle, 1 ms" "$OUT/a1.json" "S['audio']['audio']['channels']==8 and abs(S['audio']['audio']['ptime_ms']-1)<0.01"
ok "keine Verluste" "$OUT/a1.json" "S['video']['lost']==0 and S['audio']['lost']==0"
ok "Bildverteilung über die aktive Zeit (≈ 38 ms bei 25p)" "$OUT/a1.json" "30 < S['video']['video']['frame_duration_ms']['avg'] < 40"
ok "Vorschaubild vorhanden" "$OUT/a1.json" "S['video']['video']['thumbnail']"

if command -v tcpdump >/dev/null && [ "$(id -u)" = 0 ]; then
  echo "== tcpdump-Mitschnitt mit Paketverlust (netsim) und SDP"
  timeout 9 tcpdump -i any -s 1600 -w "$OUT/cap.pcap" -B 65536 udp > /dev/null 2>&1 &
  sleep 1
  $B/st2110-testsender --width 640 --height 360 --fps 25 --channels 2 --loss 0.002 --mtu 1200 --sdp-dir "$OUT" --duration 6 > /dev/null 2>&1
  sleep 3
  $B/st2110-analyze "$OUT/cap.pcap" --sdp "$OUT/video.sdp" --sdp "$OUT/audio.sdp" > "$OUT/a2.json" 2>/dev/null
  ok "Hinweis auf fehlenden PTP" "$OUT/a2.json" "any('PTP' in f['text'] for f in d['capture']['findings'])"
  ok "pcap gelesen, SDP zugeordnet" "$OUT/a2.json" "d['capture']['format']=='pcap' and S['video']['sdp_matched']"
  ok "Verluste erkannt" "$OUT/a2.json" "S['video']['lost'] > 0"
  ok "Burst-Sender als nicht Narrow bewertet" "$OUT/a2.json" "S['video']['video']['st2110_21_class'] != 'N'"
fi
echo "Ergebnis: $pass bestanden, $fail fehlgeschlagen"
[ $fail -eq 0 ]
