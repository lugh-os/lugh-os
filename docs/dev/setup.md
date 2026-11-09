# Developer setup

How to set up a machine to build the Lugh ISO, boot it in QEMU and run the
checks CI runs. The reference host is **KDE neon** (the founder's machine);
any recent Linux with a container engine and QEMU works.

The rule: **everything that builds Lugh runs inside a Debian 13 "trixie"
container**. KDE neon and Ubuntu ship Ubuntu-patched `live-build` and
`debootstrap` that don't match Debian's, so the host only runs `make`, a
container engine and QEMU. The container image (`localhost/lugh-build-env:trixie`)
is built from `scripts/build-env/Containerfile` on first use and rebuilt
automatically when that file changes.

## 1. Host packages

### KDE neon (reference) and Ubuntu 24.04+

```sh
sudo apt install live-build debootstrap qemu-system-x86 qemu-utils ovmf xorriso mtools dosfstools squashfs-tools podman make git
```

`live-build` and `debootstrap` on the host are optional (the build uses the
container's copies); they are listed so you can poke at `iso/` by hand. The
packages you really need are `make git podman qemu-system-x86 qemu-utils ovmf`.

For `make check` you also need Rust via [rustup](https://rustup.rs); the
version is pinned in `rust-toolchain.toml` and rustup installs it on first use:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Debian 13

Same package list as above. Debian's own `live-build` would work on the host,
but use the container anyway so your build matches CI.

### Fedora

```sh
sudo dnf install podman make git qemu-system-x86 edk2-ovmf
```

OVMF lives in `/usr/share/edk2/ovmf/`; `scripts/qemu-run.sh` finds it there.

### Arch

```sh
sudo pacman -S podman make git qemu-desktop edk2-ovmf
```

Arch's `edk2-ovmf` has no VARS file with Microsoft keys enrolled, so
`make run-uefi-sb` needs one from elsewhere: point `OVMF_VARS_MS_TEMPLATE` at
it (and `OVMF_CODE_SB` at the secure-boot CODE file if the name differs).

### Firmware lookup

`scripts/qemu-run.sh` looks for OVMF in `/usr/share/OVMF`, `/usr/share/ovmf`,
`/usr/share/edk2/ovmf`, `/usr/share/edk2/x64`, `/usr/share/edk2-ovmf/x64` and
`/usr/share/qemu`. Override with:

| Variable | Default file (Debian/Ubuntu) |
|---|---|
| `OVMF_CODE` | `OVMF_CODE_4M.fd` |
| `OVMF_VARS_TEMPLATE` | `OVMF_VARS_4M.fd` |
| `OVMF_CODE_SB` | `OVMF_CODE_4M.secboot.fd` |
| `OVMF_VARS_MS_TEMPLATE` | `OVMF_VARS_4M.ms.fd` (Microsoft keys enrolled) |

The VARS templates are copied to `out/OVMF_VARS.fd` and `out/OVMF_VARS.ms.fd`
on first run, so firmware settings (boot order, enrolled keys) persist between
runs. Delete those files to reset the firmware.

## 2. Podman or docker

The build scripts (via `scripts/lib/container.sh`) use **podman if it is
installed, otherwise docker**. Force one with `CONTAINER_ENGINE`:

```sh
make iso CONTAINER_ENGINE=docker
```

- **Podman (preferred on dev hosts).** Daemonless and rootless for the package
  and repo steps. The ISO build runs `lb build` in a `--privileged` container;
  live-build needs real root for `debootstrap` (device nodes, mounts). If
  rootless podman fails there with `mknod`/`mount` permission errors, run the
  ISO step with root podman: `sudo make iso` keeps everything in one engine, or
  use docker.
- **Docker.** Rootful by default, so privileged builds just work. You need to
  be in the `docker` group (`sudo usermod -aG docker $USER`, then log in
  again). Files the container writes to the checkout are chowned back to you
  when it exits, so `out/` stays yours.
- **CI** uses docker (`CONTAINER_ENGINE=docker` in `iso.yml`), because the
  runner's docker is rootful.

`make build-env` builds or refreshes the image without building anything else.

## 3. Make targets

Run `make` or `make help` for the list. Outputs go to `out/` (git-ignored).

| Target | What it does |
|---|---|
| `make help` | Lists the targets (default goal). |
| `make debs` | `scripts/build-debs.sh`: builds every `packaging/<pkg>/debian/` package in the container → `out/debs/*.deb` (runs lintian). |
| `make repo` | `scripts/repo-publish.sh`: publishes `out/debs/` with aptly as a signed apt repo → `out/repo/` (+ `out/repo/lugh.asc`). Signs with `LUGH_REPO_GPG_KEY` if set, else a throwaway dev key with a loud warning (see [signing](signing.md)). |
| `make iso` | Runs `debs` and `repo`, then `scripts/build-iso.sh`: `lb build` in the privileged container → `out/lugh-<VERSION>-amd64.iso`, its `.sha256`, and the symlink `out/lugh.iso`. |
| `make brand-assets` | `scripts/render-brand-assets.sh`: re-renders the logo PNGs from the SVG sources. |
| `make build-env` | Builds or refreshes the `localhost/lugh-build-env:trixie` image. |
| `make check` | On the host: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` (the CI `rust` job). |
| `make hello` | Builds the cxx-qt hello app (`ui/hello/`) in a trixie + Qt 6 container (`tests/toolchain/Containerfile`) → `out/hello-target/` (the CI `hello` job). |
| `make run-uefi` | Boots the ISO in QEMU: q35, OVMF, KVM. Serial console on your terminal (`Ctrl-a x` quits, `Ctrl-a c` toggles the QEMU monitor). |
| `make run-uefi-sb` | Same with Secure Boot on: `OVMF_CODE_4M.secboot.fd`, Microsoft keys enrolled, SMM. The ISO must boot through Debian's signed shim → GRUB → kernel. |
| `make run-bios` | Same with legacy BIOS (`-machine pc`, SeaBIOS). |
| `make test-boot` | Headless boot in all three modes; waits for `LUGH-BOOT-OK` on the serial console (180 s with KVM, 600 s without). Writes `out/serial-<mode>.log` and `out/boot-times.json`, prints a table, fails if any mode fails. See [tests/boot](../../tests/boot/README.md). |
| `make test-boot-uefi` / `-uefi-sb` / `-bios` | One mode only. |
| `make clean` | Removes `out/` and runs `lb clean` in `iso/` (inside the container, since those files can be root-owned). Keeps `iso/cache/`, so the next build doesn't re-download every package. Never touches tracked files. Note that it also removes the throwaway dev signing key in `out/`. |

Useful variables: `ISO=path/to.iso` (default `out/lugh.iso`) for the run and
test targets, `QEMU_MEM` / `QEMU_SMP` (default `4G` / `4`), `QEMU_ACCEL=tcg` to
force software emulation, `QEMU_EXTRA="..."` for extra QEMU arguments, and
`BOOT_TIMEOUT=<seconds>` for `test-boot`.

A full first build:

```sh
git clone <repo> lugh-os && cd lugh-os
make iso          # ~10–30 min the first time, mostly package downloads
make run-uefi     # look at it
make test-boot    # what CI runs
```

## 4. CI

- `.github/workflows/ci.yml` (every push and PR): `rust` (fmt, clippy, test),
  `hello` (builds `ui/hello` in `debian:trixie`, then `qmllint` on
  `ui/**/*.qml`) and `shellcheck` (`scripts/**/*.sh`, `iso/auto/*`).
- `.github/workflows/iso.yml` (every push and PR): `make debs repo iso` with the
  `LUGH_REPO_GPG_KEY` secret, uploads the ISO + `.sha256` (kept 7 days for PRs,
  30 for main), runs `make test-boot` with KVM, and writes ISO size, build time
  and boot times to the job summary. It fails if the ISO is over 1.2 GB.
  Serial logs are uploaded when the job fails.

## 5. Troubleshooting

**`/dev/kvm` permission denied / "falling back to TCG".** Add yourself to the
`kvm` group and log in again:

```sh
sudo usermod -aG kvm "$USER"
ls -l /dev/kvm        # crw-rw---- root kvm
```

If `/dev/kvm` doesn't exist, enable virtualization (VT-x / AMD-V) in the
firmware setup, or load the module (`sudo modprobe kvm_intel` or `kvm_amd`).
Without KVM everything still works under TCG, just 5–10× slower.

**`lb build` fails with `mknod`, `mount` or "Operation not permitted".** The
build container isn't really privileged. With rootless podman, rerun with
`sudo` or `CONTAINER_ENGINE=docker`. Inside nested containers (toolbox,
distrobox, a CI job already in a container) privileged builds generally don't
work; build on the host.

**Disk space.** A build needs about **10 GB** free: the live-build chroot,
the squashfs, the ISO, the package cache in `iso/cache/` and the container
image. `make clean` frees all but the cache; `podman system prune` /
`docker system prune` frees old images. `make hello` adds about 3 GB more
(the `localhost/lugh-hello-env` image, the `lugh-hello-rustup` and
`lugh-hello-cargo` volumes, and `out/hello-target/`); remove them with
`docker volume rm lugh-hello-rustup lugh-hello-cargo` and
`docker rmi $(docker images -q localhost/lugh-hello-env)` (or the podman
equivalents) when you're done.

**Stale live-build state** (odd errors after changing `iso/config/`): run
`make clean` and build again.

**`make run-uefi-sb` stops at "Access Denied" or a security violation.**
Something in the boot chain isn't signed by a key in the enrolled VARS. Make
sure you are booting a fresh ISO and that `out/OVMF_VARS.ms.fd` came from
`OVMF_VARS_4M.ms.fd` (delete it to re-copy). Lugh relies on Debian's signed
shim, GRUB and kernel only; we hold no Secure Boot keys.

**The boot test times out but the VM looks fine.** Check
`out/serial-<mode>.log`: the marker needs `console=ttyS0` on the kernel
command line and `lugh-boot-marker.service` enabled in the image.

**Files in the checkout owned by root.** Something ran the container without
the chown-back wrapper. Fix with `sudo chown -R "$USER": out iso` and use the
make targets.
