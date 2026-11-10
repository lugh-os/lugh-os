#!/usr/bin/env bash
# Build (or reuse) one Rust/cxx-qt binary for a Debian package. Called from
# debian/rules of lugh-shell and lugh-greeter, inside the build container.
#
#   cargo-deb-build.sh <name> <manifest> <target-dir> <output file>
#   e.g. cargo-deb-build.sh lugh-shell ui/shell/Cargo.toml out/shell-target build/lugh-shell
#
# <manifest> and <target-dir> are relative to the repo checkout
# (LUGH_REPO_ROOT, default /src); <output file> is relative to the caller.
#
# 1. Reuse: when <repo>/out/bin/<name> exists and no build input is newer than
#    it (the crate's src/, cpp/, build.rs, Cargo.toml, Cargo.lock, QML compiled
#    into the binary, crates/, rust-toolchain.toml), that binary is copied.
#    `make shell` / `make greeter` produce it with the same commands in the
#    same trixie userland. LUGH_FORCE_CARGO=1 skips this step.
# 2. Else: `rustup toolchain install` (rust-toolchain.toml) and
#    `cargo build --release --locked`, the commands of scripts/build-shell.sh
#    and scripts/build-greeter.sh, with CARGO_TARGET_DIR=<repo>/<target-dir>
#    so the work is shared with those scripts. The result is also copied to
#    out/bin/<name>. LUGH_CARGO_OFFLINE=1 adds --offline (vendored crates).
set -euo pipefail

(($# == 4)) || { echo "usage: $0 <name> <manifest> <target-dir> <output>" >&2; exit 2; }
name="$1" manifest="$2" target="$3" output="$4"
repo="${LUGH_REPO_ROOT:-/src}"
crate_dir="$repo/$(dirname "$manifest")"
prebuilt="$repo/out/bin/$name"

[[ -f "$repo/$manifest" ]] || { echo "cargo-deb-build: $repo/$manifest not found" >&2; exit 1; }

inputs=()
for p in "$crate_dir/src" "$crate_dir/cpp" "$crate_dir/build.rs" "$crate_dir/Cargo.toml" \
  "$crate_dir/Cargo.lock" "$crate_dir/qml/backend" "$repo/crates" "$repo/rust-toolchain.toml"; do
  [[ -e "$p" ]] && inputs+=("$p")
done

mkdir -p "$(dirname "$output")"
if [[ "${LUGH_FORCE_CARGO:-0}" != 1 && -x "$prebuilt" ]]; then
  newer="$(find "${inputs[@]}" -type f -newer "$prebuilt" -not -path '*/target/*' -print -quit)"
  if [[ -z "$newer" ]]; then
    echo "cargo-deb-build: reusing out/bin/$name (newer than its sources)" >&2
    install -m 0755 "$prebuilt" "$output"
    exit 0
  fi
  echo "cargo-deb-build: out/bin/$name is older than ${newer#"$repo"/}; rebuilding" >&2
fi

export CARGO_TARGET_DIR="$repo/$target"
export QMAKE="${QMAKE:-/usr/lib/qt6/bin/qmake}"
flags=(--release --locked)
[[ -f "$crate_dir/Cargo.lock" ]] || flags=(--release)
[[ "${LUGH_CARGO_OFFLINE:-0}" == 1 ]] && flags+=(--offline)

# rustup reads rust-toolchain.toml from the working directory upwards.
(
  cd "$repo"
  [[ "${LUGH_CARGO_OFFLINE:-0}" == 1 ]] || rustup toolchain install >&2
  cargo build "${flags[@]}" --manifest-path "$manifest" >&2
)
install -m 0755 "$CARGO_TARGET_DIR/release/$name" "$output"
install -D -m 0755 "$output" "$prebuilt"
echo "cargo-deb-build: built $name" >&2
