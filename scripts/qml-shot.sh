#!/usr/bin/env bash
# Render a QML file to a PNG with the Lugh import paths set.
#   scripts/qml-shot.sh <file.qml> <out.png> [width=1440] [height=900] [delay-ms=900] [-- extra args]
# Uses the real Wayland/X11 display when present (shader effects such as
# MultiEffect need the GPU; the offscreen platform silently skips them), so a
# window flashes for about a second. Set QT_QPA_PLATFORM=offscreen to avoid that
# when the scene has no shader effects.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="$(realpath "$1")"; out="$(realpath -m "$2")"
w="${3:-1440}"; h="${4:-900}"; delay="${5:-900}"
shift $(( $# < 5 ? $# : 5 )); [[ "${1:-}" == "--" ]] && shift
export QT_FORCE_STDERR_LOGGING=1
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"
export QML_IMPORT_PATH="$root/ui/components:$root/ui/shell/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
timeout 30 "$qml" -I "$root/ui/components" -I "$root/ui/shell/qml" "$root/tools/qml-shot/Shot.qml" -- \
  --file "file://$file" --out "$out" --width "$w" --height "$h" --delay "$delay" "$@"
echo "qml-shot: $out"
