#!/usr/bin/env bash
# Lugh desktop preview: the whole Lugh-mode desktop (wallpaper, mock app
# windows, islands, dock, every overlay) in one normal window. Runs anywhere
# Qt 6 runs; no Hyprland needed. See ui/shell/README.md.
#
#   scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
#       [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
#       [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast]
#       [--query <text>]                       with --state launcher
#       [--page wifi|bluetooth|sound|power]    with --state controlcenter
#       [--kind volume|brightness|mic|caps|layout|airplane] [--value 0..1]
#                                              with --state osd
#       [--backend ws://127.0.0.1:7777]        live services (lugh-shell-devd)
#       [--screenshot <out.png>] [--shot-delay <ms>] [--measure]
#       [--motion <state> --motion-out <dir>] [--motion-frames 24]
#
# Every argument goes to preview.qml as is. --screenshot and --motion render
# and exit; unless QT_QPA_PLATFORM is set they use the offscreen platform (no
# window flashes; Qt's software renderer: no shader effects — use
# scripts/shell-shots.sh / shell-motion.sh for the real GPU rendering).
# --measure prints the time from process start to the first frame, then exits.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"

args=("$@")
batch=0; measure=0
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --screenshot)
      # Absolute path: the QML side has no cwd context.
      if ((i + 1 < ${#args[@]})); then
        args[i + 1]="$(realpath -m "${args[i + 1]}")"
        mkdir -p "$(dirname "${args[i + 1]}")"
        batch=1
      fi ;;
    --motion-out)
      if ((i + 1 < ${#args[@]})); then
        args[i + 1]="$(realpath -m "${args[i + 1]}")"
        mkdir -p "${args[i + 1]}"
        batch=1
      fi ;;
    --measure) measure=1 ;;
  esac
done
((batch)) && export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
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

if ((measure)); then
  start_ms=$(date +%s%3N)
  out="$("${cmd[@]}" 2>&1)" || true
  printf '%s\n' "$out" | grep -v 'first-frame-epoch-ms' || true
  frame_ms=$(printf '%s\n' "$out" | sed -n 's/.*first-frame-epoch-ms \([0-9]*\).*/\1/p' | head -1)
  [[ -n "$frame_ms" ]] || { echo "shell-preview: no frame was drawn" >&2; exit 1; }
  echo "shell-preview: first frame after $((frame_ms - start_ms)) ms"
  exit 0
fi

if ((batch)); then
  exec timeout 60 "${cmd[@]}"
fi
exec "${cmd[@]}"
