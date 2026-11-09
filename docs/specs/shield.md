# Lugh Shield (Quarantine) — Spec

> Status: **Draft** · Owner phases: **4** (sandbox, folder and process quarantine) and **5** (window isolation, quarantine borders) · Related ADRs: ADR-004, ADR-007, ADR-015, ADR-016, ADR-017

## Purpose

Let anyone open something they don't trust (an app, a downloaded `.exe`, a folder from a USB stick, a cloned repo) **with one click**, and keep it away from their files, network and screen. When you're done, throw away whatever it changed, or keep only what you want.

- **Daemon:** `lugh-shieldd` (user, session bus `space.lugh.Shield1`), plus a small privileged helper for nftables rules (system bus, polkit-gated).
- **UI:** `lugh-shield` (session list, review changes), plus right-click entries in the file manager, launcher, dock and Lugh Tasks.
- **CLI:** `lugh shield …`

## Threat model

**Protects against:**
- An untrusted program reading or encrypting your personal files (ransomware-style), stealing browser cookies, SSH keys or documents.
- An untrusted program exfiltrating data over the network (in profiles without network).
- An untrusted program persisting itself (autostart entries, shell rc files, systemd user units), because writes go to a throwaway layer.
- An untrusted GUI app keylogging, screenshotting or reading the clipboard of other apps (full from Phase 5).
- Accidentally running a downloaded file outside quarantine (auto-quarantine of downloads, when enabled).

**Non-goals (stated to users):**
- **Shield is not an antivirus.** It doesn't scan or detect malware. It contains it.
- It doesn't protect against kernel exploits or hardware attacks (a sandbox shares the kernel). Use a VM for truly hostile code.
- It can't make an app safe that you give permissions to. Allowing "Home folder" access means the app can read your home folder.
- It can't fully sandbox a process **that is already running**. It can only freeze, cut, limit or kill it, then relaunch it inside quarantine.

## User stories

- **Windows switcher:** "I downloaded a crack-looking installer from a forum. Right-click → Open in Quarantine. It ran, I saw it was junk, I clicked Discard. Nothing touched my files."
- **Linux power user:** "I clone a random repo and run its build script with `lugh shield run --profile net -- make`, so it can download dependencies but can't read `~/.ssh`."
- **Minimal user:** "Shield costs nothing until I use it. No daemon runs."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | **Open in Quarantine** for any app (`.desktop`), executable, script, `.exe`/`.msi` (through Bridge), AppImage, or file (opened with its default app, inside the sandbox). |
| FR-2 | Four profiles: **Strict**, **Standard**, **Net**, **Custom** (permissions table in §Profiles). The default is set in Settings → Privacy. |
| FR-3 | Writes go into a **session overlay**. At the end, **Review changes** shows a per-file list: keep (copy to the real location), discard, or open (sandboxed). |
| FR-4 | **Quarantine a folder:** mark it so that everything opened from inside it runs in quarantine. The folder is visibly badged. |
| FR-5 | **Auto-quarantine downloads** (optional, off by default except in a future "Safe" preset): files written to `~/Downloads` by browsers are marked `user.lugh.quarantine`. |
| FR-6 | **Running-process actions** (from Tasks, the dock or the CLI): Freeze/Resume, Cut network, Limit CPU/RAM, Kill, **Relaunch in Quarantine**. |
| FR-7 | Quarantined windows are visibly marked: a striped border, a shield icon and a title prefix (Phase 5 compositor; interim in §Wayland isolation). |
| FR-8 | Quarantined GUI apps can't read other apps' clipboard, capture the screen or register global shortcuts (Phase 5; interim isolation in Phase 4). |
| FR-9 | Session list: see all running quarantined sessions, their profile, resources and network use, with Stop and Review actions. |
| FR-10 | Promoting trust: "Trust this file" removes the quarantine mark (admin not required for user files; asks for confirmation and explains what it means). |
| FR-11 | Audit log of sessions: what ran, which profile, when, network on or off, files kept. |
| FR-12 | Bridge integration: any bottle or `.exe` can run quarantined (§Bridge integration). |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | Launch overhead ≤ 150 ms over a normal launch (namespace + overlay setup). |
| NFR-2 | No resident process when no session is active (`lugh-shieldd` is D-Bus activated and exits 30 s after the last session ends). |
| NFR-3 | No setuid binaries of our own. Unprivileged user namespaces only, plus one polkit-gated helper for nftables. |
| NFR-4 | Quarantine state is never conveyed by color alone (stripes + icon + text). |
| NFR-5 | Overlay sessions survive a crash or reboot and can still be reviewed afterwards. |

