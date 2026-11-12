#!/usr/bin/env bash
# Run the production shell root (ui/shell/qml/main.qml) as wlr-layer-shell
# surfaces. Uses qml6, or the Rust host when LUGH_SHELL_BIN points at it.
#
#   scripts/shell-run.sh                 # on Hyprland (refuses elsewhere)
#   scripts/shell-run.sh --nested [s]    # in a headless nested KWin: start,
#                                        #   settle 3 s, watch it idle for s
#                                        #   seconds (default 10), then report
#                                        #   first frame, RSS, idle frames, CPU
#   scripts/shell-run.sh --nested-exec [WxH] -- <command…>
#                                        # run any command inside a headless
#                                        #   nested KWin (used by shell-shots.sh
#                                        #   and shell-motion.sh)
#   scripts/shell-run.sh --force         # on any wlr-layer-shell compositor
#   … -- --dark --accent teal            # args after -- go to main.qml
#
# It refuses to start outside Hyprland without --force/--nested: on another
# desktop (KDE, GNOME) it would put a second panel on the live session.
#
# Config: --nested runs the shell with a throwaway XDG_CONFIG_HOME (defaults,
# removed on exit) and passes --dev-config, so the dev flags --dark,
# --accent, --reduce-motion land in ShellSettings for that run only. On
# Hyprland/--force the real config is used, unless one of those flags is
# given: then a throwaway copy of ~/.config/lugh/lugh-shell.conf (changes
# made in Customize during that run are dropped). kdeglobals, fontconfig and
# GTK settings are copied in. LUGH_DEV_CONFIG=keep always uses the real
# config (the flags then only reach Theme).
#
# Environment:
#   LUGH_NESTED_GPU=mesa|default   nested KWin + clients on Mesa (the Intel/AMD
#                                  iGPU; default when Mesa's EGL vendor file is
#                                  there) or on whatever the host prefers
#                                  (NVIDIA here: +25–100 MB per GL process).
#   LUGH_NESTED_OUTPUTS=n          number of virtual outputs (default 1).
#   LUGH_SHELL_BIN=<lugh-shell>    run the Rust host instead of qml6
#                                  (LUGH_SHELL_ARGS: extra host args, e.g. --mock).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"

mode=hyprland; nested_secs=10; nested_size=1440x900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nested) mode=nested; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && { nested_secs="$1"; shift; } ;;
    --nested-exec) mode=nested-exec; shift; [[ "${1:-}" =~ ^[0-9]+x[0-9]+$ ]] && { nested_size="$1"; shift; } ;;
    --force) mode=force; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# ---- headless nested KWin ----------------------------------------------------
# Starts kwin_wayland --virtual (no window on the desktop), points the
# environment at it. The caller's EXIT trap must call stop_nested.
kwin_pid="" nested_bus_pid=""
start_nested() {
  local size="$1"
  command -v kwin_wayland >/dev/null || { echo "shell-run: nested mode needs kwin_wayland" >&2; exit 2; }
  local mesa=/usr/share/glvnd/egl_vendor.d/50_mesa.json
  if [[ "${LUGH_NESTED_GPU:-mesa}" == mesa && -f "$mesa" ]]; then
    # glvnd would otherwise pick the NVIDIA EGL on hybrid laptops.
    export __EGL_VENDOR_LIBRARY_FILENAMES="$mesa"
  fi
  # Private session bus for the nested KWin. On the desktop's bus it registers
  # its shortcuts under the host KWin's "kwin" kglobalaccel component and, on
  # exit, deactivates them all (Meta+Tab, Meta+W, ... stop working on the host).
  local bus
  bus="$(dbus-daemon --session --fork --nopidfile --print-address=1 --print-pid=1)" \
    || { echo "shell-run: could not start a private D-Bus for nested KWin" >&2; exit 2; }
  nested_bus_pid="$(sed -n 2p <<<"$bus")"
  local sock="lugh-nested-$$"
  DBUS_SESSION_BUS_ADDRESS="$(sed -n 1p <<<"$bus")" \
    kwin_wayland --virtual --no-lockscreen --socket "$sock" \
    --width "${size%x*}" --height "${size#*x}" --output-count "${LUGH_NESTED_OUTPUTS:-1}" \
    >/dev/null 2>&1 &
  kwin_pid=$!
  for _ in $(seq 50); do [[ -S "${XDG_RUNTIME_DIR:?}/$sock" ]] && break; sleep 0.1; done
  [[ -S "$XDG_RUNTIME_DIR/$sock" ]] || { echo "shell-run: nested KWin did not start" >&2; exit 2; }
  export WAYLAND_DISPLAY="$sock" QT_QPA_PLATFORM=wayland QT_WAYLAND_DISABLE_WINDOWDECORATION=1
  export LUGH_NESTED=1
}
stop_nested() {
  [[ -n "$kwin_pid" ]] && kill "$kwin_pid" 2>/dev/null
  [[ -n "$nested_bus_pid" ]] && kill "$nested_bus_pid" 2>/dev/null
  true
}

