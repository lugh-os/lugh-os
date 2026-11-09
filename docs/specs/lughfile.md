# Lughfile — Spec

> Status: **Draft** · Owner phase: **2** (CLI, export/apply/sync) · extended in **3** (store/bridge entries, installer restore) · Related ADRs: ADR-007, ADR-009, ADR-018, ADR-019

## Purpose

Your whole Lugh setup — apps, Windows apps, services, desktop look, dotfiles — described in a small folder you can keep in git and push to GitHub. On a fresh install you paste the repo URL and get your system back.

This is **declarative-ish**: Lugh makes the system *match the file* for everything the file describes, but it is not a bit-for-bit reproducible system like NixOS. Package **versions** come from the repos at apply time; things outside the file are left alone (unless you ask to prune).

- **CLI:** `lugh`
- **Daemon:** `lugh-configd` — user part on the session bus and system part on the system bus, both as `space.lugh.Config1`.
- **GUI:** Settings → Lughfile ([settings](settings.md)); installer restore ([installer](installer.md)).

## User stories

- **Windows switcher:** "I reinstalled and clicked 'Restore from my Lughfile' in the installer; my apps, wallpaper and Windows games came back."
- **Linux power user:** "I edit `lugh.toml`, run `lugh diff`, then `lugh apply`, and commit. My dotfiles are linked from the same repo."
- **Minimal user:** "If I never touch it, nothing happens. No background syncing, no account required."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | `lugh init` creates `~/.config/lugh/` as a git repo with a commented `lugh.toml`, `.lughignore`, `dotfiles/`, `bridge/`. |
| FR-2 | `lugh export` captures current state (user-installed apt packages, Flatpaks, Bridge apps, enabled services, `desktop.toml`, selected dotfiles) into the Lughfile. |
| FR-3 | `lugh diff` shows a plan: what `apply` would install, remove, enable, link, or change. |
| FR-4 | `lugh apply` executes the plan idempotently; running it twice changes nothing the second time. |
| FR-5 | Removal policy: `apply` only removes things **Lugh previously added from this Lughfile** (tracked in state); everything else stays unless `--prune`. |
| FR-6 | `lugh sync` pulls/pushes the repo to a remote (GitHub, GitLab, any git host) over HTTPS or SSH. |
| FR-7 | Secrets are never written: a built-in deny list + `.lughignore`, and a token scanner blocks commits containing likely secrets. |
| FR-8 | `lugh rollback` reverts the last apply (uses the Btrfs pre-apply snapshot for system changes + git for file changes). |
| FR-9 | Installer and first-boot restore from a repo URL (Phase 3). |
| FR-10 | Optional machine-wide `/etc/lugh/system.toml` (admin-owned) for system settings and packages shared by all users. |
| FR-11 | Schema is versioned; older files are migrated automatically, with a backup and a printed summary. |
| FR-12 | Store, Settings and Bridge record user changes into the Lughfile automatically (can be turned off: `[lugh] track_changes = false`). |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | `lugh diff` completes in ≤ 2 s for a 300-entry Lughfile (no network unless `--refresh`). |
| NFR-2 | Apply is transactional per backend: if apt fails, nothing from the apt set is half-applied (PackageKit transaction); later steps don't run; summary shows exactly what changed. |
| NFR-3 | No background process when idle; auto-sync (if enabled) is a systemd user timer. |
| NFR-4 | All output is readable without color; `--json` for scripting. |

## Design

### Folder layout
```
~/.config/lugh/                 # git repo
├── lugh.toml                   # the Lughfile
├── desktop.toml                # owned by lugh-settingsd (see settings.md), included by lugh.toml
├── .lughignore                 # gitignore syntax; extra paths never captured
├── dotfiles/                   # files linked into $HOME (paths mirror $HOME)
│   └── .config/kitty/kitty.conf
├── bridge/                     # bottle manifests (not the bottles themselves)
│   └── notepad-plus-plus.toml
└── hooks/                      # optional: pre-apply.sh / post-apply.sh (user-written, opt-in)
~/.local/state/lugh/            # NOT in git: apply state, last plan, logs
└── state.json                  # what Lugh added, from which Lughfile commit
```

