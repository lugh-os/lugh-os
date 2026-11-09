# Phase 4 — Shield (quarantine)

> Status: Draft · Size: L · Depends on: Phase 3 (Store, Bridge, app scopes) · Specs: [../specs/shield.md](../specs/shield.md), [../specs/bridge.md](../specs/bridge.md), [../specs/tasks.md](../specs/tasks.md) · ADRs: ADR-015, ADR-017

## Goal

Any app, file, folder or Windows `.exe` can be opened in quarantine with one click. A running app can be frozen, cut off from the network, limited or killed from the shell or from Lugh Tasks. Files that a quarantined app changes can be reviewed, kept or discarded.

## Scope

**In**
- `lugh-shieldd` user daemon (session bus, `space.lugh.Shield1`) and the `lugh shield` CLI.
- Sandbox profiles `strict`, `standard` and `net`, built on bubblewrap, Landlock, seccomp, overlayfs, pasta or an empty netns, and systemd scopes.
- Throwaway write layer for each session, with a **Review changes** UI (keep, discard, or keep some).
- **Open in Quarantine** entry points: file manager context menu, launcher (Alt+Enter), shell/dock right-click, Store, Bridge and Tasks.
- Folder quarantine using the xattr marker `user.lugh.quarantine`, enforced by the launcher and the file-association handler.
- Optional auto-quarantine of downloads.
- Running-process actions: freeze, cut network, limit resources, kill, and **Relaunch in Quarantine**.
- Bridge bottles that can launch quarantined.
- Interim GUI isolation on Hyprland: an optional nested compositor (`cage`) per quarantined GUI app, plus best-effort border marking through Hyprland window rules.

**Out (deferred)**
- Compositor-enforced window isolation (no clipboard, no screencopy, no global shortcuts) and striped borders drawn by the compositor. These arrive in **Phase 5** through `wp-security-context-v1` and `lugh-shell-v1`.
- Malware scanning or reputation lookups. Shield is not an antivirus.
- Sandboxing system services or root processes.
- Retroactive filesystem sandboxing of a process that is already running. This is not possible; see the threat model.

## Threat model (summary; full version in the spec)

| Shield protects against | Shield does **not** protect against |
|---|---|
| An untrusted app reading or encrypting `~/Documents`, SSH keys, browser profiles | Kernel exploits or privilege escalation bugs, which can escape any namespace sandbox |
| An app phoning home or scanning the LAN (`strict`/`standard` profiles) | Hardware or firmware attacks |
| An installer that scatters files around `$HOME` (the overlay catches them) | Social engineering: if the user clicks **Keep changes** on everything, the files are kept |
| A misbehaving app hogging CPU/RAM (cgroup limits) | Apps the user explicitly runs **outside** quarantine |
| (Phase 5) Clipboard sniffing, screenshots, keylogging through global shortcuts | (Phase 4, Hyprland) GUI-level snooping, unless the nested-compositor option is on |

> **Shield is not an antivirus.** It reduces the damage an untrusted program can do. It doesn't decide whether a program is malicious, and a kernel exploit can escape it. The UI must say this plainly the first time it's used.

## Sandbox profiles

| Profile | Filesystem | Network | Devices | Use |
|---|---|---|---|---|
| `strict` | read-only system dirs; empty tmpfs `$HOME`; the opened file/folder bind-mounted **read-only**; all writes go to the overlay | none (empty netns) | no GPU*, no webcam/mic, no USB | unknown files, downloaded scripts, cloned repos |
| `standard` (default) | as `strict`, but the opened folder is overlay-mounted (writes are captured for review) | internet only, no LAN, through `pasta` with LAN ranges blocked | GPU, audio output; no webcam/mic | most apps and `.exe` installers |
| `net` | as `standard` | full network, including LAN | GPU, audio | apps that legitimately need LAN (game servers, printers), shown with an extra warning |