if [[ $mode == nested-exec ]]; then
  [[ $# -gt 0 ]] || { echo "shell-run: --nested-exec needs a command" >&2; exit 2; }
  trap stop_nested EXIT
  start_nested "$nested_size"
  rc=0; "$@" || rc=$?
  exit "$rc"
fi

qml_args=("$@")
[[ -d /usr/share/backgrounds/lugh ]] || qml_args+=(--wallpaper-dir "file://$root/branding/wallpapers/")

# ---- throwaway config (see the header) ------------------------------------------
dev_cfg=""
use_dev_config() {
  local seed="$1" real_cfg="${XDG_CONFIG_HOME:-$HOME/.config}" f
  [[ "${LUGH_DEV_CONFIG:-}" == keep ]] && return 0
  dev_cfg="$(mktemp -d "${TMPDIR:-/tmp}/lugh-shell-config.XXXXXX")"
  for f in kdeglobals fontconfig gtk-3.0 gtk-4.0 qt6ct; do
    [[ -e "$real_cfg/$f" ]] && cp -r "$real_cfg/$f" "$dev_cfg/" 2>/dev/null || true
  done
  if ((seed)) && [[ -f "$real_cfg/lugh/lugh-shell.conf" ]]; then
    mkdir -p "$dev_cfg/lugh" && cp "$real_cfg/lugh/lugh-shell.conf" "$dev_cfg/lugh/"
  fi
  export XDG_CONFIG_HOME="$dev_cfg"
  qml_args+=(--dev-config)
}
appearance_flags=0
for a in "${qml_args[@]}"; do
  case "$a" in --dark|--accent|--reduce-motion) appearance_flags=1 ;; esac
done

# ---- environment (the lugh-shell unit sets the same; docs/dev/shell-performance.md)
export QT_QPA_PLATFORM=wayland
# Layer surfaces never get decorations; skip loading the decoration plugin.
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
# OpenGL RHI: smaller per-window footprint than Vulkan on Mesa, and what
# trixie's Qt 6.8 defaults to anyway. Pin it so drivers can't flip it.
export QSG_RHI_BACKEND="${QSG_RHI_BACKEND:-opengl}"
# Threaded render loop (Qt's default on Mesa): each mapped window renders and
# animates on its own thread, so a busy GUI thread never drops panel/launcher
# frames. QSG_RENDER_LOOP=basic trades that for fewer threads/contexts.
export QSG_RENDER_LOOP="${QSG_RENDER_LOOP:-threaded}"
# glibc creates up to 8×cores malloc arenas, one per render thread: cap them.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
# Compiled QML cache (default on; keep it explicit for the systemd unit).
export QML_DISK_CACHE_PATH="${QML_DISK_CACHE_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/lugh-shell/qmlcache}"
export QT_FORCE_STDERR_LOGGING=1
export QML_IMPORT_PATH="$root/ui/components:$root/ui/shell/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"

build_cmd() {
  if [[ -n "${LUGH_SHELL_BIN:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=(${LUGH_SHELL_ARGS:-})
    cmd=("$LUGH_SHELL_BIN" --qml-dir "$root/ui/shell/qml" --qml-dir "$root/ui/components" "${extra[@]}" -- "$@")
  else
    cmd=("$qml" -I "$root/ui/components" -I "$root/ui/shell/qml" "$root/ui/shell/qml/main.qml" -- "$@")
  fi
}

# run_live: the shell on the live compositor (no exec while a throwaway
# config has to be removed afterwards).
run_live() {
  ((appearance_flags)) && use_dev_config 1
  build_cmd "${qml_args[@]}"
  [[ -z "$dev_cfg" ]] && exec "${cmd[@]}"
  trap 'rm -rf "$dev_cfg"' EXIT
  rc=0; "${cmd[@]}" || rc=$?
  exit "$rc"
}

case "$mode" in
  hyprland)
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
      echo "shell-run: not in a Hyprland session; use --nested (headless test) or --force." >&2
      exit 2
    fi
    run_live ;;
  force)
    run_live ;;
  nested)
    trap 'kill "${shell_pid:-}" 2>/dev/null || true; stop_nested; [[ -n "$dev_cfg" ]] && rm -rf "$dev_cfg"; true' EXIT
    start_nested "$nested_size"
    # After start_nested: the nested KWin keeps the real config.
    use_dev_config 0
    export QT_MESSAGE_PATTERN='%{type}: %{message}'
    build_cmd "${qml_args[@]}" --idle-report "$nested_secs"
    log="$(mktemp)"
    # utime+stime of a pid, in clock ticks.
    ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
    # wait_log <pattern> <timeout s>: until the log has the line or the shell died.
    wait_log() {
      local n=$(($2 * 10))
      while ((n-- > 0)); do
        grep -q "$1" "$log" && return 0
        kill -0 "$shell_pid" 2>/dev/null || return 1
        sleep 0.1
      done
      return 1
    }
    start_ms=$(date +%s%3N)
    "${cmd[@]}" >"$log" 2>&1 &
    shell_pid=$!
    ok=1
    wait_log 'idle-start' 20 || ok=0
    t1=$(ticks "$shell_pid")
    if ((ok)); then wait_log 'idle-frames' $((nested_secs + 10)) || ok=0; fi
    t2=$(ticks "$shell_pid")
    rss=$(awk '/^VmRSS/ {print $2}' "/proc/$shell_pid/status" 2>/dev/null || echo 0)
    peak=$(awk '/^VmHWM/ {print $2}' "/proc/$shell_pid/status" 2>/dev/null || echo 0)
    threads=$(awk '/^Threads/ {print $2}' "/proc/$shell_pid/status" 2>/dev/null || echo 0)
    split=$(awk '/^RssAnon/ {a=$2} /^RssFile/ {f=$2} /^RssShmem/ {s=$2} END {printf "anon %d + file %d + shmem %d", a/1024, f/1024, s/1024}' "/proc/$shell_pid/status" 2>/dev/null || true)
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
    grep -vE 'first-frame-epoch-ms|idle-start' "$log" || true
    if ((!ok)); then echo "shell-run: the shell exited or never reached idle" >&2; exit 1; fi
    frame_ms=$(sed -n 's/.*first-frame-epoch-ms \([0-9]*\).*/\1/p' "$log" | head -1)
    hz=$(getconf CLK_TCK)
    echo "shell-run: first frame $((frame_ms - start_ms)) ms after exec"
    echo "shell-run: RSS $((rss / 1024)) MB at idle (peak $((peak / 1024)) MB; $split), $threads threads"
    echo "shell-run: idle CPU $(((t2 - t1) * 1000 / hz)) ms over ${nested_secs}s"
    if grep -qE '^(warning|critical|fatal): ' "$log"; then
      echo "shell-run: QML warnings above" >&2; exit 1
    fi
    echo "shell-run: ran in a nested KWin without QML warnings" ;;
esac
