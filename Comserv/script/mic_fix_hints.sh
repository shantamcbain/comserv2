#!/usr/bin/env bash
# Print step-by-step fixes when the mic level stays flat in Linux Settings.
set -euo pipefail

cat <<'EOF'
=== Fix Linux microphone (input meter flat / no sound) ===

0. Close Settings → Sound completely (it locks the mic and shows a flat bar).
   Then run:
     ./script/mic_apply_fix.sh front
     ./script/mic_apply_fix.sh usb

1. Settings → Sound → Input
   • Try EACH device in the dropdown:
     - "USB PnP Audio Device" (USB headset/dongle)
     - "Built-in Audio Analog Stereo" (rear/front panel jack)
   • Speak and watch the orange bar — pick the device that moves.

2. Volume must be up; input must NOT be muted (no crossed speaker icon).

3. Built-in motherboard mic (ALC1150) — often needs boost in ALSA:
     amixer -c 0 sset 'Front Mic Boost' 3
     amixer -c 0 sset 'Capture' 80%
   • Pink mic jack on the back I/O panel, not green line-out.

4. USB headset: unplug, wait 5s, replug. Then re-select it in Sound → Input.

5. Advanced mixer (install if missing: sudo apt install pavucontrol):
     pavucontrol
   • Input Devices tab → green checkmark = default
   • Recording tab shows which app holds the mic (close other browsers)

6. Test again:
     ./script/mic_test.sh

7. If still silent: hardware — try another USB mic or phone headset with mic.
EOF