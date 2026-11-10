#!/usr/bin/env bash
# Lugh desktop preview: the whole Lugh-mode desktop (wallpaper, mock app
# windows, bar, dock, every overlay) in one normal window. Runs anywhere Qt 6
# runs; no Hyprland needed. See ui/shell/README.md.
#
#   scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
#       [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
#       [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast]
#       [--query <text>] [--screenshot <out.png>] [--measure]
#
# --screenshot renders, saves the PNG after ~1.2 s and exits (uses the
# offscreen platform unless QT_QPA_PLATFORM is set, so no window flashes).
# --measure prints the time from process start to the first frame, then exits.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  # Make the screenshot path absolute (the QML side sees no cwd context).
  if [[ "${args[i]}" == --screenshot && $((i + 1)) -lt ${#args[@]} ]]; then
    args[i + 1]="$(realpath -m "${args[i + 1]}")"
    mkdir -p "$(dirname "${args[i + 1]}")"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
  fi
done
# The offscreen platform has no icon theme (app icons would fall back to
# letter plates): borrow the desktop's platform theme for icon lookup.
if [[ "${QT_QPA_PLATFORM:-}" == offscreen && -z "${QT_QPA_PLATFORMTHEME:-}" ]]; then
  for t in kde:KDEPlasmaPlatformTheme6 gtk3:libqgtk3; do
    if compgen -G "/usr/lib/*/qt6/plugins/platformthemes/${t#*:}.so" >/dev/null; then
      export QT_QPA_PLATFORMTHEME="${t%%:*}"; break
    fi
  done
fi

# Without lugh-branding installed, point Wallpaper at the repo's art.
if [[ ! -d /usr/share/backgrounds/lugh ]]; then
  args+=(--wallpaper-dir "file://$root/branding/wallpapers/")
fi

export QT_FORCE_STDERR_LOGGING=1
export QML_IMPORT_PATH="$root/ui/components:$root/ui/shell/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
cmd=("$qml" -I "$root/ui/components" -I "$root/ui/shell/qml" "$root/ui/shell/qml/preview.qml" -- "${args[@]}")

if [[ " ${args[*]} " == *" --measure "* ]]; then
  start_ms=$(date +%s%3N)
  out="$("${cmd[@]}" 2>&1)" || true
  printf '%s\n' "$out" | grep -v 'first-frame-epoch-ms' || true
  frame_ms=$(printf '%s\n' "$out" | sed -n 's/.*first-frame-epoch-ms \([0-9]*\).*/\1/p' | head -1)
  [[ -n "$frame_ms" ]] || { echo "shell-preview: no frame was drawn" >&2; exit 1; }
  echo "shell-preview: first frame after $((frame_ms - start_ms)) ms"
  exit 0
fi

if [[ " ${args[*]} " == *" --screenshot "* ]]; then
  exec timeout 30 "${cmd[@]}"
fi
exec "${cmd[@]}"
