# Testing the desktop in a VM

`make test-desktop` (→ `scripts/test-desktop.sh`) boots the live ISO in QEMU
with UEFI, follows it from autologin to the desktop, drives it with the
keyboard, logs out to the sign-in screen and logs back in. It takes a
screenshot at every step and exits non-zero when a step fails.

```sh
make iso                 # debs -> repo -> out/lugh.iso
make test-desktop        # full run, ~2 min with KVM
make test-desktop ARGS="--gl off"     # the same on software rendering
```

Output:

| Path | What |
|---|---|
| `out/vm-shots/NN-*.png` | one screenshot per step (table below) |
| `out/vm-logs/serial.log` | serial console: boot log and the `LUGH-MARK` lines |
| `out/vm-logs/lugh-shell.log` | `journalctl --user -u lugh-shell` |
| `out/vm-logs/greeter.log` | `journalctl -u greetd` (greetd, cage, lugh-greeter) |
| `out/vm-logs/hyprland.log` | Hyprland's own log of the last session |
| `out/vm-logs/journal.log` | the whole journal of the boot |
| `out/vm-logs/numbers.txt` | boot and login times, shell RSS and idle CPU, memory |
| `out/vm-logs/system.txt` | failed units, sessions, `free -m`, package versions |

## The steps

| Shot | Action | Checked inside the guest |
|---|---|---|
| `01-desktop.png` | boot, greetd `initial_session` autologin | `LUGH-MARK: session-ready` on serial; user session active; `lugh-shell.service` active; `space.lugh.Shell1` on the bus; `lugh-dock` and `lugh-wallpaper` mapped, no `lugh-bar`; the monitor reserves a bottom strip; `hyprctl plugin list` has hyprbars when `lugh-hyprbars` is installed |
| `02-launcher.png` | Super+Space | `lugh-launcher` layer mapped |
| `03-launcher-results.png` | type `fire` | — (look at the picture), then Esc closes it |
| `04-controlcenter.png` | Super+C | `lugh-controlcenter` layer mapped, Esc unmaps it |
| `05-notifications.png` | Super+N | `lugh-notification-center` layer mapped |
| `06-toast.png` | `notify-send` in the guest | `lugh-notifications` layer mapped |
| `15-overview.png` | Super+Tab | `lugh-overview` layer mapped, Esc unmaps it |
| `16-workspace-2.png` | Super+Ctrl+Right, then Super+Ctrl+Left | `hyprctl activeworkspace` is 2, then 1 |
| `17-panel-focus.png`, `17b-panel-enter.png` | Super+B, then Enter | Enter on the focused start button maps `lugh-menu` |
| `07-lock.png` | Super+L | the session reports locked |
| `08-unlocked.png` | type the password, Enter | no longer locked |
| `11-foot.png` | Ctrl+Alt+T (`launch.sh`) | a foot window exists and sits in an `app-lugh-*.scope`; with hyprbars, `hyprctl decorations` lists a bar on it |
| `18-foot-maximized.png` | Super+Up | the window lies inside the monitor minus its reserved panel strip (and title bar room) |
| `19-foot-snapped.png` | Super+Up again, Super+Left | the same, for the left half |
| `20-huge-clamped.png` | `foot -W 400x150` | the oversized floating window was shrunk into the usable area |
| `12-firefox.png` | Super+Space, `fire`, Enter | a Firefox window in a scope; it draws its own frame (no hyprbars bar) |
| `21-files.png` | Super+E | a pcmanfm-qt (Qt 6) window, with a hyprbars bar |
| `13-osd-volume.png` | Volume Down twice | the sink volume changed |
| — | after the app steps | no QML warning (`*.qml:N` / `*.js:N` lines) in `lugh-shell`'s journal |
| — | `systemctl --user kill -s KILL lugh-shell` | the bar is back, foot survived |
| — | 10 s idle sample | `lugh-shell` CPU and RSS (reported, not asserted) |
| `09-greeter.png` | log out (`hl.dsp.exit()`) | `LUGH-MARK: greeter-ready` on serial; `cage` and `lugh-greeter` run as `_greetd` |
| `10-desktop-again.png` | type the password, Enter | a second `LUGH-MARK: session-ready`; `lugh-shell.service` active |

The live user is **`lugh`**, password **`live`** (live-config's default
password; `LIVE_PASSWORD` overrides what the test types).

## How the test reaches the guest

Three channels, all set up by `scripts/qemu-run.sh`:

