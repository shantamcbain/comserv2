#!/usr/bin/env bash
# Apply ALSA / PipeWire settings for workstation microphones.
# Usage: ./script/mic_configure.sh [front|rear|line|usb]
set -euo pipefail

MODE="${1:-front}"

find_source() {
    local pattern="$1"
    pactl list sources short | awk -v pat="$pattern" '$2 ~ pat && $2 !~ /monitor/ {print $2; exit}'
}

ensure_analog_card() {
    # Prefer analog duplex; fall back to digital-out + analog-in.
    if ! pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:analog-stereo+input:analog-stereo 2>/dev/null; then
        pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:iec958-stereo+input:analog-stereo
    fi
}

ensure_usb_card() {
    if ! pactl set-card-profile alsa_card.usb-Solid_State_System_Co._Ltd._USB_PnP_Audio_Device_000000000000-00 output:analog-stereo+input:mono-fallback 2>/dev/null; then
        pactl set-card-profile alsa_card.usb-Solid_State_System_Co._Ltd._USB_PnP_Audio_Device_000000000000-00 output:iec958-stereo+input:mono-fallback
    fi
}

configure_analog_source() {
    local port="$1"
    ensure_analog_card
    sleep 0.5
    local source
    source="$(find_source 'pci-0000_00_1f.3.analog-stereo')"
    if [[ -z "$source" ]]; then
        echo "Built-in analog input not found in PipeWire."
        exit 1
    fi
    pactl set-default-source "$source"
    pactl set-source-port "$source" "$port" 2>/dev/null || true
    pactl set-source-mute "$source" 0
    pactl set-source-volume "$source" 100%
    wpctl set-default "$source" 2>/dev/null || true
}

case "$MODE" in
    front)
        amixer -c 0 sset 'Input Source' 'Front Mic'
        amixer -c 0 sset 'Front Mic Boost' 3
        amixer -c 0 sset 'Capture' 100%
        amixer -c 0 sset 'Capture' cap
        configure_analog_source 'analog-input-front-mic'
        echo "Configured built-in input: front panel mic"
        ;;
    rear)
        amixer -c 0 sset 'Input Source' 'Rear Mic'
        amixer -c 0 sset 'Rear Mic Boost' 3
        amixer -c 0 sset 'Capture' 100%
        amixer -c 0 sset 'Capture' cap
        configure_analog_source 'analog-input-rear-mic'
        echo "Configured built-in input: rear panel mic"
        ;;
    line)
        amixer -c 0 sset 'Input Source' 'Line'
        amixer -c 0 sset 'Line Boost' 3
        amixer -c 0 sset 'Capture' 100%
        amixer -c 0 sset 'Capture' cap
        configure_analog_source 'analog-input-linein'
        echo "Configured built-in input: line in"
        ;;
    usb)
        if ! arecord -l 2>/dev/null | grep -q 'card 1:.*USB PnP Audio Device'; then
            echo "USB headset not detected. Unplug, wait 5s, replug, then retry."
            exit 1
        fi
        ensure_usb_card
        sleep 0.5
        amixer -c 1 sset 'Mic' 100%
        amixer -c 1 sset 'Mic' cap
        amixer -c 1 sset 'Auto Gain Control' off
        source="$(find_source 'usb.*mono-fallback')"
        if [[ -z "$source" ]]; then
            echo "USB mic source not found in PipeWire."
            exit 1
        fi
        pactl set-default-source "$source"
        pactl set-source-mute "$source" 0
        pactl set-source-volume "$source" 100%
        wpctl set-default "$source" 2>/dev/null || true
        echo "Configured USB input: Vankyo USB PnP Audio Device"
        ;;
    *)
        echo "Usage: $0 [front|rear|line|usb]"
        exit 1
        ;;
esac

echo "Default source: $(pactl get-default-source)"
echo "Now run: ./script/mic_test.sh  (close Settings → Sound first)"