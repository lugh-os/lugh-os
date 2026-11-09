#!/usr/bin/env bash
# Render Lugh brand PNGs from the SVG sources in branding/.
#
#   branding/logo/png/lugh-logo-{128,256,512}.png        (GRUB, Plymouth, light backgrounds)
#   branding/logo/png/lugh-logo-dark-{128,256,512}.png   (Plymouth, dark backgrounds)
#   branding/icons/hicolor/<N>x<N>/apps/lugh-logo.png    (icon theme, LOGO=lugh-logo)
#
# Uses rsvg-convert when the host has it; otherwise runs itself inside a
# debian:trixie container (librsvg2-bin) and hands the outputs back to the
# calling user. Idempotent: every run overwrites the same files.
#
# Usage: scripts/render-brand-assets.sh   (from any directory)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGO_DIR="$REPO_ROOT/branding/logo"
PNG_DIR="$LOGO_DIR/png"
ICON_DIR="$REPO_ROOT/branding/icons/hicolor"
ICON_SVG="$ICON_DIR/scalable/apps/lugh-logo.svg"

LOGO_SIZES=(128 256 512)
ICON_SIZES=(16 22 24 32 48 64 128 256 512)
DEBIAN_IMAGE="${LUGH_RENDER_IMAGE:-debian:trixie}"

render() { # <svg> <size> <out.png>
  local svg="$1" size="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  rsvg-convert --width "$size" --height "$size" --keep-aspect-ratio \
    --format png --output "$out.tmp" "$svg"
  mv -f "$out.tmp" "$out"
  echo "  ${out#"$REPO_ROOT"/}"
}

render_all() {
  echo "Rendering brand assets with $(rsvg-convert --version)"
  for size in "${LOGO_SIZES[@]}"; do
    render "$LOGO_DIR/lugh-logo.svg"      "$size" "$PNG_DIR/lugh-logo-$size.png"
    render "$LOGO_DIR/lugh-logo-dark.svg" "$size" "$PNG_DIR/lugh-logo-dark-$size.png"
  done
  for size in "${ICON_SIZES[@]}"; do
    render "$ICON_SVG" "$size" "$ICON_DIR/${size}x${size}/apps/lugh-logo.png"
  done
}

if command -v rsvg-convert >/dev/null 2>&1; then
  render_all
  # Inside the container fallback: give the files back to the host user.
  if [[ -n "${LUGH_HOST_UID:-}" ]]; then
    chown -R "$LUGH_HOST_UID:${LUGH_HOST_GID:-$LUGH_HOST_UID}" "$PNG_DIR" \
      "$ICON_DIR"/*x*/
  fi
  exit 0
fi

if [[ -n "${LUGH_HOST_UID:-}" ]]; then
  echo "error: rsvg-convert still missing inside the container" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "error: need rsvg-convert (apt install librsvg2-bin) or docker" >&2
  exit 1
fi

echo "rsvg-convert not found; rendering inside $DEBIAN_IMAGE"
docker run --rm \
  -v "$REPO_ROOT:/src" \
  -e LUGH_HOST_UID="$(id -u)" -e LUGH_HOST_GID="$(id -g)" \
  -e DEBIAN_FRONTEND=noninteractive \
  "$DEBIAN_IMAGE" bash -c '
    set -euo pipefail
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends librsvg2-bin >/dev/null
    exec bash /src/scripts/render-brand-assets.sh
  '
