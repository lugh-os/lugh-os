#!/usr/bin/env bash
# Build lugh-greeter (ui/greeter, cxx-qt + Qt 6) in the trixie Qt container,
# the same image `make hello` uses (tests/toolchain/Containerfile).
#
#   scripts/build-greeter.sh            release build -> out/bin/lugh-greeter
#   scripts/build-greeter.sh --verify   also: clippy, `lugh-greeter --check`, and
#                                       a full login against a fake greetd
#                                       (a second binary built with test-hooks)
#
# Cargo output goes to out/greeter-target. Extra cargo features for the shipped
# binary: none (test-hooks is only used for the --verify binary).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

verify=0
case "${1:-}" in
  "") ;;
  --verify) verify=1 ;;
  *) echo "usage: $0 [--verify]" >&2; exit 2 ;;
esac

engine="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
image="localhost/lugh-hello-env:$(sha256sum tests/toolchain/Containerfile | cut -c1-12)"
"$engine" image inspect "$image" >/dev/null 2>&1 ||
  "$engine" build -t "$image" -f tests/toolchain/Containerfile tests/toolchain

# Rootless podman maps container root to the host user; docker does not.
if [[ "$engine" == podman && "$(id -u)" != 0 ]]; then owner=0:0; else owner="$(id -u):$(id -g)"; fi

mkdir -p out/bin
# shellcheck disable=SC2016  # the script expands inside the container
"$engine" run --rm --init -v "$root:/src" -w /src \
  -v lugh-hello-rustup:/root/.rustup -v lugh-hello-cargo:/root/.cargo/registry \
  -e LANG=C.UTF-8 -e CARGO_TARGET_DIR=/src/out/greeter-target -e QMAKE=/usr/lib/qt6/bin/qmake \
  -e OWNER="$owner" -e VERIFY="$verify" \
  "$image" bash -euo pipefail -c '
    trap "chown -R \"$OWNER\" /src/out" EXIT
    manifest=ui/greeter/Cargo.toml
    rustup toolchain install
    cargo build --release --manifest-path "$manifest"
    install -m 0755 out/greeter-target/release/lugh-greeter out/bin/lugh-greeter
    echo "build-greeter: out/bin/lugh-greeter"
    [[ "$VERIFY" == 1 ]] || exit 0

    # The UI needs QML modules the toolchain image does not carry.
    missing=()
    for pkg in qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-effects; do
      dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
      apt-get update -qq && apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
    fi

    cargo clippy --release --manifest-path "$manifest" --all-features -- -D warnings

    export QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1
    ui=(--qml-dir ui/greeter/qml --import-path ui/components)
    echo "== lugh-greeter --check"
    out/bin/lugh-greeter --check "${ui[@]}"
    echo "== refuses to run without greetd"
    if env -u GREETD_SOCK out/bin/lugh-greeter "${ui[@]}"; then echo "expected a refusal" >&2; exit 1; fi

    echo "== full login against a fake greetd"
    cargo build --release --manifest-path "$manifest" --features test-hooks \
      --target-dir out/greeter-target/hooks
    cargo build --release -p lugh-greetd --example fake_greetd --target-dir out/greeter-target/fake
    sock="$(mktemp -d)/greetd.sock"
    out/greeter-target/fake/release/examples/fake_greetd "$sock" amara "s3cret pw" 60 &
    fake=$!
    for _ in $(seq 50); do [[ -S "$sock" ]] && break; sleep 0.1; done
    rc=0
    GREETD_SOCK="$sock" LUGH_GREETER_AUTOTEST="amara:s3cret pw" \
      timeout 60 out/greeter-target/hooks/release/lugh-greeter "${ui[@]}" || rc=$?
    echo "lugh-greeter exited $rc"
    wait "$fake"; echo "fake_greetd exited 0 (start_session received)"
    [[ "$rc" == 0 ]]
    # The shipped binary must not carry the hook.
    if grep -q LUGH_GREETER_AUTOTEST out/bin/lugh-greeter; then
      echo "the release binary contains the autotest hook" >&2; exit 1
    fi
    echo "build-greeter: verified"
  '