1. **Serial console** (`--serial-log`). The kernel logs there
   (`console=ttyS0`), and in a test VM `lugh-test-markers.service` copies every
   journal line containing `LUGH-MARK` to it. `lugh-shell` writes
   `LUGH-MARK: session-ready` when its first frame is on screen; `lugh-greeter`
   writes `LUGH-MARK: greeter-ready` likewise. `LUGH-BOOT-OK` (the Phase 0 boot
   marker) is still printed at `multi-user.target`.
2. **QMP** (`--qmp SOCKET`): `screendump` for the screenshots and `send-key`
   for the keyboard. Keys go through the emulated keyboard, so they take the
   real path: Hyprland keybind → `busctl` → `space.lugh.Shell1`.
3. **The test agent** (`--test-agent SOCKET`): QEMU adds a virtio-serial port
   named `space.lugh.test`. A udev rule in the live image
   (`/etc/udev/rules.d/90-lugh-test.rules`) starts `lugh-test-agent.service`
   only when that port exists, so real hardware never runs it. The agent
   (`/usr/local/lib/lugh/test-agent`) reads one base64-encoded shell command
   per line, runs it as root and answers with the output and the exit status.
   Inside a command, `as-user '<cmd>'` runs `<cmd>` as the desktop user with
   their session bus, Wayland display and Hyprland instance.

`scripts/lib/vm.py` is the client for 2 and 3:

```sh
scripts/lib/vm.py --qmp out/vm/qmp.sock key meta_l-spc      # Super+Space
scripts/lib/vm.py --qmp out/vm/qmp.sock type 'fire'
scripts/lib/vm.py --qmp out/vm/qmp.sock shot /tmp/now.png
scripts/lib/vm.py --agent out/vm/agent.sock run 'systemctl status greetd'
scripts/lib/vm.py --agent out/vm/agent.sock run "as-user 'hyprctl layers'"
```

## Graphics in the VM

`qemu-run.sh --gl auto|on|off` (default `auto`, also `QEMU_GL`):

- **on**: `virtio-vga-gl` with virgl. The guest gets real OpenGL, rendered on
  a host DRM render node (`-display egl-headless,rendernode=…` when headless,
  `gtk,gl=on` in a window). The script picks an Intel or AMD render node
  first; `QEMU_RENDERNODE=/dev/dri/renderD12x` overrides it. Your user needs
  read/write access to the node (the `render` group, or a logind ACL).
- **off**: plain `virtio-vga`. The guest renders with llvmpipe. `lugh-session`
  sees the software renderer in Hyprland's log and switches to the low-power
  profile before the shell starts: no blur, shadows or compositor animations
  (`conf.d/low-power.lua`), and the shell draws opaque panels with reduced
  motion (`LUGH_LOW_POWER=1` → `Services.shell.lowPower`). `LUGH_LOW_POWER=0`
  in the session environment turns the detection off.
- **auto**: `on` when a render node is usable, else `off`.

Numbers measured with `--gl off` are software-rendering numbers; numbers with
`--gl on` depend on the host GPU. Neither is a real-hardware number.

## Iterating fast

An ISO build takes 10–20 minutes, so boot once and push changes into the
running VM:

```sh
scripts/test-desktop.sh --boot-only      # boots, waits for the desktop, leaves the VM up
vm() { scripts/lib/vm.py --qmp out/vm/qmp.sock --agent out/vm/agent.sock "$@"; }

# out/ is shared read-only with the guest over 9p (tag "lughshare"):
vm run 'mkdir -p /mnt/out && mount -t 9p -o trans=virtio,ro lughshare /mnt/out'

# new packages
make debs
vm run --timeout 300 'dpkg -i /mnt/out/debs/lugh-*.deb'
vm run "as-user 'systemctl --user restart lugh-shell'"     # the shell
vm run 'systemctl restart greetd'                           # the greeter (ends the session)

# only a Hyprland config change: copy it over and reload
vm run "as-user 'hyprctl reload config-only'"

scripts/test-desktop.sh --attach         # run the steps against the running VM
vm quit                                  # power it off
```

The live system runs from RAM (overlay on the squashfs), so everything pushed
this way is gone at the next boot; rebuild the ISO to confirm.

To look at it yourself: `make run-uefi` opens the same VM in a window
(`QEMU_GL=off make run-uefi` for software rendering).

## What this test does not cover

- Real hardware: Wi-Fi, Bluetooth, battery, brightness, suspend, real GPUs.
- Pointer input: every step is keyboard-driven.
- Motion: screenshots are stills.
- BIOS and Secure Boot: `make test-boot` covers booting in those modes.
