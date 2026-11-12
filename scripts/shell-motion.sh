#!/usr/bin/env bash
# Motion contact sheets: how the liquid motion of the composed desktop looks,
# without a human at the screen. For each motion the preview grabs its scene
# as fast as it can (frame 0 = just before the trigger; one grab takes 35–100
# ms), in MOTION_PASSES runs whose grabs are shifted against each other, and
# the frames of all runs are tiled in time order into one sheet (~30 ms
# apart), each labelled with its time since the trigger:
#   out/motion/<name>-{light,dark}.png        (frames kept in out/motion/frames/)
#
#   scripts/shell-motion.sh [out-dir=out/motion] [extra preview args…]
#   MOTION_NAMES="launcher osd"  MOTION_THEMES="dark"
#   MOTION_MS=900 (recorded time)  MOTION_PASSES=3
#   MOTION_CROP=full  keeps whole frames (default: the region that moves).
#
# Names: launcher, controlcenter, notifications, menu, osd, toast, lock,
# overview, customize (these two are recorded full frame).
# Rendering is the same as scripts/shell-shots.sh (headless nested KWin when
# kwin_wayland is there, else the software renderer). Needs ImageMagick.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/out/motion}"; [[ $# -gt 0 ]] && shift
out="$(realpath -m "$out")"
mkdir -p "$out/frames"

montage="$(command -v montage || true)"
[[ -n "$montage" ]] || { echo "shell-motion: ImageMagick (montage) is not installed" >&2; exit 2; }

platform="${SHOTS_PLATFORM:-$(command -v kwin_wayland >/dev/null && echo nested || echo offscreen)}"
if [[ "$platform" == nested && -z "${LUGH_NESTED:-}" ]]; then
  exec "$root/scripts/shell-run.sh" --nested-exec 3000x2000 -- "${BASH_SOURCE[0]}" "$out" "$@"
fi
[[ "$platform" == nested ]] || export QT_QPA_PLATFORM=offscreen
echo "shell-motion: rendering on $platform into $out"

read -r -a names <<<"${MOTION_NAMES:-launcher controlcenter notifications osd toast}"
read -r -a themes <<<"${MOTION_THEMES:-light dark}"
ms="${MOTION_MS:-900}"; passes="${MOTION_PASSES:-3}"
W=1440; H=900

# The part of the 1440×900 scene each motion happens in (WxH+X+Y). The
# panel is at the bottom: the quick panel, notification center and OSD open
# bottom-right, the Lugh menu bottom-left.
crop_for() {
  [[ "${MOTION_CROP:-}" == full ]] && { echo ""; return; }
  case "$1" in
    launcher)      echo "800x900+320+0" ;;
    controlcenter) echo "560x900+880+0" ;;
    notifications) echo "560x900+880+0" ;;
    menu)          echo "480x700+0+200" ;;
    osd)           echo "640x240+800+660" ;;
    toast)         echo "520x360+920+0" ;;
    *)             echo "" ;;
  esac
}

fail=0
# One capture at a time: parallel ones would steal each other's frame time.
for theme in "${themes[@]}"; do
  for name in "${names[@]}"; do
    dir="$out/frames/$name-$theme"
    rm -rf "$dir"; mkdir -p "$dir"
    log=""; ok=1
    for ((p = 0; p < passes; p++)); do
      a=(--motion "$name" --motion-out "$dir/p$p" --motion-frames 60 --motion-ms "$ms"
         --motion-offset $((p * 100 / passes)) --width "$W" --height "$H")
      [[ "$theme" == dark ]] && a+=(--dark)
      if ! l="$("$root/scripts/shell-preview.sh" "${a[@]}" "$@" 2>&1)"; then
        echo "FAIL $name-$theme"; printf '%s\n' "$l" | tail -5; fail=1; ok=0; break
      fi
      log+="$l"$'\n'
      # f-<nn>-<ms>.png → f-<ms>-p<pass>.png (time order); "before" only once.
      for f in "$dir/p$p"/f-*.png; do
        t="${f##*-}"; t="${t%.png}"
        [[ "$t" == 0000 && $p -gt 0 ]] || mv "$f" "$dir/f-$t-p$p.png"
      done
      rm -rf "$dir/p$p"
    done
    ((ok)) || continue

    crop="$(crop_for "$name")"
    m=(-background '#1b1a18' -fill '#f0ede6' -pointsize 15 -tile 8x -geometry "+4+4")
    lbl=(); n=0
    for f in "$dir"/f-*.png; do
      t="${f#"$dir"/f-}"; t="${t%%-*}"
      lbl+=(-label "$((10#$t)) ms" "$f"); n=$((n + 1))
    done
    if [[ -n "$crop" ]]; then
      "$montage" "${lbl[@]}" -crop "$crop" +repage -resize 50% "${m[@]}" "$out/$name-$theme.png"
    else
      "$montage" "${lbl[@]}" -resize 480x "${m[@]}" "$out/$name-$theme.png"
    fi
    echo "ok   $out/$name-$theme.png  ($n frames over $ms ms)"
    printf '%s\n' "$log" | grep -E 'warning|critical|unavailable' | sort -u | sed 's/^/     /' | head -5 || true
  done
done
exit "$fail"
