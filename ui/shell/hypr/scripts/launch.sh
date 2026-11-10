#!/bin/sh
# launch.sh: start an app from a compositor keybind in its own systemd user
# scope, named like the shell's launcher does (ADR-015):
#   app-lugh-<appid>-<random>.scope   in app.slice
#
# Usage: launch.sh <appid> <command> [args...]
#
# The shell launches apps itself (StartTransientUnit); this is only for the
# few apps bound to keys in Hyprland (terminal, files, settings, tasks).
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: launch.sh <appid> <command> [args...]" >&2
    exit 2
fi

# Unit names allow [A-Za-z0-9:_.\-]; anything else becomes "_".
appid=$(printf '%s' "$1" | tr -c 'A-Za-z0-9:_.-' '_')
shift

rand=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')

manager=$(systemctl --user is-system-running 2>/dev/null || true)
case "$manager" in
    running|degraded|starting)
        if command -v systemd-run >/dev/null 2>&1; then
            exec systemd-run --user --scope --quiet --collect \
                --slice=app.slice --unit="app-lugh-${appid}-${rand}" -- "$@"
        fi
        ;;
    *)
        ;;
esac

# No usable systemd user manager (e.g. nested dev setup): just run it.
exec "$@"