### `lugh.toml` schema v1 — full example
```toml
schema = 1

[lugh]
name = "my-laptop"          # label only; not the hostname
track_changes = true             # Store/Settings/Bridge record changes here
include = ["desktop.toml"]       # files merged into this one

[sync]
remote = "git@github.com:yourname/lugh-config.git"
branch = "main"
auto = "off"                     # off | daily | on-change
# machine-specific overrides live in [machine."<hostname>"] tables (below)

[packages]                       # apt (Debian + Lugh repo)
install = ["git", "htop", "ripgrep", "neovim", "steam-installer"]
remove  = ["nano"]               # explicitly unwanted (only removed with confirmation)

[flatpak]
remotes = { flathub = "https://dl.flathub.org/repo/flathub.flatpakrepo" }
install = [
  "org.kde.krita",
  "com.discordapp.Discord",
  { id = "com.spotify.Client", scope = "user" },
]

[bridge]                         # Windows apps via Lugh Bridge (see bridge.md)
apps = [
  { recipe = "notepad-plus-plus" },
  { recipe = "ea-app", profile = "gaming" },
  { manifest = "bridge/my-old-tool.toml" },   # custom bottle described in a file
]

[services]                       # systemd units
user.enable    = ["syncthing.service"]
system.enable  = ["docker.service"]            # needs admin at apply
system.disable = ["cups-browsed.service"]

[desktop]                        # normally lives in desktop.toml; inline values override it
mode = "lugh"
theme = "light"
accent = "amber"

[dotfiles]
method = "symlink"               # symlink | copy
# every file under dotfiles/ maps to the same path under $HOME
extra = [
  { source = "dotfiles/special/ssh_config", target = "~/.ssh/config", mode = "0600" },
]

[shell]
default = "zsh"                  # changes login shell (chsh) at apply

[machine."gaming-pc"]            # applied only when hostname == gaming-pc
packages.install = ["nvidia-driver"]
desktop.mode = "focus"
```

### `/etc/lugh/system.toml` (optional, admin)
Same schema subset: `[packages]`, `[flatpak]` (system scope), `[services.system]`, plus `[system] hostname`, `timezone`, `locale`, `keyboard`. Applied with `sudo lugh apply --system` or from Settings with polkit `space.lugh.config.apply-system`.

### Apply semantics
1. **Load** `lugh.toml` + includes + matching `[machine.*]`; validate against schema (clear errors with line numbers).
2. **Snapshot current state** (installed packages/flatpaks/bottles, enabled units, dotfile links).
3. **Plan**: compute the set of actions; each tagged `add | remove | change | link | skip(reason)`.
4. **Confirm** (interactive: show plan; `--yes` skips). Plan saved to `~/.local/state/lugh/last-plan.json`.
5. **Pre-apply Btrfs snapshot** if the plan has system changes (via snapper: "Before lugh apply <commit>").
6. **Execute in order**: repos/remotes → apt (one PackageKit transaction) → Flatpak → services → Bridge apps (can be slow; progress per app) → desktop settings (via settingsd) → dotfiles → shell → `post-apply` hook.
7. **Record** `state.json`: each item Lugh added, with Lughfile commit hash. This is what enables safe removal.
8. **Summary** with counts and any failures; non-zero exit if anything failed.

Removal rules:
- An item removed from the Lughfile is uninstalled only if `state.json` says Lugh added it. Otherwise it's reported as "not managed — left alone".
- `--prune` additionally removes **user-installed** packages/flatpaks not listed (never essential/system packages; the base set from [system-base](system-base.md) is protected).
- Explicit `[packages].remove` entries always ask for confirmation unless `--yes`.

Dotfiles:
- Existing real file at a target → moved to `~/.local/state/lugh/backup/<timestamp>/` before linking; never overwritten silently.

### Export semantics
- apt: packages marked **manual** (`apt-mark showmanual`) minus the base/profile set → only what the user added.
- Flatpak: installed apps (not runtimes).
- Bridge: each bottle's manifest (recipe ID + profile + overrides), never the prefix contents.
- Services: units whose enablement differs from vendor preset.
- Dotfiles: **opt-in only** — `lugh track ~/.config/kitty/kitty.conf` copies it into `dotfiles/` and links it back. Export never sweeps `$HOME`.

### Secrets policy
- Built-in deny list (cannot be overridden): `~/.ssh/id_*`, `*.pem`, `*.key`, `~/.gnupg/`, `~/.local/share/keyrings/`, browser profiles, `.netrc`, `~/.config/gh/hosts.yml`, Wine registry `user.reg` credentials, `.env*`.
- `.lughignore` for anything else.
- `lugh sync` runs a token scanner (patterns for GitHub/GitLab tokens, AWS keys, private key headers, high-entropy strings in assignments) on staged files; on hit it refuses to commit and shows the file/line. `--allow <path>` to override per file.
- Remote should be **private**; `lugh sync` warns if a GitHub repo is public (via unauthenticated API check).

