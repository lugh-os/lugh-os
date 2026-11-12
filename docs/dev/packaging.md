# Packaging: the Lugh .deb packages

Lugh OS is installed from its own Debian packages. `make debs` builds them into
`out/debs/`, `make repo` publishes them to the signed local apt repository the
ISO build consumes (`out/repo/`, see `scripts/repo-publish.sh`).

Sources: `packaging/<package>/debian/`, `scripts/build-debs.sh`,
`scripts/build-env/` (build container), `scripts/lib/container.sh`.

## 1. Package map

| Package | Arch | Ships |
|---|---|---|
| `lugh-branding` | all | os-release / issue / motd (diverted), GRUB theme, Plymouth theme, icons, logos → `/usr/share/lugh/branding/logo/`, wallpapers + `wallpapers.json` → `/usr/share/backgrounds/lugh/` |
| `lugh-ui` | all | the `Lugh.UI` QML module → `/usr/share/lugh/qml/Lugh/UI/`, Lucide font → `/usr/share/lugh/qml/fonts/lucide.ttf` |
| `lugh-shell` | amd64 | `/usr/bin/lugh-shell`, `/usr/share/lugh/qml/main.qml`, `/usr/share/lugh/qml/Lugh/Shell/`, `/usr/lib/systemd/user/lugh-session.target` + `lugh-shell.service`, `/usr/share/dbus-1/services/space.lugh.Shell1.service`, `/etc/pam.d/lugh-lock`, `/usr/share/lugh/launcher/aliases.toml` |
| `lugh-greeter` | amd64 | `/usr/bin/lugh-greeter`, `/usr/share/lugh/greeter/qml/`, `/usr/libexec/lugh/greeter-session`, `/etc/greetd/config.toml` (diverted), `tmpfiles.d` for `/run/lugh-greeter` and `/var/lib/lugh-greeter` |
| `lugh-session` | all | `/usr/bin/lugh-session`, `/usr/share/wayland-sessions/lugh.desktop`, `/usr/share/xdg-terminal-exec/lugh-xdg-terminals.list` (foot first), the Hyprland config → `/usr/share/lugh/hypr/` (`lugh.lua`, `conf.d/`, `lugh/`, `scripts/`), `/usr/share/xdg-desktop-portal/lugh-portals.conf`, the GTK/foot defaults → `/usr/share/lugh/xdg/` (first in `XDG_CONFIG_DIRS` inside the session), `/etc/chromium.d/lugh`, a gsettings override (`90_lugh-session.gschema.override`), `hyprland.md` in the doc dir |
| `lugh-hyprbars` | amd64 | the hyprbars plugin built for the archive's Hyprland → `/usr/lib/lugh/hyprland/hyprbars.so` + `hyprbars.hyprland-version` (source vendored in `packaging/lugh-hyprbars/src`, update steps in `src/README.Lugh`) |
| `lugh-desktop-minimal` | all | metapackage: the Minimal profile |

`/usr/share/lugh/qml` is one QML import root shared by three packages: the
shell loads `main.qml` from it and both binaries import `Lugh.UI` from it.
`IconNames.qml` finds the font at `../../../fonts/lucide.ttf` relative to
`Lugh/UI/icons/`, so that relative layout must stay. Demos, the gallery, the
preview harness and the generator scripts (`*.py`) are not installed.

All packages carry the same version: `<VERSION>.<patch>` (`0.0` → `0.0.1`).
`lugh-shell` and `lugh-greeter` depend on exactly their own version of
`lugh-ui`, because the QML API is not stable yet.

## 2. Dependencies and why

