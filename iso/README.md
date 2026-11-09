# iso/ — live-build config for the Lugh live ISO

Build with `make iso` (runs `scripts/build-iso.sh`), never with the host's
live-build: the build runs in the Debian trixie container
(`scripts/build-env/Containerfile`), in a copy of this directory. Only
`iso/cache/` (downloaded .debs, gitignored) is shared with the host.

| Path | What |
|---|---|
| `auto/config` | the `lb config` call (trixie, `main contrib non-free non-free-firmware`, grub-efi + syslinux, Secure Boot, live user `lugh`, serial console) |
| `config/package-lists/*.list.chroot` | base, firmware, network, audio, storage, browser, live, lugh |
| `config/archives/` | backports, Mozilla (build-time list, key, pin) and the local Lugh repo (`http://127.0.0.1:8099`, served from `out/repo/` during the build) |
| `config/hooks/normal/` | `0100-lugh-branding` (Plymouth theme + initramfs), `0200-lugh-boot-marker` |
| `config/includes.chroot/` | apt keyrings, Mozilla pin, the image's signed-by Mozilla source (`sources.list.d/mozilla.sources`), `lugh-boot-marker.service` |
| `config/bootloaders/` | GRUB (UEFI) and ISOLINUX (BIOS) menus in Lugh colours, `splash.svg` |

Staged by `scripts/build-iso.sh` before each build (gitignored, don't edit):

- `config/archives/lugh.key.chroot` ← `out/repo/lugh.asc`
- `config/includes.chroot/etc/apt/keyrings/lugh.asc` ← `out/repo/lugh.asc`
- `config/bootloaders/grub-pc/live-theme/` ← `branding/grub/`

The Mozilla key in `config/archives/mozilla.key.chroot` (and its copy in
`includes.chroot/etc/apt/keyrings/packages.mozilla.org.asc`) is
<https://packages.mozilla.org/apt/repo-signing-key.gpg>, fingerprint
`35BA A0B3 3E9E B396 F59C A838 C0BA 5CE6 DC63 15A3`.
