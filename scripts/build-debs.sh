#!/usr/bin/env bash
# Build every Lugh .deb into out/debs/ (what `make debs` runs).
#
#   scripts/build-debs.sh            # all packages
#   scripts/build-debs.sh lugh-branding [...]   # only these
#
# For each packaging/<pkg>/debian/ (packaging/repo/ is not a package) a source
# tree is assembled in out/build/<pkg>/:
#   debian/    copy of packaging/<pkg>/debian/
#   <path>     copy of every repo path listed in debian/lugh-sources
# and built with `dpkg-buildpackage -us -uc -b` inside the build container
# (scripts/lib/container.sh). lintian runs on each result: its findings are
# printed, and the build fails only on lintian errors. The .deb files land in
# out/debs/; .changes/.buildinfo and lintian.log stay in out/build/<pkg>.result/.
#
# debian/lugh-sources: one repo-relative path per line (file or directory,
# `#` comments and blank lines ignored). Each is copied to the same relative
# path in the build tree, so debian/install reads like the repo layout.
#
# Version: every package gets <VERSION file>.<LUGH_DEB_PATCH, default 1>
# (0.0 -> 0.0.1); the top entry of debian/changelog is restamped in the build
# tree. Set LUGH_DEB_VERSION to give the full version yourself.
#
# lugh-shell and lugh-greeter (Rust + cxx-qt) build their binary from the
# checkout through scripts/build-env/cargo-deb-build.sh, which reuses an
# up-to-date out/bin/<name> (docs/dev/packaging.md). Packages are built in
# dependency-free order; none needs another Lugh package to build.
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

# Copy the repo paths listed in debian/lugh-sources into the build tree.
copy_sources() {
  local pkg="$1" work="$2" list="$2/debian/lugh-sources" line path
  [[ -f "$list" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r path _ <<<"$line" || true
    [[ -n "${path:-}" ]] || continue
    [[ "$path" != /* && "$path" != *..* ]] ||
      die "$pkg: debian/lugh-sources: '$path' must be a path inside the repo"
    [[ -e "$REPO_ROOT/$path" ]] ||
      die "$pkg: debian/lugh-sources: $path does not exist in the repo"
    mkdir -p "$work/$(dirname "$path")"
    cp -a "$REPO_ROOT/$path" "$work/$path"
  done <"$list"
}

# Package version from the repo's VERSION file.
deb_version() {
  if [[ -n "${LUGH_DEB_VERSION:-}" ]]; then
    printf '%s\n' "$LUGH_DEB_VERSION"
    return
  fi
  local v
  v="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" || die "cannot read VERSION"
  [[ -n "$v" ]] || die "VERSION is empty"
  printf '%s.%s\n' "$v" "${LUGH_DEB_PATCH:-1}"
}

# Restamp the top changelog entry in the build tree with deb_version.
stamp_version() {
  local pkg="$1" work="$2" version
  version="$(deb_version)"
  sed -i -E "1s/^([^ ]+) \\([^)]*\\)/\\1 (${version})/" "$work/debian/changelog"
  head -n1 "$work/debian/changelog" | grep -qF "($version)" ||
    die "$pkg: could not set the version in debian/changelog"
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
  copy_sources "$pkg" "$work"
  stamp_version "$pkg" "$work"

  (
    cd "$work"
    if ! dpkg-checkbuilddeps >/dev/null 2>&1; then
      warn "$pkg: Build-Depends missing from the build image:"
      dpkg-checkbuilddeps 2>&1 | sed 's/^/    /' >&2 || true
      warn "installing them with apt-get build-dep (add them to scripts/build-env/Containerfile)"
      apt-get update -qq
      apt-get build-dep -y -qq --no-install-recommends ./ >/dev/null
    fi
    LUGH_REPO_ROOT="$REPO_ROOT" DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-noautodbgsym}" \
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