**lugh-ui**: the QML modules its code and its users import
(`qml6-module-qtquick`, `-qtquick-controls` (for `QtQuick.Controls.impl`),
`-qtquick-templates`, `-qtquick-layouts`, `-qtquick-shapes`, `-qtquick-window`,
`-qtqml`, `-qtqml-models`, `-qtqml-workerscript`), `qt6-svg-plugins` (SVG
icons and logos), `fonts-inter` and `fonts-jetbrains-mono` (the theme's type).

**lugh-shell**: Qt libraries and libpam through `${shlibs:Depends}`;
`layer-shell-qt` + `qml6-module-org-kde-layershell` (the panel and the
overlays are layer surfaces), `qml6-module-qtcore` (`ShellSettings` uses
`QtCore.Settings`), `qt6-wayland`; `pulseaudio-utils` (`pactl`), `pipewire-pulse`,
`wireplumber` (sound); `network-manager` (Wi-Fi); `upower` (battery);
`papirus-icon-theme` (default app icons), `adwaita-icon-theme` (fallback,
cursor); `wl-clipboard`, `grim`, `slurp` (clipboard, screenshots);
`xdg-utils`, `dbus-user-session`. Recommends: `bluez`,
`power-profiles-daemon` (their control-center tiles hide when the service is
missing), `qml6-module-qtwebsockets` (only the development backend
`WsBackend.qml` imports it).

**lugh-greeter**: `greetd`, `cage` (kiosk compositor), `tuigreet` (fallback),
`qml6-module-qtquick-effects`, `qt6-wayland`, `lugh-ui`, `lugh-branding`
(lockup logo, blurred wallpaper), `adduser`.

**lugh-session**: `hyprland (>= 0.55)` and `xdg-desktop-portal-hyprland`, both
from **trixie-backports** (Hyprland is not in trixie itself);
`xdg-desktop-portal`, `xdg-desktop-portal-gtk`, `gnome-keyring` (portals,
ADR-020); `systemd`, `dbus-bin`, `dbus-user-session` (session start, D-Bus
calls from keybinds, scopes); `wireplumber`, `pipewire-pulse`, `brightnessctl`,
`playerctl` (media keys); `polkitd`, `pkexec`; `xdg-terminal-exec`, `foot`;
`qt6-wayland (>= 6.8)` (its Adwaita decoration plugin), `adwaita-icon-theme`;
`dconf-gsettings-backend`, `gsettings-desktop-schemas` (GTK button layout and
dark mode through the Settings portal); `lugh-shell`. Recommends:
`hyprland-guiutils` (backports; "app not responding" dialog),
`libpam-gnome-keyring`, `lugh-hyprbars` (title bars, see below),
`pcmanfm-qt`, `xwayland`, `fonts-inter`.

**lugh-hyprbars**: `hyprland (= <the exact version it was built against>)`,
because Hyprland plugins must match the compositor build (no stable ABI).
`debian/rules` checks after the build that every symbol the plugin needs
exists in that Hyprland and its libraries, and fails otherwise. Built
against `hyprland-dev` from trixie-backports, which the build container
installs. **When backports moves Hyprland, rebuild this package**: until
then apt holds Hyprland back, and the ISO build fails on the unsatisfiable
dependency. `lugh/titlebars.lua` also refuses to load a plugin whose
`.hyprland-version` stamp differs from the running Hyprland.

**lugh-desktop-minimal**: the four Lugh packages above, `firefox` (from
`packages.mozilla.org`, as configured in `iso/config/archives/mozilla.*`),
`foot`, `pcmanfm-qt`, `vlc`, fonts (Inter, JetBrains Mono, Noto, Noto Color
Emoji), `pipewire`, `pipewire-audio`, `pipewire-pulse`, `wireplumber`,
`network-manager`. No office suite, no store.

A system that installs these needs three apt sources besides trixie: the Lugh
repo, trixie-backports, and the Mozilla repo.

## 3. The greeter and greetd

`/etc/greetd/config.toml` is a conffile of `greetd`. `lugh-greeter` does not
overwrite it: like `lugh-branding` does for os-release, it ships
`/etc/greetd/config.toml.lugh` and config-package-dev diverts Debian's file
to `config.toml.lugh-orig` and links `config.toml` to ours. Removing the
package restores Debian's file.

greetd runs `/usr/libexec/lugh/greeter-session` as `_greetd` on VT 7. greetd
passes no environment, so the wrapper sets it: `XKB_DEFAULT_*` from
`/etc/default/keyboard`, `XCURSOR_THEME=Adwaita`, `QT_QPA_PLATFORM=wayland`.
It then sources **`/etc/lugh/greeter-session.env`** if present (plain
`VAR=value` lines; the live ISO can set `WLR_RENDERER_ALLOW_SOFTWARE=1` there)
and runs `cage -s -- lugh-greeter` through `systemd-cat`, so the output of
cage and the greeter is in the journal (`journalctl -t lugh-greeter`); greetd
itself does not keep it.

Fallback: each non-zero exit of cage/lugh-greeter adds one to
`/run/lugh-greeter/failures`; a successful login removes the file. From the
third failure on the wrapper starts `tuigreet` (same session, `lugh-session`)
instead. The counter lives in `/run`, so a reboot tries the graphical greeter
again.

Nothing needs `systemctl enable` from our side: Debian's `greetd` package
enables `greetd.service`, and `lugh-session.target` pulls the shell in.

## 4. Building

```sh
make debs                      # every package -> out/debs/
make debs PKGS="lugh-ui lugh-session"   # only these
make repo                      # publish out/debs to out/repo (signed)
make shell greeter             # only the two binaries -> out/bin/
```

`scripts/build-debs.sh` runs in the build container
(`localhost/lugh-build-env:trixie`, `scripts/build-env/Containerfile`). For
each package it assembles `out/build/<pkg>/`:

1. `debian/` is copied from `packaging/<pkg>/debian/`.
2. Every path in **`debian/lugh-sources`** is copied from the repo to the same
   relative path. One repo-relative file or directory per line, `#` comments.
   So `debian/install` reads like the repo layout
   (`ui/shell/session/lugh.desktop usr/share/wayland-sessions/`).
3. The top `debian/changelog` entry is restamped with the version
   (`LUGH_DEB_PATCH`, or `LUGH_DEB_VERSION` for the whole string).
4. `dpkg-buildpackage -us -uc -b`, then lintian (the build fails on lintian
   errors only; the log is `out/build/<pkg>.result/lintian.log`).

### The two Rust binaries

`lugh-shell` and `lugh-greeter` are Rust + cxx-qt. Their `debian/rules` call
`scripts/build-env/cargo-deb-build.sh`, which builds from the **checkout**
(not from a copy, so cargo's incremental state stays valid):

- **Reuse**: if `out/bin/<name>` exists and none of its inputs is newer
  (the crate's `src/`, `cpp/`, `build.rs`, `Cargo.toml`, `Cargo.lock`,
  `qml/backend/`, plus `crates/` and `rust-toolchain.toml`), it is packaged as
  is. `make shell` / `make greeter` build it with the same commands, on the
  same trixie Qt. `LUGH_FORCE_CARGO=1 make debs` always compiles.
- **Build**: `rustup toolchain install` (version from `rust-toolchain.toml`),
  then `cargo build --release --locked --manifest-path ui/<x>/Cargo.toml` with
  `CARGO_TARGET_DIR=out/shell-target` / `out/greeter-target`, the directories
  `scripts/build-shell.sh` and `scripts/build-greeter.sh` use. `lugh-shell`
  always has the `pam` feature of `lugh-shell-core` (set in
  `ui/shell/Cargo.toml`).

Caches: the toolchain and the crate registry live in the named volumes
`lugh-hello-rustup` and `lugh-hello-cargo` (mounted by
`scripts/lib/container.sh`, shared with `make hello`); cargo's target
directories are under `out/`. A release tarball must be built with
`LUGH_FORCE_CARGO=1` from a clean tree.

The image carries rustup but no toolchain, the Qt 6 dev packages, `cmake`,
`pkg-config`, `libpam0g-dev`.

## 5. Offline builds

Today the build needs the network twice: rustup downloads the toolchain once
(into the volume) and cargo downloads crates once (into the volume). After
that a rebuild works without network as long as the lock files don't change.

A fully offline, reproducible build (needed for a Debian-style source package
and for CI without network) works like this:

1. `cargo vendor --manifest-path ui/shell/Cargo.toml --sync ui/greeter/Cargo.toml vendor/`
   writes every crate into `vendor/` and prints the `[source]` replacement to
   put in `.cargo/config.toml` (`replace-with = "vendored-sources"`).
2. Ship `vendor/` in the source tarball (or as a separate `lugh-rust-vendor`
   tarball), and bake the Rust toolchain into the build image instead of the
   volume (`rustup toolchain install` in the Containerfile).
3. Build with `LUGH_CARGO_OFFLINE=1 make debs`: `cargo-deb-build.sh` then
   skips rustup and passes `--offline` to cargo.

Step 3 is implemented; steps 1 and 2 are not done yet (no `vendor/` in the
repo).

## 6. Checking the result

In a clean `debian:trixie` container with trixie-backports and the Mozilla
repo enabled:

```sh
apt-get install -y ./out/debs/*.deb
dbus-run-session -- lugh-shell --check
QT_QPA_PLATFORM=offscreen lugh-greeter --check
systemd-analyze --user verify /usr/lib/systemd/user/lugh-session.target /usr/lib/systemd/user/lugh-shell.service
desktop-file-validate /usr/share/wayland-sessions/lugh.desktop
Hyprland --verify-config --config /usr/share/lugh/hypr/lugh.lua   # as a non-root user
```
