# Lugh 0.0 "Desktop v0" — Phase 1 status note

> Date: 2026-11-10 · Phase doc: [phase-1-desktop-v0](../phases/phase-1-desktop-v0.md) · Status: **the live ISO boots to a working Lugh desktop in a VM; Phase 1 is not complete** (no installer, no Welcome app, nothing verified on real hardware yet)

## What works

`make iso` builds a live ISO that boots straight into the Lugh desktop, built
from Lugh's own Debian packages.

- **Packages** (`packaging/`, [packaging.md](../dev/packaging.md)): `lugh-ui`,
  `lugh-shell`, `lugh-greeter`, `lugh-session`, `lugh-branding` and the
  metapackage `lugh-desktop-minimal` (Firefox, foot, Files (pcmanfm-qt), VLC,
  fonts, PipeWire, NetworkManager). All six build with `make debs`, with no
  lintian errors, and install on a clean Debian trixie with trixie-backports.
- **Compositor:** Hyprland 0.55.2 from trixie-backports. Only the Hyprland
  stack is pinned to backports (`iso/config/archives/backports.pref.*`).
- **Sign-in:** greetd runs `lugh-greeter` inside cage. On the live image the
  first session logs the live user in automatically; logging out shows the
  sign-in screen, and the password logs back in.
- **Shell:** the three top islands, the dock, the launcher (Super+Space), the
  control center (Super+C), the calendar and notification center (Super+N),
  notification toasts (`notify-send`), the volume OSD in the centre island and
  the lock screen (Super+L, PAM). Keybinds reach the shell over D-Bus
  (`space.lugh.Shell1`).
- **Apps** start from the dock, the launcher and keybinds in their own
  `app-lugh-*.scope` systemd units (Firefox and foot checked).
- **Crash recovery:** `lugh-shell` is restarted by systemd after `SIGKILL`;
  open apps keep running, and a locked session comes back locked.
- **Weak and virtual GPUs:** when Hyprland renders in software (llvmpipe) the
  session switches itself to low power: no blur, shadows or compositor
  animations, opaque panels, reduced motion.

## Try it

```sh
make iso            # debs -> signed local repo -> out/lugh-0.0-amd64.iso
make run-uefi       # boot it in a QEMU window (QEMU_GL=off for software rendering)
make test-desktop   # the automated run: screenshots in out/vm-shots/
```

Live user: **`lugh`**, password: **`live`** (passwordless `sudo` on the live
image). The ISO also boots from a USB stick (`dd` or any image writer);
nothing is installed to disk, because there is no installer yet.

## Verified in the VM

`scripts/test-desktop.sh` ([testing-desktop.md](../dev/testing-desktop.md)),
QEMU 8.2 with KVM, UEFI, 4 GB RAM, 4 vCPUs, 1280×800, on the final ISO from a
cold boot. All 29 steps pass in both graphics modes:

| Step | virgl (host Intel UHD 630) | llvmpipe (software) |
|---|---|---|
| Boot to desktop through autologin | pass | pass |
| User session, `lugh-shell.service`, `space.lugh.Shell1`, bar/dock/wallpaper layers | pass | pass |
| Super+Space launcher, typing `fire` finds Firefox, Esc closes | pass | pass |
| Super+C control center, Esc closes | pass | pass |
| Super+N calendar + notifications | pass | pass |
| `notify-send` shows a toast | pass | pass |
| Super+L locks; `SIGKILL` of the shell while locked comes back locked | pass | pass |
| Wrong password stays locked ("Wrong password. Try again."); right password unlocks | pass | pass |
| Ctrl+Alt+T opens foot in an `app-lugh-*` scope | pass | pass |
| Launcher + Enter starts Firefox in an `app-lugh-*` scope | pass | pass |
| Volume key changes the volume (40 % → 30 %) and shows the OSD | pass | pass |
| `SIGKILL` of the shell: it comes back, foot and Firefox keep running | pass | pass |
| No QML errors in the shell's journal | pass | pass |
| Log out shows `lugh-greeter` (cage, user `_greetd`) | pass | pass |
| Typing the password at the greeter logs in again | pass | pass |

Screenshots: `out/vm-shots/` (virgl) and `out/vm-shots-software/` (llvmpipe).
`make test-boot` also passes: the ISO boots under UEFI (20.2 s), UEFI with
Secure Boot (18.7 s) and legacy BIOS (28.3 s) to `LUGH-BOOT-OK`.

## Measured numbers

**All of these are VM numbers.** The "virgl" column uses the host's Intel GPU
through virtio-gpu; the "llvmpipe" column is software rendering. None is a
real-hardware number.

| Metric | Budget (phase doc) | virgl | llvmpipe | Verdict |
|---|---|---|---|---|
| ISO size | ≤ 2.5 GB | 1,426,063,360 bytes (1.43 GB) | same | within budget |
| QEMU start → shell's first frame (live ISO, cold, includes firmware, the 5 s GRUB menu and reading the squashfs from the virtual CD) | — (≤ 15 s to the greeter is for an installed system on NVMe) | 44–51 s | 40–54 s | not comparable; of this, kernel + userspace to `graphical.target` is 15–17 s |
| Greeter: Enter → shell's first frame | ≤ 2 s | 2.7–3.3 s | 3.2–3.9 s | **over budget** in the VM |
| `lugh-shell` start → first frame, warm | — | 0.7 s | 1.4 s | |
| `lugh-shell` RSS at idle | ≤ 150 MB | 167–171 MB (anon ~62, file ~105) | 291–310 MB | **over budget** |
| `lugh-shell` CPU at idle, 10 s sample | ~0 % | 0.0–0.2 % | 0.0–0.2 % | fine |
| Memory used after login, no apps (`free -m`, whole VM) | ≤ 600 MB | 649–657 MB | 766–783 MB | **over budget** |
| Shell killed → new first frame | < 1 s | 1.2–1.6 s | 1.3–1.9 s | **over budget** in the VM |
| Hyprland RSS | — | 142 MB | 239 MB | |

