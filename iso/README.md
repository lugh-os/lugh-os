# iso/ — live-build config for the Lugh live ISO

Build with `make iso` (runs `scripts/build-iso.sh`), never with the host's
live-build: the build runs in the Debian trixie container
(`scripts/build-env/Containerfile`), in a copy of this directory. Only
`iso/cache/` (downloaded .debs, gitignored) is shared with the host.

| Path | What |
|---|---|
| `auto/config` | the `lb config` call (trixie, `main contrib non-free non-free-firmware`, grub-efi + syslinux, Secure Boot, live user `lugh`, serial console) |
| `config/package-lists/*.list.chroot` | base, firmware, network, audio, storage, browser, live, lugh (`lugh-branding`, `lugh-desktop-minimal`), desktop (Mesa, XWayland, BlueZ, …) |
| `config/archives/` | backports with `backports.pref.*` (only the Hyprland stack is pinned to backports), `lean.pref.chroot` (build-time block list: no LXQt session through Recommends), Mozilla (build-time list, key, pin) and the local Lugh repo (`http://127.0.0.1:8099`, served from `out/repo/` during the build) |
| `config/hooks/normal/` | `0100-lugh-branding` (Plymouth theme + initramfs), `0200-lugh-boot-marker`, `0300-lugh-desktop` (greetd is the only display manager, graphical target), `9990-lugh-first-boot` (no `ldconfig.service` run at every live boot) |
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

## The desktop on the live image

- **Autologin:** `includes.chroot/etc/greetd/lugh-live.toml` adds an
  `initial_session` (`lugh-session` as user `lugh`); a drop-in for
  `greetd.service` points greetd at it. Logging out shows `lugh-greeter`.
  Live user **`lugh`**, password **`live`** (live-config's default).
- **Software rendering:** `/etc/lugh/greeter-session.env` sets
  `WLR_RENDERER_ALLOW_SOFTWARE=1` for cage; `lugh-session` switches the
  session to low power when Hyprland renders with llvmpipe.
- **Dock pins:** `/etc/skel/.config/lugh/desktop.toml`.
- **hyprsunset:** its own user unit is masked (`/etc/systemd/user/`); the
  shell starts hyprsunset itself for Night Light.
- **Test mode:** `90-lugh-test.rules`, `lugh-test-agent.service`,
  `lugh-test-markers.service` and `/usr/local/lib/lugh/test-agent` only do
  something when QEMU offers the virtio-serial port `space.lugh.test`
  (`scripts/qemu-run.sh --test-agent`). See
  [docs/dev/testing-desktop.md](../docs/dev/testing-desktop.md).
