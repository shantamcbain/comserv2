#!/usr/bin/env bash
# Reinstall Linux audio drivers and reconfigure both workstation microphones:
#   • Card 0 — ALC1150 front-panel analog jack
#   • Card 1 — USB PnP Audio Device (Vankyo USB headset)
#
# Usage: sudo ./script/mic_reinstall_drivers.sh
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must run as root (kernel module reload + package reinstall)."
    echo "Run: sudo $0"
    exit 1
fi

if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
elif [[ -n "${PKEXEC_UID:-}" ]]; then
    REAL_USER="$(id -nu "$PKEXEC_UID")"
else
    REAL_USER="$(logname 2>/dev/null || true)"
fi
REAL_USER="${REAL_USER:-shanta}"
REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_RUNTIME="/run/user/$REAL_UID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Reinstalling ALSA / PipeWire packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get install --reinstall -y \
    alsa-base alsa-utils alsa-ucm-conf alsa-topology-conf \
    pipewire pipewire-pulse pipewire-bin \
    libpipewire-0.3-0t64 libpipewire-0.3-modules libpipewire-0.3-common \
    wireplumber \
    linux-modules-extra-"$(uname -r)" 2>/dev/null \
    || apt-get install --reinstall -y \
        alsa-base alsa-utils alsa-ucm-conf alsa-topology-conf \
        pipewire pipewire-pulse pipewire-bin \
        libpipewire-0.3-0t64 libpipewire-0.3-modules libpipewire-0.3-common \
        wireplumber

echo ""
echo "=== Reloading kernel audio modules ==="
# Stop user audio daemons first so modules can unload cleanly.
sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$REAL_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$REAL_RUNTIME/bus" \
    systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
sleep 1

# USB headset (Vankyo / JMTek USB PnP Audio Device)
modprobe -r snd_usb_audio 2>/dev/null || true
sleep 1
modprobe snd_usb_audio

# Motherboard HDA codec (ALC1150 front/rear mic jacks)
modprobe -r snd_hda_codec_alc882 2>/dev/null || true
modprobe -r snd_hda_intel 2>/dev/null || true
sleep 1
modprobe snd_hda_intel
modprobe snd_hda_codec_alc882

echo ""
echo "=== Resetting USB audio device (Vankyo) ==="
USB_DEV=""
for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    vendor=$(cat "$dev/idVendor")
    product=$(cat "$dev/idProduct")
    if [[ "$vendor" == "0c76" && "$product" == "1701" ]]; then
        USB_DEV="$dev"
        break
    fi
done
if [[ -n "$USB_DEV" ]]; then
    echo "Unbinding USB PnP Audio Device at $USB_DEV"
    echo "$(basename "$USB_DEV")" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
    sleep 2
    echo "$(basename "$USB_DEV")" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
    sleep 2
else
    echo "USB PnP Audio Device (0c76:1701) not found — skip USB reset (unplug/replug headset)."
fi

echo ""
echo "=== Restarting PipeWire for $REAL_USER ==="
sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$REAL_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$REAL_RUNTIME/bus" \
    systemctl --user start pipewire pipewire-pulse wireplumber
sleep 2

echo ""
echo "=== Configuring microphones ==="
for mode in front usb; do
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$REAL_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$REAL_RUNTIME/bus" \
        bash "$PROJECT_DIR/script/mic_configure.sh" "$mode"
done

echo ""
echo "=== Detected capture devices ==="
sudo -u "$REAL_USER" arecord -l 2>/dev/null || arecord -l

echo ""
echo "Driver reinstall complete."
echo "Test each mic:"
echo "  ./script/mic_configure.sh front && ./script/mic_test.sh"
echo "  ./script/mic_configure.sh usb  && ./script/mic_test.sh"