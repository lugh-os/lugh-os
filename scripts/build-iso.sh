#!/usr/bin/env bash
# scripts/build-iso.sh — build the Lugh live ISO with live-build.
#
#   scripts/build-iso.sh            (what `make iso` runs)
#
# Inputs (produced before this script by `make debs repo`):
#   out/repo/            signed local apt repo (distribution trixie, component main)
#   out/repo/lugh.asc    its public key
#   branding/grub/       GRUB theme directory (theme.txt + assets)
#
# Outputs:
#   out/lugh-<version>-amd64.iso, out/lugh-<version>-amd64.iso.sha256,
#   out/lugh.iso -> lugh-<version>-amd64.iso, out/lugh-<version>-amd64.packages
#   (package manifest) and out/iso-build.log.
#
# The build runs inside the trixie build container (scripts/lib/container.sh),
# privileged and on the host network. live-build works in a copy of iso/
# inside the container (so the chroot never lands in the checkout); only the
# .deb cache iso/cache/ is shared with the host and handed back to the host
# user afterwards. During the build out/repo/ is served on 127.0.0.1:8099,
# which config/archives/lugh.list.chroot points at.
#
# Environment:
#   LUGH_DEBIAN_MIRROR, LUGH_DEBIAN_SECURITY_MIRROR   override the mirrors
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=scripts/lib/container.sh
source "$REPO_ROOT/scripts/lib/container.sh"

die() { echo "error: $*" >&2; exit 1; }
note() { echo ">> $*" >&2; }

cd "$REPO_ROOT"

# --- version ------------------------------------------------------------------
[[ -f VERSION ]] || die "VERSION file not found in $REPO_ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -n "$VERSION" ]] || die "VERSION is empty"
ISO_NAME="lugh-${VERSION}-amd64.iso"

# --- inputs -------------------------------------------------------------------
if [[ ! -d out/repo || ! -f out/repo/lugh.asc || ! -e out/repo/dists/trixie/Release ]]; then
	die "the local Lugh apt repo is missing (need out/repo/dists/trixie/Release and out/repo/lugh.asc).
       Build and publish it first:  make debs repo"
fi
[[ -f out/repo/dists/trixie/InRelease || -f out/repo/dists/trixie/Release.gpg ]] \
	|| die "out/repo is not signed (no InRelease/Release.gpg); re-run: make repo"
[[ -f branding/grub/theme.txt ]] \
	|| die "branding/grub/theme.txt is missing; the GRUB theme comes from branding/grub/ (lugh-branding)"

# --- staging (host side, as the host user; all staged paths are gitignored) ----
note "staging inputs into iso/config"
install -D -m 0644 out/repo/lugh.asc iso/config/archives/lugh.key.chroot
install -D -m 0644 out/repo/lugh.asc iso/config/includes.chroot/etc/apt/keyrings/lugh.asc
rm -rf iso/config/bootloaders/grub-pc/live-theme
mkdir -p iso/config/bootloaders/grub-pc/live-theme
cp -a branding/grub/. iso/config/bootloaders/grub-pc/live-theme/
mkdir -p out iso/cache

# The repo is served on the host network; make sure the port is free.
if (exec 3<>/dev/tcp/127.0.0.1/8099) 2>/dev/null; then
	die "127.0.0.1:8099 is already in use; the ISO build serves out/repo there"
fi

ensure_build_image

rm -f "out/$ISO_NAME" "out/$ISO_NAME.sha256" out/lugh.iso

# --- build (inside the container, as root) ------------------------------------
# shellcheck disable=SC2016  # runs inside the container
inner='
set -euo pipefail
export LUGH_ISO_NAME="$1"

# /build lives in the (throw-away) container; never rm it here: the host
# cache is bind-mounted inside it.
http_pid=
cleanup() {
	[ -n "$http_pid" ] && kill "$http_pid" 2>/dev/null || true
	# lb needs a bootstrap stage cache (see iso/auto/config); it is a
	# root-owned rootfs, so never leave it in the host-shared cache.
	rm -rf /build/cache/bootstrap
	umount /build/cache 2>/dev/null || true
}
trap cleanup EXIT

echo ">> serving out/repo on http://127.0.0.1:8099"
python3 -m http.server 8099 --bind 127.0.0.1 --directory /src/out/repo \
	>/tmp/lugh-repo-http.log 2>&1 &
http_pid=$!
for _ in $(seq 50); do
	curl -fsS -o /dev/null http://127.0.0.1:8099/dists/trixie/Release && break
	sleep 0.2
done
curl -fsS -o /dev/null http://127.0.0.1:8099/dists/trixie/Release \
	|| { echo "error: local repo server did not come up" >&2; cat /tmp/lugh-repo-http.log >&2; exit 1; }

# Work in a container-local copy of iso/; share only the .deb cache.
rm -rf /build
mkdir -p /build
rsync -a --exclude=/cache --exclude=/chroot --exclude=/binary --exclude=/.build \
	--exclude="/*.iso" --exclude=/build.log /src/iso/ /build/
mkdir -p /build/cache
mount --bind /src/iso/cache /build/cache
rm -rf /build/cache/bootstrap
cd /build

lb clean
lb config
rc=0
lb build || rc=$?
[ -f build.log ] && cp build.log /src/out/iso-build.log
if [ "$rc" != 0 ]; then
	echo "error: lb build failed (exit $rc); log: out/iso-build.log" >&2
	exit "$rc"
fi

iso=/build/lugh-amd64.hybrid.iso
[ -f "$iso" ] || { echo "error: lb build produced no $iso" >&2; exit 1; }
cp "$iso" "/src/out/$LUGH_ISO_NAME"
if [ -f /build/lugh-amd64.packages ]; then
	cp /build/lugh-amd64.packages "/src/out/${LUGH_ISO_NAME%.iso}.packages"
fi
'

note "building $ISO_NAME (this downloads ~1 GB on a cold cache)"
start=$(date +%s)
LUGH_CHOWN_PATHS="iso/cache ${LUGH_CHOWN_PATHS:-}" \
	run_in_build_env --privileged --net-host -- bash -c "$inner" lugh-build-iso "$ISO_NAME"
end=$(date +%s)

# --- outputs (host side) ------------------------------------------------------
[[ -f "out/$ISO_NAME" ]] || die "build finished but out/$ISO_NAME is missing"
(cd out && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256")
ln -sfn "$ISO_NAME" out/lugh.iso

size=$(stat -c %s "out/$ISO_NAME")
note "done in $(( (end - start) / 60 ))m$(( (end - start) % 60 ))s"
note "out/$ISO_NAME  $(numfmt --to=iec --suffix=B "$size") ($size bytes)"
note "out/$ISO_NAME.sha256"
note "out/lugh.iso -> $ISO_NAME"
