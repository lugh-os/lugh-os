# Lugh Tasks (Task + Service Manager) — Spec

> Status: **Draft** · Owner phase: **2** (Shield actions wired in **4**) · Related ADRs: ADR-006, ADR-007, ADR-015, ADR-017, ADR-020

## Purpose

An "insane" system tool: the friendliness of Windows Task Manager, the depth of Process Explorer, and a real **systemd** manager. It lets you see what's running, what's slow, what starts at boot, and lets you edit services directly and safely.

- **UI:** `lugh-tasks` (QML + Rust/cxx-qt). Opens with **Ctrl+Shift+Esc** in every desktop mode.
- **Daemon:** `lugh-tasksd`. A user part (session bus) handles collection for the user's processes. A privileged part (system bus `space.lugh.Tasks1`) handles system-wide metrics, unit editing, and actions on other users' or system processes, with polkit.

## User stories

- **Windows switcher:** "Something's eating my CPU. Ctrl+Shift+Esc, sort by CPU, End task. It looks like what I know."
- **Linux power user:** "I can see a unit's dependencies, follow its journal live, edit an override with validation, and revert if I break something, without memorizing `systemctl` flags."
- **Gamer:** "I can see GPU usage and VRAM per process, and which game is using the GPU."
- **Minimal user:** "It costs nothing when closed, and very little when open."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | Tabs: **Apps**, **Processes**, **Performance**, **Services**, **Startup**, **Logs**, **Users**. |
| FR-2 | **Apps** groups processes by app using systemd scopes (ADR-015): name, icon, CPU, RAM, GPU, disk, network and energy impact. Bridge bottles and Shield sessions are badged. |
| FR-3 | **Processes:** a full tree or flat list of every process. Columns can be chosen (PID, user, CPU, RAM (PSS/RSS), GPU, VRAM, disk R/W, net, threads, nice, I/O priority, cgroup/unit, command line, start time, state). |
| FR-4 | Process actions: End (SIGTERM), Kill (SIGKILL), Suspend/Resume (scope freeze, or SIGSTOP for non-scoped processes), set priority (nice), I/O priority (ionice), CPU affinity, open location, show details (open files, maps, env with secrets masked, sockets), and **Shield actions** (freeze, cut network, limit, relaunch in Quarantine; Phase 4). |
| FR-5 | **Performance:** live graphs for CPU (total + per core, frequency), RAM/swap/zram, GPU (utilization, VRAM, clocks, temperature, power), disks (throughput, IOPS, latency, usage), network (per interface), temperatures and fans (hwmon), battery (rate, health), and pressure stall info (PSI). |
| FR-6 | **Services:** every systemd unit (system and user) with filters by type (service, timer, socket, mount, path, target), state (active, failed, inactive) and enablement. |
| FR-7 | Unit actions: start, stop, restart, reload, enable, disable, mask, unmask, reset-failed, plus "enable and start now". |
| FR-8 | **Unit editing:** drop-in override by default; optional full edit; validation before applying; daemon-reload; history and one-click revert (§Unit editing). |
| FR-9 | Unit details: description, status, main PID, memory, CPU time, tasks, the unit file with syntax highlighting (read-only until edit), drop-ins, **dependency view** (Requires/Wants/After/Before, as a graph), live journal. |
| FR-10 | **Timers** view: next and last run, schedule in human words ("every day at 03:00"). **Sockets** view: listen addresses, connections. |
| FR-11 | **Startup:** user autostart apps (XDG autostart + user units with `WantedBy=default.target`/`graphical-session.target`), enabled system services, and **boot analysis** (`systemd-analyze` time, blame, critical-chain as a visual timeline). |
| FR-12 | **Logs:** journald viewer with live follow, filters (unit, priority, boot, time range, text/regex, PID), export of filtered logs. |
| FR-13 | **Users:** logged-in sessions and per-user resource totals. Sign out a user (admin). |
| FR-14 | "Create service" wizard: generate a user or system service from a command (name, command, restart policy, start at login/boot), shown as a unit file before saving. |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | **Overhead budget:** the daemon plus UI use under 1% of one CPU core at a 1 s refresh with about 400 processes on reference hardware (see [build-and-release](build-and-release.md) §Performance). Under 0.3% when minimized (graphs paused, only the tray summary). |
| NFR-2 | Memory: UI ≤ 120 MB, tasksd ≤ 25 MB RSS. |
| NFR-3 | Opens in ≤ 300 ms (Ctrl+Shift+Esc to first data). The first sample uses cached `/proc` totals, and deltas fill in at the next tick. |
| NFR-4 | Refresh rate can be set to 0.5, 1 (default), 2 or 5 s, or paused. Graphs keep 60 s of history by default (up to 10 min). |
| NFR-5 | Tables are virtualized (thousands of rows stay smooth). Sorting and filtering stay responsive (< 16 ms per frame). |
| NFR-6 | Fully keyboard-driven with accessible table semantics. Graphs have numeric readouts and a text table alternative (not graph-only). Colors in graphs are paired with labels and patterns. |