## Design

### Profiles
| Permission | **Strict** | **Standard** (default) | **Net** | Custom |
|---|---|---|---|---|
| Home folder | none (empty tmp home) | none, except the opened file/folder, **read-only** | none, except the opened file/folder, read-write via overlay | pick folders, RO/RW |
| Writes | overlay, discarded by default | overlay, review at end | overlay, review at end | overlay or direct |
| Network | none (empty netns) | none | internet only, no LAN, no localhost (`pasta` with LAN/loopback blocked) | none / internet / full |
| Wayland display | yes, isolated (security-context) | yes, isolated | yes, isolated | yes/no |
| Clipboard | none | paste **into** the app only (user-initiated) | paste into the app only | in / in+out |
| Audio | none | output only | output only | out / in+out |
| Camera / mic | no | no | no | per device |
| GPU | no (software rendering) | yes (`/dev/dri` render node) | yes | yes/no |
| D-Bus | none | filtered: portals + notifications only (xdg-dbus-proxy) | same as Standard | custom list |
| Devices (USB, input) | no | no | no | pick |
| Syscalls | strict seccomp filter (no ptrace, no keyctl, no bpf, no mount, no userns) | default Lugh filter (no ptrace of outside, no bpf, no kernel modules) | same as Standard | default/strict |
| Resource limits | 2 CPU cores, 2 GB RAM, 50 pids | 4 cores, 4 GB, 500 pids | 4 cores, 4 GB, 500 pids | custom |

Every session runs inside `lugh-shield.slice`, which caps all quarantined sessions together at 50% CPU and 50% RAM by default.

### Mechanisms (ADR-017)
```
lugh-shieldd
  └─ systemd StartTransientUnit: app-lugh-shield-<appid>-<id>.scope  (in lugh-shield.slice; CPU/Mem/Pids limits)
       └─ bwrap  --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup
                 [--unshare-net | net via pasta]  --die-with-parent --new-session
                 --ro-bind /usr /usr  --ro-bind /etc (filtered)  --proc /proc  --dev /dev (minimal)
                 --tmpfs $HOME  --bind <session>/upper …  (overlay assembled below)
                 --seccomp <fd>   (profile filter, compiled with libseccomp)
            └─ lugh-shield-init (in sandbox): applies Landlock ruleset (FS allow-list, defense in depth),
                 drops caps, sets no_new_privs, execs the target
```
- **Overlay:** for each read-write grant, an overlayfs mount (unprivileged overlayfs in a user namespace, kernel ≥ 5.11) with `lower=<real path>`, `upper=~/.local/share/lugh/shield/sessions/<id>/upper/<n>`, `work=…/work/<n>`. The real files are never modified.
- **Network:**
  - none: `--unshare-net` (loopback only).
  - internet-only: `pasta` (passt package) provides user-mode networking into the netns, with `--no-map-gw` plus explicit blocks for RFC1918, link-local and the host's loopback.
- **Network cut for running processes:** the privileged helper `lugh-shield-netd` (system bus, polkit `space.lugh.shield.netcut`) adds an nftables rule in the `inet lugh_shield` table: `socket cgroupv2 level N "<scope path>" drop`. Dropping is instant, and existing connections are reset.
- **Freeze:** `org.freedesktop.systemd1.Unit.Freeze()` on the app scope (cgroup v2 freezer). Works on any app because every app has its own scope (ADR-015).
- **Limits:** `SetUnitProperties` (CPUQuota, MemoryMax, IOWeight) on the scope.
- **D-Bus filtering:** `xdg-dbus-proxy` with a profile-specific allow-list.
- **Wayland:** see §Wayland isolation.

