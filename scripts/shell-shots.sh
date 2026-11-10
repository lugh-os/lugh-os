#!/usr/bin/env bash
# Visual regression set: renders the desktop preview in light and dark, once
# per state, into out/shots/<theme>-<state>.png. No window appears:
#   - with kwin_wayland installed, inside a headless nested KWin (real GPU
#     scene graph: glass, shadows and shader effects render as on Hyprland);
#   - otherwise with QT_QPA_PLATFORM=offscreen, which is Qt's *software*
#     renderer: shader effects and rounded glass backdrops are missing.
#   SHOTS_PLATFORM=nested|offscreen forces one.
#   scripts/shell-shots.sh [out-dir=out/shots] [--width 1440 --height 900]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/out/shots}"; [[ $# -gt 0 ]] && shift
mkdir -p "$out"

platform="${SHOTS_PLATFORM:-$(command -v kwin_wayland >/dev/null && echo nested || echo offscreen)}"
if [[ "$platform" == nested ]]; then
  sock="lugh-shots-$$"
  kwin_wayland --virtual --no-lockscreen --socket "$sock" --width 3000 --height 2000 >/dev/null 2>&1 &
  kwin=$!
  trap 'kill "$kwin" 2>/dev/null || true' EXIT
  for _ in $(seq 50); do [[ -S "${XDG_RUNTIME_DIR:?}/$sock" ]] && break; sleep 0.1; done
  export QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" QT_WAYLAND_DISABLE_WINDOWDECORATION=1
else
  export QT_QPA_PLATFORM=offscreen
  echo "shell-shots: offscreen (software renderer): rounded glass and shader effects won't show" >&2
fi
echo "shell-shots: rendering on $platform into $out"
states=(none launcher launcher-query controlcenter notifications menu lock osd toast)

# render <name> <preview args…>
render() {
  local name="$1"; shift
  local log
  if log="$("$root/scripts/shell-preview.sh" --screenshot "$out/$name" "$@" 2>&1)"; then
    echo "ok   $out/$name"
  else
    echo "FAIL $name"; printf '%s\n' "$log" | tail -5; return 1
  fi
}

# 4 renders at a time; each takes ~1.5 s.
pids=(); fail=0
for theme in light dark; do
  for state in "${states[@]}"; do
    a=(--state "$state")
    [[ "$state" == launcher-query ]] && a=(--state launcher --query "control panel")
    [[ "$theme" == dark ]] && a+=(--dark)
    render "$theme-$state.png" "${a[@]}" "$@" &
    pids+=($!)
    if ((${#pids[@]} >= 4)); then wait "${pids[0]}" || fail=1; pids=("${pids[@]:1}"); fi
  done
done
for p in "${pids[@]}"; do wait "$p" || fail=1; done
exit "$fail"
