#!/usr/bin/env bash
# Build lugh-shell (ui/shell, cxx-qt + Qt 6) in the Debian trixie Qt container
# (tests/toolchain/Containerfile) and copy the binary to out/bin/lugh-shell.
# The host needs only a container engine: no Qt headers, no Rust.
#
#   scripts/build-shell.sh                 # release build -> out/bin/lugh-shell
#   scripts/build-shell.sh --embed         # same, with the QML tree compiled in
#                                          #   (cargo feature embed-qml)
#   scripts/build-shell.sh --update-lock   # allow changes to ui/shell/Cargo.lock
#                                          #   (after a dependency change)
#   scripts/build-shell.sh --test          # cargo test of the host crate, too
#   scripts/build-shell.sh --verify        # build, then smoke-test it there:
#                                          #   lugh-shell --check on the repo QML
#   scripts/build-shell.sh --exec <cmd…>   # run a command in the container
#                                          #   (the binary only runs on trixie)
#
# (-Wno-overloaded-virtual: the bridge signal `event(json)` shares its name
# with QObject::event on purpose; QML only sees the signal.)
# Release profile (ui/shell/Cargo.toml): thin LTO, one codegen unit, stripped.
# CARGO_TARGET_DIR is out/shell-target; rustup and the cargo registry live in
# the same named volumes as `make hello`.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
image="localhost/lugh-hello-env:$(sha256sum "$root/tests/toolchain/Containerfile" | cut -c1-12)"

features=(); test=0; verify=0; locked=1; exec_cmd=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --embed) features=(--features embed-qml); shift ;;
    --test) test=1; shift ;;
    --update-lock) locked=0; shift ;;
    --verify) verify=1; shift ;;
    --exec) shift; exec_cmd=("$@"); break ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-shell: unknown option $1" >&2; exit 2 ;;
  esac
done

"$engine" image inspect "$image" >/dev/null 2>&1 \
  || "$engine" build -t "$image" -f "$root/tests/toolchain/Containerfile" "$root/tests/toolchain"
mkdir -p "$root/out"

# Rootless podman maps container root to the caller; docker needs a chown.
if [[ "$engine" == podman && "$(id -u)" != 0 ]]; then owner=0:0; else owner="$(id -u):$(id -g)"; fi
tty=(); [[ -t 0 && -t 1 ]] && tty=(-t)

in_container() {
  # shellcheck disable=SC2016  # the script expands inside the container
  "$engine" run --rm --init -i "${tty[@]}" -v "$root:/src" -w /src \
    -v lugh-hello-rustup:/root/.rustup -v lugh-hello-cargo:/root/.cargo/registry \
    -e LANG=C.UTF-8 -e CARGO_TARGET_DIR=/src/out/shell-target -e QMAKE=/usr/lib/qt6/bin/qmake \
    -e CXXFLAGS=-Wno-overloaded-virtual -e XDG_RUNTIME_DIR=/tmp/xdg-runtime -e OWNER="$owner" ${LUGH_LOG:+-e LUGH_LOG="$LUGH_LOG"} \
    "$image" bash -c 'trap "chown -R \"$OWNER\" /src/out" EXIT
      mkdir -p -m 700 "$XDG_RUNTIME_DIR"; set -euo pipefail; "$@"' bash "$@"
}

if [[ ${#exec_cmd[@]} -gt 0 ]]; then
  in_container "${exec_cmd[@]}"
  exit
fi

build='rustup toolchain install >/dev/null
  cargo build --release --locked --manifest-path ui/shell/Cargo.toml "$@"
  install -D -m 755 out/shell-target/release/lugh-shell out/bin/lugh-shell'
[[ $locked == 1 && -f "$root/ui/shell/Cargo.lock" ]] || build="${build/ --locked/}"
(( test )) && build+='
  cargo test --release --manifest-path ui/shell/Cargo.toml "$@"'
(( verify )) && build+='
  mkdir -p /usr/share/backgrounds && ln -sfn /src/branding/wallpapers /usr/share/backgrounds/lugh
  dbus-run-session -- out/bin/lugh-shell --check --qml-dir ui/shell/qml --import-path ui/components'
in_container bash -euo pipefail -c "$build" bash "${features[@]}"

size="$(stat -c %s "$root/out/bin/lugh-shell")"
echo "build-shell: out/bin/lugh-shell ($((size / 1024)) KB, linked against Debian trixie's Qt 6.8)"