### Folder quarantine & marks
- Mark: extended attribute `user.lugh.quarantine` = JSON `{"v":1,"src":"https://…","by":"firefox","t":"2026-11-20T10:00Z","profile":"standard"}`.
- **Folder quarantine** sets the mark on the folder. The file manager, launcher and `xdg-open` integration (`lugh-open`, a thin wrapper registered as the default opener for executables) check the file and its ancestors for the mark. Anything executable, and any document opened by an app, launches through Shield.
- **Downloads:** browsers don't set xattrs on Linux, so auto-quarantine uses a `fanotify`/inotify watcher in `lugh-shieldd` (only when the feature is enabled) on `~/Downloads`, marking new files from `firefox`/`chromium`/Flatpak browsers. Firefox's `places` database or the portal's file-chooser origin is used for `src` when available (best effort).
- Filesystems without user xattrs (FAT/exFAT USB sticks, NTFS through ntfs3): the mark is stored in a sidecar database `~/.local/share/lugh/shield/marks.db`, keyed by volume UUID + path.
- **Honest limit:** marks are advisory. Something that runs *outside* Shield (a terminal `./file`) is not intercepted. `lugh-open` and the file manager honor marks, but the kernel doesn't enforce them. A terminal warning hook for marked files (`command_not_found`-style shell integration) is optional.

### Running-process actions
| Action | Mechanism | Undo |
|---|---|---|
| Freeze | scope `Freeze()` | Resume (`Thaw()`) |
| Cut network | nftables cgroup drop | Restore network |
| Limit CPU/RAM | scope properties | Remove limits |
| Kill | `KillUnit(SIGTERM)` → after 5 s `SIGKILL` | n/a |
| Relaunch in Quarantine | kill (with confirmation) → relaunch the same command and args in the chosen profile | n/a |

The UI explains: "This app is already running with full access. Freezing or cutting its network limits it now. To fully isolate it, relaunch it in Quarantine."

### Review changes
- When a session ends, or on demand, the upper directories are scanned. Lugh lists created, modified and deleted (whiteout) files mapped to their real paths.
- Per file: **Keep** (atomic copy into the real path; for modified files a backup goes to `…/sessions/<id>/backup/`), **Discard**, **Show** (preview text or image in the sandboxed viewer), **Compare** (text diff).
- Bulk actions: Keep all in folder X, Discard all.
- Suspicious changes are highlighted with an icon and a label: autostart (`~/.config/autostart`), shell rc files, `~/.config/systemd/user`, `~/.local/bin`, browser profile dirs, and executables. These default to **Discard**.
- Sessions not reviewed after 7 days are auto-discarded (configurable). Users are told in the session list.

### Wayland isolation
- **Phase 5 (full):** the compositor implements `wp-security-context-v1`. Shield creates a security context for each session's Wayland socket (with `sandbox_engine=space.lugh.shield`, `app_id`, `instance_id`). `lugh-compositor` then:
  - draws the **quarantine border** (danger color, 45° stripes, shield badge) and prefixes titles with "Quarantined —"
  - denies screencopy/image-capture, the data-control (clipboard manager) protocol, global shortcuts, layer-shell, virtual keyboard/pointer, and input-method grabs
  - gives clipboard paste only on explicit user paste into the window, and copy-out only if the profile allows
- **Phase 4 (interim, on Hyprland):** each quarantined GUI session runs inside a **nested kiosk compositor** (`cage`) as a single window in the host session. The nested compositor has its own clipboard and no screencopy access to the host, which gives real isolation. The cost is that windows from one session share a frame, and there's no native window behavior (resize inside cage, one frame per session). The border is approximated by a Hyprland window rule on the cage window class (`lugh-shield-*`) with the danger border color + title prefix. This is documented as interim.
- **Xwayland apps** (including Wine): each quarantined session gets its **own** Xwayland instance (in Phase 4, inside cage; in Phase 5 the compositor spawns a per-security-context Xwayland), so X11 clients can't snoop on each other.

### Bridge integration
- "Run in Quarantine" on any `.exe` creates a **throwaway bottle** in the session overlay. The default profile is Standard, with no network.
- Existing bottles can be launched quarantined. The bottle directory is overlaid, so changes can be reviewed and discarded.
- Recipe installers from outside the signed catalog default to quarantined install (see [bridge](bridge.md)).

### D-Bus interface `space.lugh.Shield1` (object `/space/lugh/Shield1`)
| Member | Signature | Notes |
|---|---|---|
| `Run(target s, args as, profile s, options a{sv}) → o session` | method | `target` = desktop ID, path or URI; options: `grants`, `network`, `limits` |
| `ListSessions() → ao` | method | Session objects: `Profile`, `Target`, `Pids`, `Network`, `StartedAt`, `Stop()`, `ListChanges()`, `Keep(paths as)`, `Discard(paths as)` |
| `Mark(path s, options a{sv})` / `Unmark(path s)` / `GetMark(path s) → a{sv}` | method | |
| `ProcessAction(scope s, action s, params a{sv})` | method | `freeze`, `thaw`, `netcut`, `netrestore`, `limit`, `kill`, `relaunch`; `netcut` goes through the polkit-gated helper |
| `ListProfiles() → aa{sv}` / `SaveProfile(name s, spec a{sv})` | method | |
| `SessionStarted(o)` / `SessionEnded(o, u changes)` | signal | |

