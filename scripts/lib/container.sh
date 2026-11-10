# shellcheck shell=bash
# scripts/lib/container.sh — run commands inside the Lugh build environment.
#
# Source this file (do not execute it):
#
#     source "$(dirname "$0")/lib/container.sh"
#     ensure_build_image
#     run_in_build_env [--privileged] [--net-host] -- cmd [args...]
#
# Sets:
#   REPO_ROOT          repository root (kept if already set)
#   CONTAINER_ENGINE   podman if installed, else docker (kept if already set)
#   LUGH_BUILD_IMAGE   localhost/lugh-build-env:trixie
#
# The image is built from scripts/build-env/Containerfile. Its sha256 is stored
# in the image label "lugh.containerfile.sha256"; ensure_build_image rebuilds
# when the label is missing or differs from the current file.
#
# run_in_build_env runs as root in the container, with $REPO_ROOT mounted at
# /src (also the working directory). It passes through every LUGH_* variable
# (this includes LUGH_REPO_GPG_KEY). When the command ends, /src/out and every
# path listed in LUGH_CHOWN_PATHS (space-separated, relative to the repo root
# or absolute /src/... paths) are chowned back to the host user, so no
# root-owned files are left in the checkout. The command's exit status is
# returned.
#
# Rust: the named volumes lugh-hello-rustup and lugh-hello-cargo (shared with
# `make hello`, scripts/build-shell.sh and scripts/build-greeter.sh) are mounted
# on /root/.rustup and /root/.cargo/registry, so the toolchain and the crate
# downloads survive between runs. Set LUGH_CARGO_OFFLINE=1 for `cargo --offline`
# builds from a vendored tree (docs/dev/packaging.md).

if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT

if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
	if command -v podman >/dev/null 2>&1; then
		CONTAINER_ENGINE=podman
	elif command -v docker >/dev/null 2>&1; then
		CONTAINER_ENGINE=docker
	else
		echo "error: neither podman nor docker is installed; install podman (preferred) or docker" >&2
		# shellcheck disable=SC2317  # 'exit' is reached when the file is executed, not sourced
		return 1 2>/dev/null || exit 1
	fi
fi
export CONTAINER_ENGINE

LUGH_BUILD_IMAGE="localhost/lugh-build-env:trixie"
export LUGH_BUILD_IMAGE

_LUGH_CONTAINERFILE="$REPO_ROOT/scripts/build-env/Containerfile"
_LUGH_IMAGE_LABEL="lugh.containerfile.sha256"

# ensure_build_image: build the image if it is missing or out of date.
ensure_build_image() {
	local want have
	if [[ ! -f "$_LUGH_CONTAINERFILE" ]]; then
		echo "error: $_LUGH_CONTAINERFILE not found (is REPO_ROOT=$REPO_ROOT right?)" >&2
		return 1
	fi
	want="$(sha256sum "$_LUGH_CONTAINERFILE")" || return 1
	want="${want%% *}"
	have="$("$CONTAINER_ENGINE" image inspect \
		--format "{{ index .Config.Labels \"$_LUGH_IMAGE_LABEL\" }}" \
		"$LUGH_BUILD_IMAGE" 2>/dev/null || true)"
	if [[ "$have" == "$want" ]]; then
		return 0
	fi
	if [[ -z "$have" ]]; then
		echo ">> building $LUGH_BUILD_IMAGE with $CONTAINER_ENGINE" >&2
	else
		echo ">> Containerfile changed; rebuilding $LUGH_BUILD_IMAGE" >&2
	fi
	"$CONTAINER_ENGINE" build \
		--label "$_LUGH_IMAGE_LABEL=$want" \
		-t "$LUGH_BUILD_IMAGE" \
		-f "$_LUGH_CONTAINERFILE" \
		"$(dirname "$_LUGH_CONTAINERFILE")"
}

# run_in_build_env [--privileged] [--net-host] -- cmd [args...]
run_in_build_env() {
	local -a opts=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--privileged) opts+=(--privileged) ;;
		--net-host) opts+=(--network host) ;;
		--) shift; break ;;
		*)
			echo "run_in_build_env: unknown option '$1' (expected --privileged, --net-host, --)" >&2
			return 2
			;;
		esac
		shift
	done
	if [[ $# -eq 0 ]]; then
		echo "run_in_build_env: no command given" >&2
		return 2
	fi

	# Pass LUGH_* through by name (the value is read from our environment, so
	# multi-line values such as an armored GPG key survive).
	local name
	while IFS= read -r name; do
		[[ -n "$name" ]] && opts+=(-e "$name")
	done < <(compgen -e | grep -E '^LUGH_' || true)

	# Who should own the files we hand back. Rootless podman maps container
	# root to the invoking user already, so files must stay owned by uid 0
	# inside the container; everywhere else chown to the host uid:gid.
	local owner
	if [[ "$CONTAINER_ENGINE" == podman && "$(id -u)" != 0 ]]; then
		owner="0:0"
	else
		owner="$(id -u):$(id -g)"
	fi

	local -a tty=()
	if [[ -t 0 && -t 1 ]]; then
		tty=(-t)
	fi

	# The wrapper runs the command, then chowns the output paths back even
	# when the command failed, and exits with the command's status.
	# shellcheck disable=SC2016  # expanded inside the container
	local wrapper='
		_lugh_chown_back() {
			local p
			for p in /src/out ${_LUGH_CHOWN_PATHS:-}; do
				case "$p" in /*) ;; *) p="/src/$p" ;; esac
				[ -e "$p" ] && chown -R "$_LUGH_OWNER" "$p"
			done
			return 0
		}
		trap _lugh_chown_back EXIT
		_lugh_rc=0
		"$@" || _lugh_rc=$?
		exit "$_lugh_rc"
	'

	"$CONTAINER_ENGINE" run --rm -i "${tty[@]}" --init \
		--user 0:0 \
		-v "$REPO_ROOT:/src" -w /src \
		-v lugh-hello-rustup:/root/.rustup \
		-v lugh-hello-cargo:/root/.cargo/registry \
		-e "_LUGH_OWNER=$owner" \
		-e "_LUGH_CHOWN_PATHS=${LUGH_CHOWN_PATHS:-}" \
		"${opts[@]}" \
		"$LUGH_BUILD_IMAGE" \
		bash -c "$wrapper" lugh-build-env "$@"
}
