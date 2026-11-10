#!/bin/sh
# verify-config.sh: check the Lugh Hyprland config with `Hyprland --verify-config`.
#
# Usage: ui/shell/hypr/scripts/verify-config.sh [trixie-backports|sid]
#
# Uses a local Hyprland when one is installed and no suite is given; otherwise
# runs Debian's Hyprland in a throwaway container (podman, else docker):
#   trixie-backports  0.55.2, the version Lugh targets (default)
#   sid               0.57.x, the next one (Lua-only config)
# Prints Hyprland's "Config parsing result" and exits non-zero on any error.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
suite=${1:-}

if [ -z "$suite" ] && command -v Hyprland >/dev/null 2>&1; then
    out=$(Hyprland --verify-config --config "$here/lugh.lua" 2>&1 || true)
    printf '%s\n' "$out" | sed -n '/Config parsing result/,$p'
    printf '%s\n' "$out" | grep -q '^config ok$'
    exit $?
fi

suite=${suite:-trixie-backports}
case "$suite" in
    trixie-backports)
        image=debian:trixie
        sources="deb http://deb.debian.org/debian trixie-backports main"
        target="-t trixie-backports"
        ;;
    sid)
        image=debian:sid
        sources=""
        target=""
        ;;
    *)
        echo "usage: verify-config.sh [trixie-backports|sid]" >&2
        exit 2
        ;;
esac

if command -v podman >/dev/null 2>&1; then
    engine=podman
elif command -v docker >/dev/null 2>&1; then
    engine=docker
else
    echo "verify-config: needs Hyprland, podman or docker" >&2
    exit 1
fi

# Hyprland refuses to run as root and needs XDG_RUNTIME_DIR; /usr/bin/Hyprland
# carries cap_sys_nice, which containers refuse to exec, so a copy is used.
# shellcheck disable=SC2016 # expanded inside the container
"$engine" run --rm -v "$here:/lugh:ro" \
    -e SOURCES="$sources" -e TARGET="$target" "$image" sh -c '
    set -e
    [ -n "$SOURCES" ] && echo "$SOURCES" > /etc/apt/sources.list.d/extra.list
    apt-get update -qq
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $TARGET hyprland >/dev/null
    cp /usr/bin/Hyprland /usr/local/bin/hyprland-nocap
    useradd -m verifier
    su verifier -c "export XDG_RUNTIME_DIR=\$(mktemp -d); hyprland-nocap --version | head -n 1; hyprland-nocap --verify-config --config /lugh/lugh.lua 2>&1" \
        | sed -n "1p;/Config parsing result/,\$p" > /tmp/result
    cat /tmp/result
    grep -q "^config ok$" /tmp/result
'
