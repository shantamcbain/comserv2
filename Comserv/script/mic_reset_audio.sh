#!/usr/bin/env bash
# Reset PipeWire so input devices appear in pavucontrol / GNOME Settings.
# Do NOT add wireplumber lua configs — they break this machine's audio driver.
set -euo pipefail

echo "Restarting audio..."
systemctl --user restart pipewire wireplumber pipewire-pulse
sleep 4

CARD_BUILTIN="alsa_card.pci-0000_00_1f.3"
CARD_USB="alsa_card.usb-Solid_State_System_Co._Ltd._USB_PnP_Audio_Device_000000000000-00"

# alsa:pcm fallback (only off/on profiles)
if pactl set-card-profile "$CARD_BUILTIN" on 2>/dev/null; then
    echo "Using alsa:pcm mode (profile: on)"
    pactl set-card-profile "$CARD_USB" on 2>/dev/null || true
else
    echo "Using standard ALSA profiles (duplex)"
    pactl set-card-profile "$CARD_BUILTIN" output:iec958-stereo+input:analog-stereo
    pactl set-card-profile "$CARD_USB" output:analog-stereo+input:mono-fallback
fi

echo ""
echo "Input devices:"
pactl list sources short | awk '$2 !~ /monitor/ {print "  " $2}'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/mic_configure.sh" front 2>/dev/null || true

echo ""
echo "Done. Open pavucontrol → Input Devices tab."