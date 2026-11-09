# Lugh OS — build entry points.  Run `make` (or `make help`) for the list.
#
# Heavy work (debs, repo, ISO) runs inside the Debian trixie build container
# (scripts/lib/container.sh: podman preferred, docker fallback). The host only
# needs make, bash, a container engine and QEMU + OVMF. See docs/dev/setup.md.

SHELL       := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS   += --no-builtin-rules

VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0)
ISO     ?= out/lugh.iso
export ISO

# Container engine for the targets that call it directly (hello). The build
# scripts pick their own through scripts/lib/container.sh, which honours the
# same CONTAINER_ENGINE variable.
CONTAINER_ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
export CONTAINER_ENGINE

# Tagged with the Containerfile's hash, so editing it builds a fresh image.
HELLO_IMAGE := localhost/lugh-hello-env:$(shell sha256sum tests/toolchain/Containerfile 2>/dev/null | cut -c1-12)
CONTAINER_LIB := source scripts/lib/container.sh

.PHONY: help iso debs repo brand-assets check hello build-env \
        run-uefi run-uefi-sb run-bios \
        test-boot test-boot-uefi test-boot-uefi-sb test-boot-bios \
        clean

help: ## List the make targets
	@printf 'Lugh OS %s — make targets\n\n' '$(VERSION)'
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
	  awk -v tty="$$([ -t 1 ] && echo 1)" \
	    'BEGIN { FS = ":.*## "; b = tty ? "\033[1m" : ""; r = tty ? "\033[0m" : "" } \
	     { printf "  %s%-18s%s %s\n", b, $$1, r, $$2 }'
	@printf '\nVariables: ISO=%s  CONTAINER_ENGINE=%s\n' '$(ISO)' '$(CONTAINER_ENGINE)'
	@printf 'Boot tests: BOOT_TIMEOUT=<s>  QEMU_ACCEL=kvm|tcg  QEMU_MEM=4G  QEMU_SMP=4\n'

# --- build -------------------------------------------------------------------

iso: debs repo ## Build the live ISO -> out/lugh-<VERSION>-amd64.iso (+ .sha256, out/lugh.iso)
	scripts/build-iso.sh

debs: ## Build all .deb packages -> out/debs/
	scripts/build-debs.sh

repo: ## Publish out/debs/ to the signed local apt repo -> out/repo/
	scripts/repo-publish.sh

brand-assets: ## Re-render logo PNGs from the SVG sources
	scripts/render-brand-assets.sh

build-env: ## Build (or refresh) the trixie build container image
	$(CONTAINER_LIB) && ensure_build_image

# --- code checks -------------------------------------------------------------

check: ## Rust: cargo fmt --check, clippy -D warnings, tests
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace

hello: ## Build the cxx-qt hello app (ui/hello) in a trixie container
	$(CONTAINER_ENGINE) image inspect $(HELLO_IMAGE) >/dev/null 2>&1 || \
	  $(CONTAINER_ENGINE) build -t $(HELLO_IMAGE) -f tests/toolchain/Containerfile tests/toolchain
	mkdir -p out
	$(CONTAINER_ENGINE) run --rm --init -v "$(CURDIR):/src" -w /src \
	  -v lugh-hello-rustup:/root/.rustup -v lugh-hello-cargo:/root/.cargo/registry \
	  -e LANG=C.UTF-8 -e CARGO_TARGET_DIR=/src/out/hello-target -e QMAKE=/usr/lib/qt6/bin/qmake \
	  -e OWNER="$$( [ '$(CONTAINER_ENGINE)' = podman ] && [ "$$(id -u)" != 0 ] && echo 0:0 || echo "$$(id -u):$$(id -g)")" \
	  $(HELLO_IMAGE) bash -c 'trap "chown -R \"$$OWNER\" /src/out" EXIT; \
	    rustup toolchain install && cargo build --manifest-path ui/hello/Cargo.toml && \
	    shopt -s globstar nullglob && qml=(ui/**/*.qml) && \
	    if (($${#qml[@]})); then /usr/lib/qt6/bin/qmllint -I out/hello-target/cxxqt/qml_modules "$${qml[@]}"; fi'
	@echo "hello: built in out/hello-target/debug/, qmllint clean"

# --- QEMU --------------------------------------------------------------------

run-uefi: ## Boot the ISO in QEMU with UEFI (OVMF)
	scripts/qemu-run.sh uefi

run-uefi-sb: ## Boot the ISO with UEFI + Secure Boot (Microsoft keys enrolled)
	scripts/qemu-run.sh uefi-sb

run-bios: ## Boot the ISO with legacy BIOS (SeaBIOS)
	scripts/qemu-run.sh bios

test-boot: ## Headless boot test in all three modes -> out/boot-times.json
	scripts/test-boot.sh uefi uefi-sb bios

test-boot-uefi: ## Headless boot test, UEFI only
	scripts/test-boot.sh uefi

test-boot-uefi-sb: ## Headless boot test, UEFI + Secure Boot only
	scripts/test-boot.sh uefi-sb

test-boot-bios: ## Headless boot test, legacy BIOS only
	scripts/test-boot.sh bios

# --- cleanup -----------------------------------------------------------------

# out/ and the live-build tree may hold root-owned files (rootful docker), so
# both are cleaned inside the build container when its image exists. `lb clean`
# keeps iso/cache/ (the package cache) and never touches tracked files.
clean: ## Remove out/ and live-build output (keeps iso/cache/)
	@if $(CONTAINER_LIB) 2>/dev/null && \
	    "$$CONTAINER_ENGINE" image inspect "$$LUGH_BUILD_IMAGE" >/dev/null 2>&1; then \
	  run_in_build_env --privileged -- bash -c \
	    'if [ -x iso/auto/clean ] || [ -d iso/.build ]; then (cd iso && lb clean); fi; rm -rf /src/out'; \
	else \
	  echo "clean: build image not found; removing out/ on the host only"; \
	  rm -rf out; \
	fi
