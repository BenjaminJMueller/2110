#!/usr/bin/env bash
# Synthetische Ende-zu-Ende-Tests: st2110-testsender -> Multicast (Loopback) -> st2110-probe.
# Ergebnis: „synthetisch getestet“ – ersetzt NICHT den Test mit Blackmagic-Hardware.
set -u
cd "$(dirname "$0")/.."
B=./build
OUT=${OUT:-$(mktemp -d)}
IFACE_ADDR=${IFACE_ADDR:-127.0.0.1}
LONG=${LONG_SECONDS:-0}
pass=0; fail=0
SENDER_PID=

json() { python3 -I -c "import json,sys; d=json.loads([l for l in open(sys.argv[1]) if l.startswith('{')][-1]); print(eval(sys.argv[2], {}, d))" "$1" "$2"; }
check() { # name, Python-Ausdruck über JSON-Feldern
  local name=$1 file=$2 expr=$3
  if [ "$(json "$file" "$expr" 2>/dev/null)" = "True" ]; then echo "  OK    $name"; pass=$((pass+1));
  else echo "  FEHLER $name  ($expr)"; tail -3 "$file" | sed 's/^/        /'; fail=$((fail+1)); fi
}
grep_check() {
  local name=$1 file=$2 pat=$3
  if grep -q -- "$pat" "$file"; then echo "  OK    $name"; pass=$((pass+1)); else echo "  FEHLER $name (erwartet: $pat)"; fail=$((fail+1)); fi
}
sender() { $B/st2110-testsender --sdp-dir "$OUT" "$@" > "$OUT/sender.log" 2>&1 & SENDER_PID=$!; sleep 1; }
stop_sender() { [ -n "$SENDER_PID" ] && kill "$SENDER_PID" 2>/dev/null; wait "$SENDER_PID" 2>/dev/null; SENDER_PID=; sleep 0.5; }
probe() { local f=$1; shift; timeout 600 $B/st2110-probe --iface-addr "$IFACE_ADDR" --json "$@" > "$f" 2>&1; }

echo "== 1 Unit-Tests"
if $B/test_unit tests/sdp; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo "== 2 1080p25, 10 Bit, 16 Kanäle 125 µs, RTP-abgestimmt"
sender --fps 25 --channels 16 --ptime 0.125 --duration 20
probe "$OUT/t2.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode rtp --duration 12
stop_sender
check "Bilder empfangen (>= 90 %)" "$OUT/t2.txt" "v_rendered >= 0.9*25*11"
check "Bildrate 25 erkannt" "$OUT/t2.txt" "abs(v_fps-25) < 0.1"
check "Bildgröße 1920x1080 erkannt" "$OUT/t2.txt" "v_width==1920 and v_height==1080"
check "Audio-Paketzeit 0,125 ms" "$OUT/t2.txt" "abs(a_ptime_ms-0.125) < 0.001"
# Bei hoher Paketverlustrate (überlasteter Testrechner) sind Blitzbilder
# unvollständig; dann ist die Messung nicht aussagekräftig.
if [ "$(json "$OUT/t2.txt" 'v_lost < 0.001*v_packets')" = "True" ]; then
  check "Lippensynchron |A/V| < 2 ms" "$OUT/t2.txt" "sync_n >= 5 and abs(sync_avg_ms) < 2"
else
  echo "  (übersprungen) Lippensynchron bei 1080p: Testrechner überlastet ($(json "$OUT/t2.txt" 'round(100*v_lost/(v_packets+v_lost),1)') % Verlust) – siehe Test 4/6"
fi

echo "== 3 Gleiche Quelle, einfache Vorschau (nur Messung, keine Synchronisation erwartet)"
sender --fps 25 --channels 16 --ptime 0.125 --duration 14
probe "$OUT/t3.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode preview --duration 10
stop_sender
check "Vorschau läuft" "$OUT/t3.txt" "v_rendered > 200 and a_rendered > 1000"
echo "        Vorschau-Versatz A/V: $(json "$OUT/t3.txt" 'round(sync_avg_ms,1)') ms (informativ)"

echo "== 4 Absichtlich versetzte Audio-Zeitstempel (+40 ms): Empfänger folgt den Zeitstempeln"
sender --fps 25 --channels 8 --ptime 1 --width 1280 --height 720 --audio-ts-offset-ms 40 --duration 14
probe "$OUT/t4.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode rtp --duration 10
stop_sender
check "Versatz +40 ms gemessen (±3)" "$OUT/t4.txt" "sync_n >= 4 and abs(sync_avg_ms-40) < 3"