Notes on the misses:

- **Shell RSS:** 105 MB of the 170 MB is shared library mapping (Qt, Mesa).
  Whether the budget means RSS or private memory is still open
  ([shell-performance.md](../dev/shell-performance.md)).
- **Shell restart:** 200 ms is systemd's `RestartSec`, the rest is process
  start to first frame with two apps open. It needs measuring on real hardware.
- **Software rendering memory:** llvmpipe keeps textures in the shell's own
  memory. `lugh-session` therefore lifts `lugh-shell.service`'s
  `MemoryHigh=300M` for such a login; with the limit in place the shell was
  throttled to a standstill as soon as an overlay opened.

## Not verified

- **Real hardware: nothing.** Wi-Fi, Bluetooth, battery, brightness keys,
  suspend/resume, touchpad gestures, HiDPI, multiple monitors, NVIDIA and AMD
  GPUs were not tried. The Rust services for them were exercised read-only on
  the development host in earlier work; their write paths (connecting to a
  network, pairing, switching power profile) were never run against real
  devices.
- **Pointer input** in the VM: every test step uses the keyboard.
- **Motion:** only stills were captured in the VM; the liquid motion was
  reviewed on the host (`scripts/shell-motion.sh`).
- **Screen readers**, large text, high contrast.
- **Podman** as the container engine (only Docker was used).
- **CI:** the workflows have not run on GitHub.

## Known limitations

- **Lock screen security (ADR-029).** The lock is the shell's own overlay
  surface with PAM, not `ext-session-lock-v1`. When the shell crashes while
  locked, the desktop is visible until systemd restarts it (1.2–1.9 s in the
  VM) and it comes back locked. Do not rely on it against someone with access
  to the machine.
- **No idle auto-lock** and no lock on suspend: there is no idle helper yet
  (`hypridle` or an `ext-idle-notify` client in the shell).
- **No polkit agent.** `pkexec` fails in the session ("no authentication
  agent"); actions that need authorization do not prompt.
- **No tray**, no Settings app, no Welcome app, no Store. The overview
  (Super+Tab) was not tested.
- **No installer.** Calamares, the four profiles, the Btrfs layout with
  snapper and LUKS are not started; acceptance criteria 7–9 are open.
- **Files is pcmanfm-qt** and pulls a few LXQt libraries (`lxqt-sudo`,
  `liblxqt`); the LXQt session itself is kept out of the image.
- **Sign-in screen sessions:** the greeter also lists Hyprland's own
  `hyprland.desktop` and `hyprland-uwsm.desktop`; picking them gives a bare
  Hyprland without Lugh's configuration.
- **Toasts show the title only**; the body is in the notification center.
- **Firefox first window** opens small (floating at the size it asks for).
- **Night Light** needs `hyprsunset` (installed); it was not tried.
- **Plymouth → desktop:** the VM shows a text login prompt on tty1 as well
  (live-config's console autologin); the desktop is on tty7.
- **`lugh-shell --check`** exits 1 with "1 warning" in a clean trixie
  container. The only warning in its output is Qt's non-UTF-8 locale warning;
  it was not re-run with a UTF-8 locale.
- **Dev signing key:** the ISO's Lugh apt source points at the build-time
  repo (`127.0.0.1:8099`) signed with a throwaway key. Never publish this ISO.

## Acceptance criteria (phase doc)

| # | Criterion | State |
|---|---|---|
| 1 | ISO boots to the greeter; live session autologins to the desktop | **met in QEMU under UEFI** (desktop test); UEFI+SB and BIOS boot to `LUGH-BOOT-OK`, the desktop itself was only driven under UEFI |
| 2 | Shell surfaces work by keyboard and mouse | keyboard: met for launcher, control center, notifications, lock; mouse: not tested in the VM |
| 3 | `notify-send` shows a toast, history, DND | toast met; history and DND not checked in the VM |
| 4 | Wi-Fi, Bluetooth, volume, brightness, power profile on a real laptop | **open** (no real hardware) |
| 5 | Every launched app is its own `app-lugh-*` scope | met for foot and Firefox |
| 6 | polkit dialog | **open** (no agent) |
| 7–9 | Calamares, Btrfs/snapper, LUKS | **open** |
| 10 | Minimal profile has no office suite, store or games | met: no `libreoffice` in the ISO's package manifest; Firefox and VLC are present |
| 11 | Welcome app, live theme changes | **open** |
| 12 | WCAG AA contrast | met: `scripts/check-contrast.py` 450/450 required pairs (28 advisory rows below threshold, focus ring on wallpaper) |
| 13 | Killing the shell restarts it in under 1 s, apps unaffected | apps unaffected: met; time: 1.2–1.9 s in the VM, **over** |

## Next steps

1. Run the ISO on real laptops (Intel, AMD, NVIDIA) and go through criterion 4.
2. `ext-session-lock-v1` for the lock screen, and an idle helper.
3. A polkit agent in the shell.
4. Bring shell start-up and RSS under budget on the target (pre-compiled QML,
   shader cache; see shell-performance.md).
5. The installer (Calamares) and the Welcome app.
