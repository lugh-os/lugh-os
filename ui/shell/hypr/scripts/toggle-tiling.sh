#!/bin/sh
# toggle-tiling.sh: turn tiling on/off for the focused workspace (Lugh mode).
#
# Super+T calls the Lua function directly; this wrapper is for the shell and
# the CLI (`lugh shell ...` later). The logic lives in lugh/tiling.lua, so the
# rules, the state file and the event stay in one place.
#
# Usage: toggle-tiling.sh [toggle|status]
#   toggle  (default) toggle the focused workspace
#   status  print the tiled workspace ids, one per line
#
# In Lua-config mode `hyprctl dispatch X` runs `hl.dispatch(X)`, and
# hl.dispatch accepts a Lua function, so this works on 0.55 and later.
set -eu

state_file="${XDG_RUNTIME_DIR:-/tmp}/lugh/hypr-tiled-workspaces"

case "${1:-toggle}" in
    toggle)
        if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
            echo "toggle-tiling: Hyprland is not running (HYPRLAND_INSTANCE_SIGNATURE unset)" >&2
            exit 1
        fi
        exec hyprctl dispatch 'lugh.tiling.toggle'
        ;;
    status)
        if [ -r "$state_file" ]; then
            cat "$state_file"
        fi
        ;;
    -h|--help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "usage: toggle-tiling.sh [toggle|status]" >&2
        exit 2
        ;;
esac
