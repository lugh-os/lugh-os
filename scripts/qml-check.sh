#!/usr/bin/env bash
# Headless QML load check: loads every demo, every Lugh.Shell surface and the
# desktop preview (each --state) with QT_QPA_PLATFORM=offscreen and fails on
# any QML warning or error. `make qml-check` runs it.
#   scripts/qml-check.sh            # everything
#   scripts/qml-check.sh -v         # also print each item's full output
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2
verbose=0; [[ "${1:-}" == -v ]] && verbose=1
qml="$(command -v qml6 || command -v qml || echo /usr/lib/qt6/bin/qml)"

export QT_QPA_PLATFORM=offscreen
export QT_FORCE_STDERR_LOGGING=1
export QT_MESSAGE_PATTERN='%{type}: %{message}'
export QML_IMPORT_PATH="$root/ui/components:$root/ui/shell/qml"
export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
imports=(-I "$root/ui/components" -I "$root/ui/shell/qml")
harness="$root/ui/shell/qml/preview/Check.qml"
# Without lugh-branding installed, point Wallpaper at the repo's art.
wp=(); [[ -d /usr/share/backgrounds/lugh ]] || wp=(--wallpaper-dir "file://$root/branding/wallpapers/")

fails=0; total=0
# run <label> <qml file> [args…]: fails on a non-zero exit or any
# warning/critical/fatal line.
run() {
  local label="$1"; shift
  local out rc
  out="$(timeout 30 "$qml" "${imports[@]}" "$@" 2>&1)"; rc=$?
  total=$((total + 1))
  local bad
  bad="$(printf '%s\n' "$out" | grep -E '^(warning|critical|fatal): ' || true)"
  if ((rc != 0)) || [[ -n "$bad" ]]; then
    fails=$((fails + 1))
    printf 'FAIL  %s (exit %d)\n' "$label" "$rc"
    printf '%s\n' "${bad:-$out}" | sed 's/^/      /' | head -20
  else
    printf 'ok    %s\n' "$label"
  fi
  ((verbose)) && printf '%s\n' "$out" | sed 's/^/      | /'
  return 0
}

# 1. Demos and galleries (root Item or Window-less component).
shopt -s nullglob globstar
for f in ui/components/demos/*.qml ui/components/gallery/*.qml ui/shell/qml/demos/*.qml \
         ui/shell/qml/Lugh/Shell/**/*Demo.qml ui/greeter/qml/GreeterDemo.qml; do
  run "$f" "$harness" -- --file "file://$root/$f" "${wp[@]}"
done

# 2. Every non-singleton type of Lugh.Shell, created by name as the frame does.
while read -r type _ file; do
  [[ "$type" == module || "$type" == singleton || -z "$file" ]] && continue
  if [[ -f "ui/shell/qml/Lugh/Shell/$file" ]]; then
    run "Lugh.Shell/$type" "$harness" -- --type "$type" "${wp[@]}"
  else
    total=$((total + 1)); fails=$((fails + 1))
    printf 'FAIL  Lugh.Shell/%s (missing %s)\n' "$type" "$file"
  fi
done < ui/shell/qml/Lugh/Shell/qmldir

# 3. The desktop preview in every state (it quits itself after --measure).
for state in none launcher controlcenter notifications menu lock osd toast; do
  run "preview --state $state" ui/shell/qml/preview.qml -- --state "$state" --measure "${wp[@]}"
done

echo
if ((fails)); then
  echo "qml-check: $fails of $total failed"
  exit 1
fi
echo "qml-check: all $total clean"