## Design

### Architecture
```
lugh-tasks (UI)
   │ D-Bus (session)                    │ D-Bus (system, polkit)
   ▼                                    ▼
lugh-tasksd --user                    lugh-tasksd --system (root, activated)
 ├ /proc (procfs crate): user's procs  ├ /proc all procs (other users), /proc/<pid>/io for others
 ├ cgroup v2 stats (user slice)        ├ cgroup v2 stats (system.slice, all)
 ├ DRM fdinfo (GPU per process)        ├ RAPL energy (/sys/class/powercap, root-readable)
 ├ NVML (if NVIDIA present)            ├ unit file editing + history
 ├ systemd1 (user manager)             ├ systemd1 (system manager): actions, enablement
 └ journald (user + readable system)   └ journald (all), systemd-analyze
```
- **Collection happens only while a client is subscribed.** No sampling when the UI is closed. Both daemons exit 30 s after the last client disconnects.
- Samples are pushed as compact binary batches (one D-Bus signal per tick containing a delta-encoded array), not one call per process.

### Data sources
| Metric | Source |
|---|---|
| CPU per process | `/proc/<pid>/stat` utime+stime deltas |
| Memory | `/proc/<pid>/smaps_rollup` (PSS, when visible) and `statm` (RSS) |
| Per-app totals | cgroup v2: `cpu.stat`, `memory.current`, `io.stat`, `pids.current` of the app's scope |
| Disk I/O per process | `/proc/<pid>/io` (own processes; others through the system part) |
| Network per process/app | cgroup-attached eBPF counters (`cgroup_skb`) in the system part when available; otherwise per-app network is shown as "n/a" and only interface totals (`/proc/net/dev`) are shown. No packet inspection |
| GPU per process | DRM fdinfo (`/proc/<pid>/fdinfo/*`: `drm-engine-*`, `drm-memory-*`) for amdgpu, i915/xe, nouveau, panfrost, msm; **NVML** for the NVIDIA proprietary driver |
| GPU totals | sysfs (`gpu_busy_percent`, hwmon) and NVML |
| Energy | RAPL (Intel/AMD package and core) for system power; per-app "energy impact" is estimated from CPU+GPU time, weighted, and labeled as an estimate |
| Temperatures/fans | hwmon (`/sys/class/hwmon`), NVML for NVIDIA |
| Pressure | `/proc/pressure/{cpu,memory,io}` and per-cgroup `*.pressure` |
| Battery | UPower |
| Boot analysis | `org.freedesktop.systemd1.Manager` timestamps + `systemd-analyze blame/critical-chain --json` |

### Unit editing
Two modes:
1. **Override (default):** edits `/etc/systemd/system/<unit>.d/override.conf` (system) or `~/.config/systemd/user/<unit>.d/override.conf` (user), like `systemctl edit`. The editor shows the vendor unit read-only on the left and the override on the right.
2. **Full edit (advanced, warned):** copies the unit to `/etc/systemd/system/<unit>` (or the user equivalent), which takes precedence over the vendor file, and edits that.

