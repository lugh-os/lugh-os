#!/bin/sh
# low-power.sh: switch Hyprland's low-power profile (conf.d/low-power.lua).
#
# Usage: low-power.sh on|off|toggle|status
#
# The shell calls this when power-profiles-daemon switches to/from
# "power-saver", on low battery, or when the GPU is known to be weak.
# The flag lives in $XDG_RUNTIME_DIR, so it lasts for this login only; the
# shell sets it again at start-up from the current power profile.
#
# Why a flag + reload and not `hyprctl keyword`: with the Lua config manager
# (Hyprland >= 0.55) the config is a program, not a list of keywords. lugh.lua
# reads the flag and applies low-power.lua last; `hyprctl reload config-only`
# re-runs it in a few ms without touching monitors. Turning it off is the same
# reload without the flag, which restores every default exactly.
set -eu

flag_dir="${XDG_RUNTIME_DIR:-/tmp}/lugh"
flag="$flag_dir/hypr-low-power"

reload() {
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        hyprctl reload config-only >/dev/null
    fi
}

case "${1:-status}" in
    on)
        mkdir -p "$flag_dir"
        : > "$flag"
        reload
        ;;
    off)
        rm -f "$flag"
        reload
        ;;
    toggle)
        if [ -e "$flag" ]; then "$0" off; else "$0" on; fi
        ;;
    status)
        if [ -e "$flag" ]; then echo on; else echo off; fi
        ;;
    *)
        echo "usage: low-power.sh on|off|toggle|status" >&2
        exit 2
        ;;
esac
