#!/usr/bin/env bash
# Synthetische Tests: Essenz-Sender (st2110-send) -> Essenz-Empfänger (st2110-probe)
set -u
cd "$(dirname "$0")/.."
B=./build
OUT=${OUT:-$(mktemp -d)}
pass=0; fail=0
j() { python3 -I -c "import json,sys; d=json.loads([l for l in open(sys.argv[1]) if l.startswith('{')][-1]); print(eval(sys.argv[2], {}, d))" "$1" "$2"; }
ok() { if [ "$(j "$2" "$3")" = True ]; then echo "  OK    $1"; pass=$((pass+1)); else echo "  FEHLER $1 ($3)"; tail -2 "$2"; fail=$((fail+1)); fi; }
run() { # Name, Senderoptionen, Prüfungen …
  local name=$1 opts=$2; shift 2
  echo "== $name"
  $B/st2110-send $opts --iface-addr 127.0.0.1 --sdp-dir "$OUT" --duration 14 > "$OUT/s.log" 2>&1 &
  local sp=$!
  sleep 2
  $B/st2110-probe --sdp "$OUT/send-video.sdp" --audio-sdp "$OUT/send-audio.sdp" --iface-addr 127.0.0.1 --mode rtp --duration 9 --json > "$OUT/p.txt" 2>&1
  kill $sp 2>/dev/null; wait $sp 2>/dev/null
  while [ $# -gt 0 ]; do ok "$1" "$OUT/p.txt" "$2"; shift 2; done
}
W=${TEST_WIDTH:-1280}; H=${TEST_HEIGHT:-720}
run "${W}x${H}p25, 8 Kanäle 1 ms, Testbild" "--size ${W}x${H} --fps 25 --channels 8" \
  "Bilder empfangen" "v_rendered >= 0.9*25*8" "Format erkannt" "v_width==$W and v_height==$H and abs(v_fps-25)<0.1" \
  "keine Verluste" "v_lost==0 and a_lost==0" "Audio 1 ms" "abs(a_ptime_ms-1)<0.01"
run "${W}x${H}p50, 16 Kanäle 125 µs, Lippensynchron-Testsignal" "--size ${W}x${H} --fps 50 --channels 16 --ptime-us 125 --sync-pattern" \
  "50 B/s" "abs(v_fps-50)<0.2" "Audio 125 µs" "abs(a_ptime_ms-0.125)<0.001" "lippensynchron < 1 ms" "sync_n>=5 and abs(sync_avg_ms)<1"
run "29,97 B/s" "--size ${W}x${H} --fps 30000/1001 --channels 2" "Bildrate 29,97" "abs(v_fps-29.97)<0.05"
echo "Ergebnis: $pass bestanden, $fail fehlgeschlagen"
[ $fail -eq 0 ]
