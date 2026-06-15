#!/usr/bin/env bash
# One-shot fix when GNOME Sound shows flat mic meters for both devices.
# Usage: ./script/mic_apply_fix.sh [front|usb]
set -euo pipefail

MODE="${1:-front}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Applying microphone fix ($MODE) ==="

# GNOME Settings peak-detect holds the mic and can show a flat bar.
pactl list short source-outputs 2>/dev/null | cut -f1 | while read -r id; do
    pactl kill-source-output "$id" 2>/dev/null || true
done

# Ensure microphone is not blocked at OS level.
gsettings set org.gnome.desktop.privacy disable-microphone false 2>/dev/null || true

bash "$SCRIPT_DIR/mic_configure.sh" "$MODE"

echo ""
echo "Input devices:"
pactl list sources short | awk '$2 !~ /monitor/ {print}'

echo ""
echo "Speak now for 3 seconds..."
OUT="/tmp/comserv_mic_fix_test.wav"
parec -d "$(pactl get-default-source)" --file-format=wav "$OUT" &
PID=$!
sleep 3
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

python3 <<'PY'
import math, struct, wave
path = "/tmp/comserv_mic_fix_test.wav"
with wave.open(path) as w:
    data = w.readframes(w.getnframes())
    samples = struct.unpack("<" + "h" * (len(data) // 2), data)
    peak = max(abs(s) for s in samples) if samples else 0
    rms = math.sqrt(sum(s * s for s in samples) / len(samples)) if samples else 0
print(f"Signal: peak={peak}  rms={rms:.1f}")
if peak < 500:
    print("RESULT: still silent at OS level.")
    print("Front jack: pink mic port on front panel, fully seated.")
    print("USB Vankyo: check boom mic / inline mute switch, then unplug 5s and replug.")
    print("Run: ./script/mic_fix_hints.sh")
else:
    print("RESULT: mic is working. Open Settings → Sound → Input and select the same device.")
PY