#!/usr/bin/env bash
# Run the production shell root (ui/shell/qml/main.qml) as wlr-layer-shell
# surfaces, with qml6, until the Rust binary exists.
#
#   scripts/shell-run.sh                 # on Hyprland (refuses elsewhere)
#   scripts/shell-run.sh --nested [s]    # in a headless nested KWin for s
#                                        #   seconds (default 5), then report
#   scripts/shell-run.sh --force         # on any wlr-layer-shell compositor
#   … -- --dark --accent teal            # args after -- go to main.qml
#
# It refuses to start outside Hyprland without --force/--nested: on another
# desktop (KDE, GNOME) it would put a second bar and dock on the live session.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"

mode=hyprland; nested_secs=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nested) mode=nested; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && { nested_secs="$1"; shift; } ;;
    --force) mode=force; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
qml_args=("$@")
[[ -d /usr/share/backgrounds/lugh ]] || qml_args+=(--wallpaper-dir "file://$root/branding/wallpapers/")

# ---- environment (also the recommendation for the lugh-shell unit) ---------
export QT_QPA_PLATFORM=wayland
# Layer surfaces never get decorations; skip loading the decoration plugin.
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
# OpenGL RHI: smaller per-window footprint than Vulkan on Mesa, and what
# trixie's Qt 6.8 defaults to anyway. Pin it so drivers can't flip it.
export QSG_RHI_BACKEND="${QSG_RHI_BACKEND:-opengl}"
# Threaded render loop (Qt's default on Mesa): each mapped window renders and
# animates on its own thread, so a busy GUI thread never drops dock/launcher
# frames. Use QSG_RENDER_LOOP=basic to trade that for fewer threads/contexts
# (see ui/shell/README.md for the measured difference).
export QSG_RENDER_LOOP="${QSG_RENDER_LOOP:-threaded}"
# glibc creates up to 8×cores malloc arenas, one per render thread: cap them.
# This is the single biggest RSS win for a multi-window Qt Quick process.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
# Compiled QML cache (default on; keep it explicit for the systemd unit).
export QML_DISK_CACHE_PATH="${QML_DISK_CACHE_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/lugh-shell/qmlcache}"
export QT_FORCE_STDERR_LOGGING=1
[[ $mode == nested ]] && export QT_MESSAGE_PATTERN='%{type}: %{message}'
export QML_IMPORT_PATH="$root/ui/components:$root/ui/shell/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
cmd=("$qml" -I "$root/ui/components" -I "$root/ui/shell/qml" "$root/ui/shell/qml/main.qml" -- "${qml_args[@]}")

case "$mode" in
  hyprland)
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
      echo "shell-run: not in a Hyprland session; use --nested (headless test) or --force." >&2
      exit 2
    fi
    exec "${cmd[@]}" ;;
  force)
    exec "${cmd[@]}" ;;
  nested)
    command -v kwin_wayland >/dev/null || { echo "shell-run: --nested needs kwin_wayland" >&2; exit 2; }
    sock="lugh-shell-nested-$$"
    kwin_wayland --virtual --no-lockscreen --socket "$sock" --width 1440 --height 900 \
      >/dev/null 2>&1 &
    kwin=$!
    trap 'kill "$kwin" 2>/dev/null || true' EXIT
    for _ in $(seq 50); do [[ -S "${XDG_RUNTIME_DIR:?}/$sock" ]] && break; sleep 0.1; done
    log="$(mktemp)"
    rc=0
    WAYLAND_DISPLAY="$sock" /usr/bin/time -f 'shell-run: max RSS %M KB' \
      timeout "$nested_secs" "${cmd[@]}" >"$log" 2>&1 || rc=$?
    cat "$log"
    # 124 = stopped by timeout, i.e. it ran the whole time.
    if [[ $rc -ne 0 && $rc -ne 124 ]]; then echo "shell-run: exited with $rc" >&2; exit "$rc"; fi
    if grep -qE '^(warning|critical|fatal): ' "$log"; then
      echo "shell-run: QML warnings above" >&2; exit 1
    fi
    echo "shell-run: ran ${nested_secs}s in a nested KWin without QML warnings" ;;
esac
