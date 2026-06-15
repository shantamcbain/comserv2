#!/usr/bin/env bash
# Quick microphone diagnostic for the workstation.
# Run: ./script/mic_test.sh
# Speak during the 5-second recording, then listen to the playback.

set -euo pipefail

OUT="/tmp/comserv_mic_test.wav"

echo "=== Microphone diagnostic ==="
echo ""
echo "Default input:"
pactl get-default-source 2>/dev/null || true
echo ""
echo "Input devices (look for SUSPENDED vs RUNNING):"
pactl list sources short
echo ""

SOURCE="$(pactl get-default-source)"
echo "Using source: $SOURCE"
echo "Recording 5 seconds — speak now..."
parec -d "$SOURCE" --file-format=wav "$OUT" &
REC_PID=$!
sleep 5
kill "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
echo "Saved: $OUT ($(wc -c < "$OUT") bytes)"

python3 <<'PY'
import wave, struct, math
with wave.open("/tmp/comserv_mic_test.wav") as w:
    data = w.readframes(w.getnframes())
    samples = struct.unpack("<" + "h" * (len(data) // 2), data)
    peak = max(abs(s) for s in samples) if samples else 0
    rms = math.sqrt(sum(s * s for s in samples) / len(samples)) if samples else 0
print(f"Signal: peak={peak}  rms={rms:.1f}")
if peak < 500:
    print("RESULT: SILENCE — mic not picking up audio at OS level.")
    print("Try the fixes in script/mic_fix_hints.sh")
else:
    print("RESULT: OK — mic is working in Linux.")
PY

echo ""
read -r -p "Play back recording? [y/N] " ans
if [[ "${ans,,}" == "y" ]]; then
    aplay "$OUT"
fi