Saving does the following:
1. Writes to a temp file. Runs `systemd-analyze verify` on the merged unit (vendor + drop-ins) in a sandbox. Shows errors and warnings inline with line numbers.
2. Saves the previous version to history: `/var/lib/lugh/tasks/history/<unit>/<timestamp>.conf` plus `meta.json` (who, when, mode, diff). User units go to `~/.local/state/lugh/tasks/history/`.
3. Atomically moves the file into place and calls `Reload()` (daemon-reload).
4. Offers "Restart now to apply" if the unit is active.

**Revert:** the History list shows diffs and a one-click "Revert to this version". "Reset to vendor" removes overrides and full copies (`systemctl revert` semantics).

Guardrails: a warning before stopping, masking or editing critical units (`systemd-journald`, `dbus`, `greetd`, `NetworkManager`, `lugh-*`, the display manager, the compositor's user service). Masking `dbus` or `systemd-logind` is blocked outright, with an explanation.

### D-Bus interfaces
`space.lugh.Tasks1` (system bus; the user daemon exposes the same interface on the session bus for user-scope data):
| Member | Signature | Notes |
|---|---|---|
| `Subscribe(kinds as, interval_ms u) → s token` | method | kinds: `processes`, `apps`, `cpu`, `memory`, `gpu`, `disk`, `net`, `sensors`, `pressure` |
| `Unsubscribe(token s)` | method | |
| `Sample(token s, data ay)` | signal | delta-encoded batch (format in `crates/lugh-tasksd/PROTOCOL.md`) |
| `ProcessDetails(pid u) → a{sv}` | method | open files, sockets, maps summary, env (masked) |
| `Signal(pid u, signal i)` | method | polkit `space.lugh.tasks.signal-other` for non-owned processes |
| `SetPriority(pid u, nice i, ioclass u, iolevel u)` | method | negative nice → polkit `space.lugh.tasks.priority` |
| `SetAffinity(pid u, cpus au)` | method | |
| `UnitAction(scope s, unit s, action s)` | method | `scope` = `system`/`user`; action start/stop/restart/reload/enable/disable/mask/unmask/reset-failed; polkit `space.lugh.tasks.unit-control` |
| `GetUnitFile(unit s) → (s vendor, as dropins, s effective)` | method | |
| `VerifyUnit(unit s, content s, mode s) → aa{sv}` | method | diagnostics (line, severity, message) |
| `SaveUnit(unit s, content s, mode s) → s history_id` | method | polkit `space.lugh.tasks.unit-edit` |
| `UnitHistory(unit s) → aa{sv}` / `RevertUnit(unit s, history_id s)` / `ResetUnitToVendor(unit s)` | method | polkit `space.lugh.tasks.unit-edit` |
| `CreateService(spec a{sv}) → s unit` | method | polkit `space.lugh.tasks.unit-edit` for system units |
| `BootAnalysis() → a{sv}` | method | totals, blame list, critical chain |
| `JournalQuery(filter a{sv}) → h fd` | method | returns a pipe with JSON lines; `follow=true` keeps streaming; system logs need membership in `systemd-journal`/`adm`, or polkit `space.lugh.tasks.journal-system` |

Shield actions in the Processes and Apps tabs call `space.lugh.Shield1.ProcessAction` ([shield](shield.md)).

### polkit actions
| Action ID | Use | Default (active local admin) |
|---|---|---|
| `space.lugh.tasks.signal-other` | end/kill processes of other users or system services | auth_admin_keep |
| `space.lugh.tasks.priority` | raise priority (negative nice, realtime I/O) | auth_admin_keep |
| `space.lugh.tasks.unit-control` | start/stop/enable/disable/mask system units | auth_admin_keep |
| `space.lugh.tasks.unit-edit` | edit, revert or create system units | auth_admin (always ask) |
| `space.lugh.tasks.journal-system` | read the full system journal | auth_admin_keep (skipped if the user is in `adm`) |
User units and the user's own processes need no authorization.

### CLI
```
lugh tasks top                       # TUI summary (htop-like, uses the same daemon)
lugh tasks apps [--sort cpu]
lugh tasks kill <pid|app-id> [--force]
lugh tasks units [--failed] [--user] [--type timer]
lugh tasks unit <name> [start|stop|restart|enable|disable|mask|status]
lugh tasks edit <unit> [--full]      # opens $EDITOR, validates, saves with history
lugh tasks history <unit> / revert <unit> <id> / reset <unit>
lugh tasks boot                      # boot time + blame + critical chain
lugh tasks logs [-u unit] [-p err] [-f] [--boot -1]
```

## UX

### Layout
A left rail of tab icons with labels and a main area. The header has search (filters the current tab), the refresh-rate menu and a pause button. The window defaults to 1100×720 and supports a compact mini mode (the Performance summary only, always-on-top optional).

### Tabs
- **Apps:** rows with icon, name, and badges ("Windows · Bridge", "Quarantined", "Flatpak"). Columns: CPU, RAM, GPU, Disk, Network, Energy, each with a heat tint *and* the number. Expand a row to see its processes. Primary action: **End task**.
- **Processes:** a tree toggle, column chooser, and a details side panel.
- **Performance:** a selectable list on the left (CPU, Memory, GPU 0, Disk nvme0n1, Wi-Fi, Battery, Sensors) with a mini-graph each, and a large graph plus key numbers on the right (like Windows Task Manager's layout, so it's instantly familiar).
- **Services:** a table (Name, Description, State, Enabled, Memory, Since) with filter chips (Running / Failed / Disabled / Timers / Sockets / User), and a detail pane with sub-tabs Status / Unit file / Dependencies / Logs / History.
- **Startup:** apps that start at login (toggle on/off, impact estimate), services enabled at boot, and a boot timeline chart (critical chain highlighted, with labels on bars).
- **Logs:** a filter bar, virtualized log list in monospace, priority icons + labels, live-follow toggle, and Export.
- **Users:** sessions with totals, and sign out.

### States
- **Loading:** first-tick skeleton rows for at most one refresh interval.
- **Empty:** "No failed units 🎉" (a text label as well as the icon); "No apps start at login".
- **Error:** "Couldn't read GPU usage: the NVIDIA driver doesn't expose NVML on this system. Other metrics are unaffected." Shown inline in the GPU card, never as a modal.
- **Permission:** a lock badge on rows that need admin; the action prompts through polkit with a specific message ("Restart NetworkManager.service").
- **Unit editor validation:** a gutter marker with the error under the line. Save is disabled until there are no errors; warnings are allowed.

### Keyboard
| Shortcut | Action |
|---|---|
| Ctrl+Shift+Esc (global) | open Tasks / bring to front |
| Ctrl+1..7 | switch tab |
| Ctrl+F or type | filter |
| Delete | End task / stop unit (with confirmation for system units) |
| Shift+Delete | Kill |
| Ctrl+E | edit unit |
| Ctrl+L | logs for selected app/unit |
| Space | pause/resume refresh |
| F5 | refresh now |

## Security & privacy
- Environment variables in process details are masked by default for keys matching `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*KEY*`. Reveal is per item and needs re-authentication for other users' processes.
- Unit editing is always auditable (history with author + diff) and reversible.
- The system daemon exposes only the actions above. Each privileged call is a distinct polkit action with a human-readable message.
- No data leaves the machine.

## Testing
- Unit: parsers for `/proc` and fdinfo (fixtures from real kernels and drivers), delta encoding, schedule-to-text for timers, unit history store.
- Integration (VM): a CPU-hog test app is detected within 2 ticks; End task kills its scope; edit an override → verify catches a bad directive → good edit saves → restart applies → revert restores; mask guardrail for `dbus` refuses.
- Overhead benchmark in CI: 400 synthetic processes, 1 s refresh for 5 min, measured CPU of tasksd + UI under 1% (NFR-1).
- GPU matrix (manual + CI where possible): Intel (i915/xe), AMD (amdgpu), NVIDIA proprietary (NVML), NVIDIA nouveau.
- Accessibility: screen reader walkthrough of the Services tab and editor; table navigation by keyboard only.

## Open questions
- eBPF per-app network accounting needs `CAP_BPF` in the system daemon. Is that acceptable for v1, or should we ship interface totals only and add per-app network later?
- Should the TUI (`lugh tasks top`) be a priority for server/SSH use, or post-beta?
- Unit editor: build our own QML syntax highlighter for unit files, or embed KSyntaxHighlighting (already a Qt library, which has a systemd unit definition)? Proposed: KSyntaxHighlighting.