### Sync
- Plain git underneath; `lugh sync` = commit (message auto: "lugh: export on my-laptop 2026-11-20") → pull --rebase → push.
- Auth: SSH keys (default if remote is `git@`), HTTPS with Git Credential Manager / libsecret (gnome-keyring), or `gh auth` if GitHub CLI is installed. No Lugh account.
- **Conflicts:** if rebase conflicts, Lugh stops, leaves the repo in a normal git conflict state, and explains (`lugh sync --abort` to undo, or open in editor). TOML conflicts in list fields get a helper: `lugh sync --resolve union` (merges install lists).
- Auto-sync timer (`lugh-sync.timer`) only if `[sync] auto` set; failures produce one notification, not repeated nags.

### Restore at install / first boot (Phase 3)
- Installer page "Restore from my Lughfile" takes a git URL (+ optional SSH key/token entered then, stored only in the new user's keyring).
- The installer clones into the new user's `~/.config/lugh/` and sets a first-boot unit `lugh-firstboot-apply.service` (user) which runs `lugh apply --yes --from-installer` after first login, showing progress in a welcome window. Bridge apps can be deferred ("Install Windows apps later").

### Schema versioning
- `schema = N` at top. `lugh` supports reading N and N-1..1; on load of older, it migrates in memory, writes back after `apply`/`export` with a backup `lugh.toml.schemaN.bak` and a printed change list.
- Newer schema than supported → refuse with "Update Lugh to use this Lughfile".

### D-Bus interface `space.lugh.Config1`
| Member | Signature | Notes |
|---|---|---|
| `Plan(options a{sv}) → s plan_json` | method | |
| `Apply(plan_id s, options a{sv}) → o job` | method | system parts require polkit `space.lugh.config.apply-system` |
| `Export(options a{sv}) → as changed_files` | method | |
| `Record(change a{sv})` | method | called by Store/Settings/Bridge |
| `Sync(options a{sv}) → o job` | method | |
| `Rollback(options a{sv}) → o job` | method | polkit `space.lugh.config.rollback` for system parts |
| `Status() → a{sv}` | method | clean/dirty, ahead/behind, last apply |
| `StateChanged()` | signal | |

### CLI
```
lugh init [--remote <url>]
lugh status                      # repo state, drift summary (items installed/removed outside the Lughfile)
lugh export [--dry-run]
lugh diff [--system]
lugh apply [--yes] [--prune] [--system] [--only packages,flatpak,bridge,services,desktop,dotfiles]
lugh rollback [--to <apply-id>]
lugh sync [--resolve union] [--abort]
lugh track <path> / lugh untrack <path>
lugh edit                        # open lugh.toml in $EDITOR, validate on save
```

## UX

Settings → **Lughfile** page:
- **Not set up (empty):** "Keep your whole setup in one place. [Create Lughfile] [Restore from a repo]".
- **Set up:** status card ("Synced with github.com/yourname/lugh-config · 2 changes not synced"), buttons Sync now / Review changes / Apply.
- **Review changes:** plan view grouped by category with +/−/~ icons and labels (not color alone); "Apply" primary.
- **Applying:** progress per step with live log toggle; Bridge apps listed individually.
- **Error:** e.g. "Couldn't push: authentication failed for github.com. [Set up access] [Details]".
- **Conflict:** "Your Lughfile changed on another computer. [Merge automatically] [Open in editor] [Cancel]".

## Security & privacy
- No secrets in the repo (above); token scanner on every sync.
- System-scope apply requires admin; user-scope never escalates.
- Hooks are **disabled by default**; when a pulled Lughfile contains hooks that weren't run before, `apply` shows them and asks before running (prevents a compromised remote from executing code silently).
- Lughfiles restored in the installer show a full plan before applying.

## Testing
- Unit: schema parse/validate/migrate (fixtures for each schema version), planner (table tests: add/remove/managed/unmanaged/prune), secret scanner (positive/negative corpus).
- Integration (QEMU): fresh VM → `lugh apply` from a fixture repo → assert installed set; apply again → zero actions; remove an entry → only that item removed; rollback restores.
- Sync tests against a local bare repo (conflict scenarios).
- Installer restore end-to-end in CI (Phase 3).

## Open questions
- Should Lugh offer an optional "Lugh-hosted encrypted backup" for users without GitHub? (Proposed: no; document GitLab/Codeberg/self-hosted.)
- Version pinning (`packages.install = [{ name = "foo", version = "1.2" }]`) — useful but fights Debian's model; proposed post-beta.
- How much of Bridge bottle *data* (saves, configs) to optionally back up — probably a separate "backup" feature, not the Lughfile.
