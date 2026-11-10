#!/bin/sh
# media-key.sh: hardware keys (volume, mic, brightness, media, caps lock).
# Changes the value, then asks lugh-shell to show its OSD:
#   space.lugh.Shell1.ShowOSD(s kind, d value)
#
# OSD kinds sent (the shell must handle these):
#   volume          value 0.0-1.5 (1.0 = 100 %)
#   volume-muted    value = the volume level while muted
#   microphone      1.0 = live, 0.0 = muted
#   brightness      0.0-1.0
#   kbd-brightness  0.0-1.0
#   caps-lock       1.0 = on, 0.0 = off
#
# Needs: wireplumber (wpctl), brightnessctl (uses logind, no root), playerctl
# (media keys only), systemd (busctl). A missing tool skips that key quietly.
set -u

STEP_VOLUME="5%"
STEP_BRIGHTNESS="5%"
MAX_VOLUME="1.5"    # allow up to 150 % like GNOME's "over-amplification"

osd() {
    busctl --user --expect-reply=no call \
        space.lugh.Shell1 /space/lugh/Shell1 space.lugh.Shell1 \
        ShowOSD sd "$1" "$2" >/dev/null 2>&1 || true
}

have() { command -v "$1" >/dev/null 2>&1; }

# "Volume: 0.45 [MUTED]" -> kind + level
volume_osd() {
    out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || return 0
    level=$(printf '%s\n' "$out" | awk '{print $2}')
    case "$out" in
        *MUTED*) osd volume-muted "$level" ;;
        *)       osd volume "$level" ;;
    esac
}

mic_osd() {
    out=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null) || return 0
    case "$out" in
        *MUTED*) osd microphone 0 ;;
        *)       osd microphone 1 ;;
    esac
}

# brightnessctl -m: "device,class,current,percent,max"
# brightness_osd <osd-kind> <brightnessctl selector option>
brightness_osd() {
    kind=$1
    out=$(brightnessctl -m "$2" 2>/dev/null | head -n 1) || return 0
    [ -n "$out" ] || return 0
    value=$(printf '%s\n' "$out" | awk -F, '{ if ($5 > 0) printf "%.3f", $3 / $5; else print 0 }')
    osd "$kind" "$value"
}

case "${1:-}" in
    volume-up)
        have wpctl || exit 0
        wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
        wpctl set-volume -l "$MAX_VOLUME" @DEFAULT_AUDIO_SINK@ "$STEP_VOLUME+"
        volume_osd
        ;;
    volume-down)
        have wpctl || exit 0
        wpctl set-volume @DEFAULT_AUDIO_SINK@ "$STEP_VOLUME-"
        volume_osd
        ;;
    volume-mute)
        have wpctl || exit 0
        wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
        volume_osd
        ;;
    mic-mute)
        have wpctl || exit 0
        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
        mic_osd
        ;;
    brightness-up)
        have brightnessctl || exit 0
        brightnessctl --quiet --class=backlight set "$STEP_BRIGHTNESS+"
        brightness_osd brightness --class=backlight
        ;;
    brightness-down)
        have brightnessctl || exit 0
        # never go fully dark: keep at least 1 %
        brightnessctl --quiet --class=backlight --min-value=1% set "$STEP_BRIGHTNESS-"
        brightness_osd brightness --class=backlight
        ;;
    kbd-brightness-up)
        have brightnessctl || exit 0
        brightnessctl --quiet --device='*::kbd_backlight' set 34%+
        brightness_osd kbd-brightness --device='*::kbd_backlight'
        ;;
    kbd-brightness-down)
        have brightnessctl || exit 0
        brightnessctl --quiet --device='*::kbd_backlight' set 34%-
        brightness_osd kbd-brightness --device='*::kbd_backlight'
        ;;
    play-pause|next|previous)
        have playerctl || exit 0
        playerctl "$1" >/dev/null 2>&1 || true
        ;;
    caps-lock)
        # Any keyboard reporting caps lock on counts (laptop + external keyboards
        # share the state in Hyprland).
        if hyprctl devices -j 2>/dev/null | grep -q '"capsLock": *true'; then
            osd caps-lock 1
        else
            osd caps-lock 0
        fi
        ;;
    *)
        echo "usage: media-key.sh volume-up|volume-down|volume-mute|mic-mute|brightness-up|brightness-down|kbd-brightness-up|kbd-brightness-down|play-pause|next|previous|caps-lock" >&2
        exit 2
        ;;
esac