### CLI
```
lugh shield run [--profile strict|standard|net|<custom>] [--grant ~/Projects/foo:rw] [--net none|internet|full] -- <cmd> [args…]
lugh shield open <file-or-app>
lugh shield list
lugh shield review <session> [--keep path…] [--discard-all]
lugh shield stop <session>
lugh shield mark <path> [--folder] / unmark <path> / status <path>
lugh shield freeze|thaw|netcut|netrestore|kill <pid|app-id|scope>
lugh shield profiles [show <name>|edit <name>]
lugh shield log [--since 7d]
```

### polkit actions
| Action ID | Use | Default |
|---|---|---|
| `space.lugh.shield.netcut` | nftables rule add/remove for a scope owned by the caller | yes for own scopes (no prompt); auth_admin for other users' or system scopes |
| `space.lugh.shield.process-system` | freeze, limit or kill system services | auth_admin |
Running sandboxes needs no privilege.

### Audit log
JSON lines in `~/.local/state/lugh/shield/audit.jsonl` (rotated at 10 MB): session start/end, target hash, profile, network mode, kept files. Viewable in the Shield app ("History"). It stays local and is never sent anywhere.

## UX
- **Entry points:** right-click "Open in Quarantine" (file manager, launcher results, dock); Bridge "Run in Quarantine"; Tasks process menu; a `Shift+Enter` launcher modifier ("open quarantined").
- **Launch sheet** (skippable with "Don't ask, use Standard"): shows the profile choice with a plain-language summary ("Can't see your files · No internet · Changes reviewed at the end") and an Advanced expander for grants.
- **Running:** the session shows as a tray/bar indicator (shield icon + count) and in the Shield app with live CPU, RAM and network.
- **End:** notification "Notepad++ (Quarantine) closed · 12 changes · [Review] [Discard all]".
- **Review screen:** a tree of changed paths with icons for created / modified / deleted, suspicious-change labels, and per-row Keep/Discard. The primary button is "Apply choices".
- **States:**
  - empty: "Nothing in quarantine. Right-click any app or file and choose Open in Quarantine."
  - loading: scanning changes, with a spinner and file count
  - error: e.g. "Couldn't start quarantine: user namespaces are disabled on this system. [How to fix]"
- **Keyboard:** Super+Shift+Q opens the Shield app. In Review, ↑/↓ moves, K keeps, D discards, Enter applies.

## Security & privacy
- Defense in depth: namespaces + Landlock + seccomp + no_new_privs + dropped capabilities. Failure of any one layer is not fatal.
- Requires `kernel.unprivileged_userns_clone=1` (Debian default). If Debian or AppArmor restricts userns in future, Lugh ships an AppArmor profile allowing `bwrap` userns (as Ubuntu does).
- The cage/compositor isolation is reviewed as part of the Phase 5 security review.
- The audit log and marks are local only.
- Known escape surfaces are documented: GPU driver bugs (Strict disables the GPU), PipeWire output (Strict disables audio), portals (file chooser grants are explicit user actions).

## Testing
- **Escape test suite** (CI, in a VM): from inside each profile, try to read `~/.ssh/id_ed25519`, write to `~/.bashrc`, open a socket to `1.1.1.1` and to the LAN gateway, read the clipboard, screencopy, ptrace a host process, create a user namespace, and access `/dev/input`. Every attempt must fail as the profile table specifies.
- Overlay correctness: create/modify/delete/rename, keep/discard round-trips, crash mid-session → still reviewable.
- Process actions on a test app: freeze stops CPU usage, netcut drops connections within 100 ms, relaunch preserves args.
- Performance: launch overhead benchmark (NFR-1).
- Usability tests with Windows switchers: "open this suspicious file safely" without instructions.

## Open questions
- Should Standard allow GPU by default (better app compatibility vs. driver attack surface)? Proposed: yes for Standard, no for Strict.
- Is a "VM mode" profile (microVM via `krun`/libkrun or Firecracker for truly hostile code) worth adding post-beta?
- A file manager choice (see [settings](settings.md) open question) affects how deep right-click integration goes.
