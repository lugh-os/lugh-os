#!/usr/bin/env bash
# Visual regression set: renders the desktop preview in light and dark, once
# per state, into out/shots/<theme>-<state>.png. No window appears:
#   - with kwin_wayland installed, inside a headless nested KWin (real GPU
#     scene graph: glass, shadows and shader effects render as on Hyprland);
#   - otherwise with QT_QPA_PLATFORM=offscreen, which is Qt's *software*
#     renderer: shader effects and rounded glass backdrops are missing.
#   SHOTS_PLATFORM=nested|offscreen forces one.
#   scripts/shell-shots.sh [out-dir=out/shots] [--width 1440 --height 900 …]
#   SHOTS_STATES="none lock" SHOTS_THEMES="dark" narrow the set.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/out/shots}"; [[ $# -gt 0 ]] && shift
out="$(realpath -m "$out")"
mkdir -p "$out"

platform="${SHOTS_PLATFORM:-$(command -v kwin_wayland >/dev/null && echo nested || echo offscreen)}"
if [[ "$platform" == nested && -z "${LUGH_NESTED:-}" ]]; then
  # Again, inside the headless KWin (shell-run.sh sets LUGH_NESTED).
  exec "$root/scripts/shell-run.sh" --nested-exec 3000x2000 -- "${BASH_SOURCE[0]}" "$out" "$@"
fi
if [[ "$platform" != nested ]]; then
  export QT_QPA_PLATFORM=offscreen
  echo "shell-shots: offscreen (software renderer): rounded glass and shader effects won't show" >&2
fi
echo "shell-shots: rendering on $platform into $out"
read -r -a states <<<"${SHOTS_STATES:-none launcher launcher-query controlcenter controlcenter-wifi controlcenter-sound notifications menu lock osd toast}"
read -r -a themes <<<"${SHOTS_THEMES:-light dark}"

# render <name> <preview args…>
render() {
  local name="$1"; shift
  local log
  if log="$("$root/scripts/shell-preview.sh" --screenshot "$out/$name" "$@" 2>&1)"; then
    echo "ok   $out/$name"
    # QML warnings are part of the result.
    printf '%s\n' "$log" | grep -E 'warning|critical|Error' | grep -v 'lugh-preview: wrote' | sed 's/^/     /' | head -5 || true
  else
    echo "FAIL $name"; printf '%s\n' "$log" | tail -5; return 1
  fi
}

# 4 renders at a time; each takes ~2 s.
pids=(); fail=0
for theme in "${themes[@]}"; do
  for state in "${states[@]}"; do
    case "$state" in
      launcher-query) a=(--state launcher --query "control panel") ;;
      controlcenter-*) a=(--state controlcenter --page "${state#controlcenter-}") ;;
      *) a=(--state "$state") ;;
    esac
    [[ "$theme" == dark ]] && a+=(--dark)
    render "$theme-$state.png" "${a[@]}" "$@" &
    pids+=($!)
    if ((${#pids[@]} >= 4)); then wait "${pids[0]}" || fail=1; pids=("${pids[@]:1}"); fi
  done
done
for p in "${pids[@]}"; do wait "$p" || fail=1; done
exit "$fail"