\* `strict` allows the GPU when it opens a GUI app (otherwise most apps won't start). The rendering node only, never `/dev/dri/card*` master access.

The user can create custom profiles in the Shield UI. They are stored in `~/.config/lugh/shield/profiles/*.toml` and included by the Lughfile.

## Deliverables

| Deliverable | Path in repo | Package |
|---|---|---|
| Shield daemon (session bus `space.lugh.Shield1`) | `crates/lugh-shieldd/` | `lugh-shield` |
| Sandbox builder library (bwrap args, Landlock rules, seccomp BPF, overlay setup) | `crates/lugh-shieldd/src/sandbox/` | `lugh-shield` |
| CLI `lugh shield …` | `crates/lugh-cli/src/shield.rs` | `lugh-cli` |
| Shield UI (sessions, review changes, profiles, quarantined folders) | `ui/shield/` | `lugh-shield` |
| Shell integration (context menus, quarantine badge, running-app actions) | `ui/shell/` | `lugh-shell` |
| File-manager integration (context menu + folder badge) | `ui/shell/filemanager-integration/` or a service-menu file for the chosen file manager | `lugh-shield` |
| nftables base table for `lugh-shield.slice` | `packaging/shield/nftables/lugh-shield.nft` | `lugh-shield` |
| polkit actions (system-level network cut) | `packaging/shield/polkit/space.lugh.shield.policy` | `lugh-shield` |
| Default profiles | `packaging/shield/profiles/{strict,standard,net}.toml` | `lugh-shield` |
| Hyprland interim rules (border marking) | `iso/includes/etc/lugh/hyprland/shield.conf` | `lugh-session-hyprland` |

## Work breakdown

### 1. Sandbox core (`lugh-shieldd/src/sandbox`)
- [ ] Profile schema (TOML) and parser, with a validated default set.
- [ ] bubblewrap argument builder: `--unshare-all` (minus net for `net`/`standard`), `--die-with-parent`, `--new-session`, read-only binds for `/usr /etc /opt`, tmpfs `/tmp` and `$HOME`, selective `--ro-bind`/`--bind`.
- [ ] Unprivileged overlayfs inside the user namespace (kernel ≥ 5.11): lower is the target folder, upper and work dirs go in `~/.local/share/lugh/shield/sessions/<id>/`. Fall back to `fuse-overlayfs` if the kernel refuses.
- [ ] Landlock ruleset applied inside the sandbox before `exec` (ABI version detected at runtime; degrade gracefully and log it).
- [ ] seccomp filter: deny `ptrace`, `keyctl`, `add_key`, `bpf`, `perf_event_open`, `userfaultfd`, `kexec_*`, `mount` outside the setup phase, `unshare(CLONE_NEWUSER)` (no nested userns), and the TIOCSTI/TIOCLINUX ioctls.
- [ ] Network: `strict` gets an empty netns (loopback only). `standard` runs `pasta` with outbound NAT and blocks RFC1918, link-local, ULA and multicast. `net` passes the netns through.
- [ ] Device policy: `/dev/dri/renderD*` only, PipeWire socket filtered (output only for `standard`), no `/dev/video*`, no `/dev/bus/usb`.
- [ ] Wayland socket passthrough (Phase 4) with a hook for `wp-security-context-v1` (Phase 5).
- [ ] D-Bus: filtered through `xdg-dbus-proxy` (talk only to the portal, notifications and the tray).

### 2. Session lifecycle (`lugh-shieldd`)
- [ ] `Run(profile, argv, cwd, target_paths) → session_id`. Starts the sandbox in a transient scope `app-lugh-shield-<appid>-<id>.scope` under `lugh-shield.slice` (ADR-015).
- [ ] Track sessions: state (running, exited), changes summary, profile, origin.
- [ ] `ListChanges(session_id)`: walk the overlay upper dir and report added, modified and deleted files (whiteouts), with sizes.
- [ ] `Commit(session_id, paths[])` / `Discard(session_id)`: copy chosen files to the real location after a conflict check. Never auto-commit.
- [ ] Session retention: keep exited sessions 7 days (configurable), then discard. Show disk usage.
- [ ] Signals: `SessionStarted`, `SessionExited`, `ChangesAvailable`.

### 3. CLI
- [ ] `lugh shield run [--profile strict|standard|net|<custom>] [--gui-nested] -- <cmd> [args]`
- [ ] `lugh shield open <file-or-folder>`: resolves the default handler and runs it quarantined.
- [ ] `lugh shield ls`, `lugh shield changes <id>`, `lugh shield keep <id> [paths…]`, `lugh shield discard <id>`
- [ ] `lugh shield mark <folder>` / `unmark <folder>` (folder quarantine)
- [ ] `lugh shield freeze|thaw|netcut|netrestore|limit|kill <pid|scope>`

### 4. Folder quarantine and auto-quarantine
- [ ] `mark` sets `user.lugh.quarantine=1` on the folder (and new files inherit it through the daemon's inotify watcher).
- [ ] The launcher and the file-association handler (`lugh-open`, which wraps `xdg-open` for Lugh) check the xattr on the file and its ancestors. If it is set, they always run the handler quarantined.
- [ ] Files without xattr support (FAT/exFAT USB, network shares): keep the marker in a per-mount list in `~/.config/lugh/shield/marked.toml`.
- [ ] Optional **auto-quarantine downloads** (off by default; asked once on first run): mark `~/Downloads` and treat files carrying `user.xdg.origin.url` (set by browsers, including Firefox) as quarantined until the user chooses **Trust this file**.
- [ ] A shield badge on marked files and folders in the file manager and launcher results.

### 5. Running-process controls (with Tasks)
- [ ] **Freeze/thaw**: `org.freedesktop.systemd1` `FreezeUnit`/`ThawUnit` on the app scope (cgroup v2 freezer).
- [ ] **Cut network**: an nftables rule `socket cgroupv2 level N "<scope path>" drop` in table `inet lugh_shield`. This needs root, so it goes through a small polkit-gated method on a system helper (`lugh-shieldd --system`, D-Bus-activated).
- [ ] **Limit**: `SetUnitProperties` (CPUQuota, MemoryMax, IOWeight) on the scope.
- [ ] **Kill**: `KillUnit` (SIGTERM, then SIGKILL after 5 s).
- [ ] **Relaunch in Quarantine**: capture argv, cwd and env of the main process, kill it, and run it again through `Run(...)`. The UI explains why: "A running app can't be sandboxed; it must restart."

### 6. Bridge integration
- [ ] Bridge bottles gain a "Run in Quarantine" toggle (per launch and per bottle default).
- [ ] The bottle prefix is mounted through overlay so changes from a Windows installer can be reviewed before they're kept.
- [ ] Unknown `.exe` files double-clicked from a marked folder always open in a quarantined throwaway bottle.

### 7. UI (`ui/shield/` + shell)
- [ ] Shield app: Active sessions, History (with Review changes), Quarantined folders, Profiles, and an About page with the threat model in plain language.
- [ ] Review changes dialog: a tree of added, modified and deleted files with size and a diff for text files. Buttons: Keep selected, Keep all, Discard all.
- [ ] First-run explainer, shown once (includes "Shield is not an antivirus").
- [ ] Shell: right-click any app, dock icon or launcher result → **Open in Quarantine**. Running quarantined apps get a shield badge on their dock or taskbar icon.
- [ ] Every state is covered (DESIGN-SYSTEM §7): empty ("Nothing quarantined right now"), loading, error (for example "Overlay not supported on this filesystem — using copy mode").

### 8. Hyprland interim GUI isolation
- [ ] `--gui-nested` option and per-profile default: run the app inside `cage` (a kiosk Wayland compositor) shown as one window. The app then can't see the host clipboard or take screenshots of other windows. Trade-offs: one window per app, and no native resizing of child windows.
- [ ] Best-effort border marking: the shell sets the window tag `quarantine` through Hyprland IPC, and a window rule in `shield.conf` gives it a red border. Hyprland can't draw stripes, so the dock badge and a titlebar overlay are what keep it from being color-only.
- [ ] Document clearly in the UI: "Full window isolation arrives with the Lugh compositor."

## Acceptance criteria

1. `lugh shield run --profile strict -- cat ~/.ssh/id_ed25519` fails (the file doesn't exist inside the sandbox).
2. In `strict`, `curl https://example.com` fails. In `standard` it succeeds and `curl http://192.168.1.1` fails. In `net` both succeed.
3. A sandboxed `touch ~/Documents/x` inside an overlay-mounted folder doesn't create the file on the host until the user clicks **Keep**. **Discard** leaves the host untouched.
4. Double-clicking a file inside a marked folder always opens its handler quarantined, verified by the presence of a `lugh-shield.slice` scope.
5. With auto-quarantine on, a file downloaded with Firefox opens quarantined until **Trust this file** is chosen.
6. Freeze stops a CPU-burning app (0% CPU in Tasks within 1 s), and thaw resumes it.
7. Cut network on a running app drops its existing and new connections within 1 s, and restore re-enables them.
8. Relaunch in Quarantine restarts the app sandboxed with the same arguments and working directory.
9. A Windows installer run through Bridge in quarantine leaves the real bottle unchanged until it's reviewed and kept.
10. The seccomp filter blocks `ptrace` (verified with `strace` inside the sandbox) and nested user namespaces.
11. No custom setuid binary is installed (`find / -perm -4000` shows only Debian's).
12. With `--gui-nested`, a quarantined app's clipboard reads return nothing from the host session.

## Testing

**Automated (CI, QEMU image)**
- Sandbox escape suite: a test binary tries to read `$HOME` secrets, write outside the overlay, open raw sockets, `ptrace` a sibling, `unshare` a user namespace, and use the TIOCSTI ioctl. All must fail.
- Network matrix per profile against local test servers (one on the LAN subnet, one "internet" behind NAT).
- Overlay correctness: add, modify, delete, rename, symlinks, hardlinks, large files and xattrs; then commit and discard.
- Process controls: freeze/thaw, netcut/restore and limit, all on a synthetic workload.

**Unit**
- Profile parsing and validation, bwrap argument generation (snapshot tests), Landlock rule generation, seccomp BPF generation, and overlay change detection including whiteouts.

**Manual checklist**
- [ ] Open a downloaded `.AppImage`, a `.sh` script, a cloned git repo and a `.exe` in quarantine.
- [ ] Review changes on an installer that writes 1000+ files; the UI stays responsive.
- [ ] Mark a USB stick (exFAT); the marker list works without xattrs.
- [ ] Screen reader and keyboard-only pass through the Shield app and the Review dialog.
- [ ] The first-run explainer reads clearly to a non-technical tester.

## Performance budget

| Metric | Budget |
|---|---|
| Sandbox start overhead (`strict`, CLI app) | ≤ 80 ms over a native launch |
| Sandbox start overhead (`standard`, GUI app, with pasta) | ≤ 200 ms |
| `lugh-shieldd` idle RSS | ≤ 15 MB; exits after 60 s idle with no sessions |
| Overlay I/O overhead | ≤ 10% on sequential write versus native |
| Change listing for 10 000 files | ≤ 1 s |
| Session idle RAM increase (Phase 3 baseline) | ≤ +10 MB when Shield is unused |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Users treat Shield as an antivirus | False sense of safety | Plain-language explainer, the About page threat model, and no "safe" or "clean" wording anywhere |
| Kernel or userns escapes | Full compromise | Keep the kernel updated from the Lugh repo, a tight seccomp filter (no nested userns, no bpf), and document the limit |
| Unprivileged overlayfs unavailable (old kernel, some filesystems) | No review-changes | Fall back to `fuse-overlayfs`, then to "copy mode" (snapshot the target and diff) with a visible notice |
| GUI isolation weak on Hyprland | Clipboard/screen snooping in Phase 4 | Nested `cage` option, honest UI copy, full fix in Phase 5 |
| Apps break in `strict` (need GPU, fonts, D-Bus) | Users stop using Shield | Allow the GPU render node, ship fonts read-only, use xdg-dbus-proxy, and let the user step a profile down per app (remembered) |
| nftables cgroup match needs root | Network cut fails | polkit-gated system helper; if denied, fall back to freeze and explain |
| Disk fills with old session overlays | Low disk space | 7-day retention, size shown in UI, cleanup on low-disk warning |
| xattrs lost on copy (`cp` without `-a`, archives) | Folder quarantine bypassed | Daemon watcher re-marks files inside marked folders, and the browser-origin xattr is also checked |

## Exit checklist

- [ ] All acceptance criteria pass on the CI QEMU image and on one real laptop.
- [ ] Escape suite green and running in CI on every commit touching `crates/lugh-shieldd`.
- [ ] Threat model published in [../specs/shield.md](../specs/shield.md) and shown in the Shield app.
- [ ] ISO builds in CI from a clean checkout.
- [ ] QEMU boot test passes (reaches the desktop).
- [ ] Shield UI follows DESIGN-SYSTEM.md, all states implemented (§7), quarantine never shown by color alone.
- [ ] `space.lugh.Shield1` API documented, CLI equivalent for every method, polkit actions defined, unit tests present.
- [ ] Performance budgets above pass.
- [ ] Spec updated, any new decisions added to DECISIONS.md.
- [ ] Release note written in `docs/releases/phase-4.md`.