echo "== 5 360p50, 2 Kanäle 1 ms, 0,1 % Paketverlust (klein, damit der synthetische Sender Echtzeit schafft)"
sender --fps 50 --channels 2 --ptime 1 --width 640 --height 360 --loss 0.001 --duration 14
probe "$OUT/t5.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode rtp --duration 10
stop_sender
check "Verluste gezählt" "$OUT/t5.txt" "v_lost > 0 and a_lost >= 0"
check "Wiedergabe läuft trotz Verlust" "$OUT/t5.txt" "v_rendered > 0.8*50*9"
check "Bildrate 50 erkannt" "$OUT/t5.txt" "abs(v_fps-50) < 0.2"

echo "== 6 Senderneustart (neue SSRC) und Unterbrechung"
sender --fps 25 --channels 2 --width 640 --height 360 --ssrc-video 1111 --ssrc-audio 2222 --duration 30
( probe "$OUT/t6.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode rtp --duration 16 ) &
PP=$!
sleep 5; stop_sender; sleep 3
sender --fps 25 --channels 2 --width 640 --height 360 --ssrc-video 3333 --ssrc-audio 4444 --duration 30
wait $PP; stop_sender
grep_check "Unterbrechung erkannt" "$OUT/t6.txt" "Signal unterbrochen"
grep_check "Neustart erkannt" "$OUT/t6.txt" "neu gestartet"
check "Empfang danach wieder aufgenommen" "$OUT/t6.txt" "state=='Empfang' and v_rendered > 25*10"
check "Lippensynchron nach Neustart" "$OUT/t6.txt" "abs(sync_last_ms) < 2"

echo "== 7 Formatwechsel beim Sender (SDP 640x360, gesendet 1280x720)"
sender --fps 25 --channels 2 --width 640 --height 360 --duration 2
cp "$OUT/video.sdp" "$OUT/video_small.sdp"; stop_sender
sender --fps 25 --channels 2 --width 1280 --height 720 --duration 12
probe "$OUT/t7.txt" --video-sdp "$OUT/video_small.sdp" --mode rtp --duration 6
stop_sender
grep_check "Formatwechsel gemeldet" "$OUT/t7.txt" "passt nicht zur SDP"

echo "== 8 Nicht unterstützte Formate werden abgewiesen"
$B/st2110-probe --video-sdp tests/sdp/video_1080i50.sdp --duration 1 > "$OUT/t8.txt" 2>&1
grep_check "1080i abgewiesen mit Abhilfe" "$OUT/t8.txt" "progressives Format"
$B/st2110-probe --video-sdp tests/sdp/video_rgb.sdp --duration 1 > "$OUT/t8b.txt" 2>&1
grep_check "RGB abgewiesen mit Abhilfe" "$OUT/t8b.txt" "YCbCr 4:2:2"

echo "== 9 Falsche Multicast-Gruppe: Zustand „Warte auf Signal“"
sed 's/239.10.10.1/239.10.99.99/' "$OUT/video_small.sdp" > "$OUT/wrong.sdp"
probe "$OUT/t9.txt" --video-sdp "$OUT/wrong.sdp" --duration 3
check "Kein Signal erkannt" "$OUT/t9.txt" "state=='Warte auf Signal' and v_packets==0"

if [ "$LONG" -gt 0 ]; then
  echo "== 10 Dauerbetrieb ${LONG} s (1080p25, 16 Kanäle)"
  sender --fps 25 --channels 16 --ptime 0.125 --duration $((LONG+10))
  probe "$OUT/t10.txt" --video-sdp "$OUT/video.sdp" --audio-sdp "$OUT/audio.sdp" --mode rtp --duration "$LONG"
  stop_sender
  check "Dauerbetrieb: Bilder >= 90 %" "$OUT/t10.txt" "v_rendered >= 0.9*25*($LONG-1)"
  check "Dauerbetrieb: lippensynchron" "$OUT/t10.txt" "abs(sync_avg_ms) < 2"
  echo "        Drift: $(json "$OUT/t10.txt" 'drift_ppm') ppm, Resyncs: $(json "$OUT/t10.txt" 'resyncs')"
fi

echo
echo "Ergebnis: $pass bestanden, $fail fehlgeschlagen (Protokolle: $OUT)"
[ $fail -eq 0 ]
