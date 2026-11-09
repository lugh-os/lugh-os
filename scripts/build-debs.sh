#!/usr/bin/env bash
# Build every Lugh .deb into out/debs/ (what `make debs` runs).
#
#   scripts/build-debs.sh            # all packages
#   scripts/build-debs.sh lugh-branding [...]   # only these
#
# For each packaging/<pkg>/debian/ (packaging/repo/ is not a package) a source
# tree is assembled in out/build/<pkg>/:
#   debian/    copy of packaging/<pkg>/debian/
#   branding/  copy of the repo's branding/
# and built with `dpkg-buildpackage -us -uc -b` inside the build container
# (scripts/lib/container.sh). lintian runs on each result: its findings are
# printed, and the build fails only on lintian errors. The .deb files land in
# out/debs/; .changes/.buildinfo and lintian.log stay in out/build/<pkg>.result/.
#
# Missing Build-Depends are installed from Debian with apt (needs network) and
# reported, so they can be added to scripts/build-env/Containerfile.
# Set LUGH_NO_CONTAINER=1 to run directly (already inside the build container).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# List package names: every packaging/<pkg>/debian/ except packaging/repo.
list_packages() {
  local d pkg
  for d in "$REPO_ROOT"/packaging/*/debian; do
    [[ -d "$d" ]] || continue
    pkg="$(basename "$(dirname "$d")")"
    [[ "$pkg" == repo ]] && continue
    printf '%s\n' "$pkg"
  done
}

build_one() {
  local pkg="$1"
  local build="$REPO_ROOT/out/build"
  local work="$build/$pkg"            # source tree
  local result="$build/$pkg.result"   # .changes, .buildinfo, .deb, lintian.log

  log "Building $pkg"
  rm -rf "$work" "$result"
  mkdir -p "$work" "$result"
  cp -a "$REPO_ROOT/packaging/$pkg/debian" "$work/debian"
  if [[ -d "$REPO_ROOT/branding" ]]; then
    cp -a "$REPO_ROOT/branding" "$work/branding"
  else
    warn "no branding/ directory in the repo; building $pkg without it"
  fi

  (
    cd "$work"
    if ! dpkg-checkbuilddeps >/dev/null 2>&1; then
      warn "$pkg: Build-Depends missing from the build image:"
      dpkg-checkbuilddeps 2>&1 | sed 's/^/    /' >&2 || true
      warn "installing them with apt-get build-dep (add them to scripts/build-env/Containerfile)"
      apt-get update -qq
      apt-get build-dep -y -qq --no-install-recommends ./ >/dev/null
    fi
    dpkg-buildpackage -us -uc -b
  )

  # dpkg-buildpackage writes its results next to the source tree, in out/build/.
  shopt -s nullglob
  local files=("$build"/*.deb "$build"/*.changes "$build"/*.buildinfo)
  shopt -u nullglob
  ((${#files[@]})) && mv "${files[@]}" "$result/"
  shopt -s nullglob
  local changes=("$result"/*.changes) debs=("$result"/*.deb)
  shopt -u nullglob
  ((${#debs[@]})) || die "$pkg: dpkg-buildpackage produced no .deb"

  ((${#changes[@]})) || die "$pkg: dpkg-buildpackage produced no .changes"

  log "lintian $pkg (fails on errors only)"
  # lintian should not run as root. The checkout may be unreadable for other
  # users (a 0700 home), so lint a copy in /tmp as nobody.
  local lint_dir="" as_user=() lint_changes=("${changes[@]}")
  if ((EUID == 0)) && command -v setpriv >/dev/null; then
    lint_dir="$(mktemp -d /tmp/lugh-lintian.XXXXXX)"
    cp "$result"/* "$lint_dir/"
    chmod 0755 "$lint_dir" && chmod 0644 "$lint_dir"/*
    lint_changes=("$lint_dir/$(basename "${changes[0]}")")
    as_user=(env HOME=/tmp setpriv --reuid=nobody --regid=nogroup --clear-groups)
  fi
  local lintian_rc=0
  (cd /tmp && "${as_user[@]}" lintian --fail-on error --display-info --info "${lint_changes[@]}") 2>&1 |
    tee "$result/lintian.log" >&2 || lintian_rc=$?
  [[ -z "$lint_dir" ]] || rm -rf "$lint_dir"
  ((lintian_rc == 0)) ||
    die "$pkg: lintian reported errors (see out/build/$pkg.result/lintian.log)"
  [[ -s "$result/lintian.log" ]] || echo "lintian: no findings" | tee "$result/lintian.log" >&2

  cp "${debs[@]}" "$REPO_ROOT/out/debs/"
}

in_build_env() {
  local pkgs=("$@")
  ((${#pkgs[@]})) || mapfile -t pkgs < <(list_packages)
  ((${#pkgs[@]})) || die "no packaging/*/debian directories found"

  local pkg
  for pkg in "${pkgs[@]}"; do
    [[ "$pkg" != repo && -d "$REPO_ROOT/packaging/$pkg/debian" ]] ||
      die "unknown package '$pkg' (no packaging/$pkg/debian/)"
  done

  # Clear previous output.
  rm -rf "$REPO_ROOT/out/debs" "$REPO_ROOT/out/build"
  mkdir -p "$REPO_ROOT/out/debs" "$REPO_ROOT/out/build"

  for pkg in "${pkgs[@]}"; do
    build_one "$pkg"
  done

  log "Built into out/debs/:"
  ls -1 "$REPO_ROOT/out/debs" >&2
}

main() {
  if [[ "${1:-}" == "--in-build-env" ]]; then
    shift
    in_build_env "$@"
    return
  fi
  if [[ "${LUGH_NO_CONTAINER:-0}" == 1 ]]; then
    in_build_env "$@"
    return
  fi
  # shellcheck source=scripts/lib/container.sh
  source "$REPO_ROOT/scripts/lib/container.sh"
  ensure_build_image
  run_in_build_env -- /src/scripts/build-debs.sh --in-build-env "$@"
}

main "$@"
