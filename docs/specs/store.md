# Lugh Store — Spec

> Status: **Draft** · Owner phase: **3** · Related ADRs: ADR-003, ADR-007, ADR-009, ADR-011, ADR-013, ADR-016, ADR-018, ADR-019

## Purpose

One place to find, install, update and remove software, whether it comes from Debian/Lugh apt, Flathub, or is a **Windows app** run through Lugh Bridge. It is designed so that someone who has only used Windows never needs to know which source they're installing from, while a Linux user can always see and choose it.

- **UI:** `lugh-store` (QML + Rust/cxx-qt)
- **Daemon:** `lugh-stored`, on the system bus as `space.lugh.Store1`. It also hosts the **Update Center** backend `space.lugh.Update1` (lugh-updated, see [system-base](system-base.md) §Updates).

## User stories

- **Windows switcher:** "I search 'Photoshop' and the store tells me what to do: use Krita or Photopea, or run the Windows version, which installs in one click."
- **Windows switcher:** "I double-click `setup.exe` I downloaded, and something sensible happens."
- **Linux power user:** "I can see whether an app is a .deb or a Flatpak, pick the source, see its permissions, and everything I install is recorded in my Lughfile."
- **Minimal user:** "The store doesn't run in the background, doesn't nag me, and installing VLC doesn't pull in half of KDE."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | Browse: Home (featured, curated collections), Categories, Search, Installed, Updates, Windows apps. |
| FR-2 | Three **sources**: apt (Debian + Lugh repo via PackageKit), Flatpak (Flathub via libflatpak), Bridge (Windows recipes via `lugh-bridged`). |
| FR-3 | When an app exists in several sources, a single listing shows the **recommended source** (rules in §Source priority) with a "Source" picker. |
| FR-4 | **Windows-aware search** using `alternatives.toml`: Windows app names map to native versions, alternatives and Bridge recipes. |
| FR-5 | **`.exe` / `.msi` / `.lnk` handler:** double-click opens the Store's "Run Windows app" flow (§Windows file handler). |
| FR-6 | Install, remove and update with a **queue** visible to the user: parallel downloads, serialized transactions per backend, cancellable before commit. |
| FR-7 | **Update Center:** apt + Flatpak + firmware (fwupd) + Bridge runners/recipes in one list. A Btrfs snapshot is taken before system updates, and rollback is offered. |
| FR-8 | App page: name, summary, screenshots, description, source, size, version, license, developer, permissions (Flatpak) or dependencies (apt), and Bridge compatibility rating for Windows apps. |
| FR-9 | `.deb` and `.flatpakref` files opened from the file manager install through the Store with a source warning ("This package isn't from Lugh or Debian"). |
| FR-10 | Every user-initiated install or removal is reported to `lugh-configd` so the Lughfile records it (unless the user disabled tracking). |
| FR-11 | Offline: cached catalog browsable, installs disabled with the reason shown, queued updates resume when online. |
| FR-12 | Ratings & reviews: **later** (post-beta). Bridge compatibility ratings ship in Phase 3. |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | Store window visible in ≤ 600 ms cold, with the home page served from cache. Catalog refresh happens in the background. |
| NFR-2 | Search results in ≤ 100 ms after keystroke for local catalog (pre-built index; [tantivy](https://github.com/quickwit-oss/tantivy) or SQLite FTS5). |
| NFR-3 | `lugh-stored` exits after 120 s idle when no transaction is running. No resident tray/updater process — scheduled checks run as a systemd timer (`lugh-update-check.timer`, daily, randomized). |
| NFR-4 | Install of a typical small app adds no packages beyond its hard dependencies (`APT::Install-Recommends "false"` system-wide per [system-base](system-base.md)). |
| NFR-5 | Accessible (AT-SPI names on all cards), keyboard-navigable grids, AA contrast; screenshots have alt text from AppStream captions. |

## Design

### Architecture
```
lugh-store (UI, user) ──D-Bus (system)──▶ lugh-stored (root, activated)
                                            ├─ PackageKit (apt backend)       ← AppStream (appstream catalog for Debian/Lugh)
                                            ├─ libflatpak (system installation) ← Flathub AppStream
                                            ├─ lugh-bridged (user session, via the caller's session bus proxy) ← recipe catalog
                                            ├─ catalog index (/var/cache/lugh/store/index)
                                            ├─ snapper (pre/post snapshots)
                                            └─ lugh-configd (record installs)
lugh-updated (root, timer + on demand) ── apt/flatpak/fwupd/bridge update discovery
```
- Flatpaks install **system-wide** by default (shared by all users); "Install for me only" is available in Advanced.
- Bridge installs happen in the **user** session (bottles are per user), so `lugh-stored` hands Windows installs to the calling user's `lugh-bridged` (the UI makes that call directly; stored only aggregates the catalog).

### Source priority (default rules, first match wins)
1. User override for this app (remembered per app ID).
2. **Lugh repo** package (we curate and test it).
3. **Flathub verified** if the Debian version is more than one major version behind upstream, or the app is a fast-moving desktop app on a curated list (browsers other than Firefox, chat apps, Spotify, Discord, OBS, etc.).
4. **Debian** package.
5. **Flathub** (unverified) — shown with "Community package" label.
6. **Bridge recipe** (Windows version) — only offered when no native version exists, or when the user explicitly picks "Windows version".

Firefox is always from Mozilla's APT repo (ADR-011). Developers can set a global preference in Store → Preferences: "Prefer Flatpak" / "Prefer system packages".

### Catalog & metadata
- AppStream for apt (from Debian `dep11` + Lugh repo) and Flathub. Merged by AppStream ID; duplicates collapsed into one listing with multiple sources.
- Curated data from a signed `lugh-store-data` package (also fetchable as signed JSON): featured, collections, category art, source overrides, **alternatives.toml**.

### `alternatives.toml` (Windows-aware search)
```toml
schema = 1

[[app]]
windows_name = "Adobe Photoshop"
aliases = ["photoshop", "ps", "adobe ps"]
native = []                                   # no native Linux version
alternatives = [
  { id = "org.kde.krita",       why = "Painting and photo editing, PSD support" },
  { id = "org.gimp.GIMP",       why = "Photo editing, closest feature set" },
  { web = "https://www.photopea.com", name = "Photopea", why = "Photoshop-like editor in the browser" },
]
bridge = { recipe = "adobe-photoshop-cc2021", rating = "bronze", note = "Older versions only; Creative Cloud installer does not work" }

[[app]]
windows_name = "Notepad++"
aliases = ["notepad plus plus", "npp"]
native = []
alternatives = [
  { id = "org.kde.kate", why = "Fast, tabbed, syntax highlighting" },
  { id = "org.gnome.TextEditor", why = "Simple" },
]
bridge = { recipe = "notepad-plus-plus", rating = "platinum" }

[[app]]
windows_name = "Spotify"
aliases = ["spotify"]
native = [{ id = "com.spotify.Client" }]      # native exists → shown first, Windows version not offered
```
Search results for a Windows name render a dedicated **"Coming from Windows?"** card at the top: native version if any → alternatives (with the "why") → "Run the Windows version" (Bridge, with rating badge).

### Windows file handler (`.exe`, `.msi`, `.lnk`, `.bat`)
`lugh-store --open-windows-file <path>` is registered as the MIME handler (`application/x-ms-dos-executable`, `application/x-msi`, `application/x-ms-shortcut`). Flow:
1. Hash the file (SHA-256) and read PE metadata (product name, publisher, signature) — done in a Shield-sandboxed helper since the file is untrusted.
2. Look up the hash/product in the recipe catalog → if a recipe matches: "We have a tested setup for **Notepad++** → Install". 
3. If the product has a native version/alternative in `alternatives.toml`: offer it first ("Notepad++ has great Linux alternatives…") with "Run the Windows version anyway".
4. Otherwise hand to Bridge's generic flow ([bridge](bridge.md) §`.exe` handler): detect installer vs portable, choose profile, choose bottle (new by default).
5. If the file carries `user.lugh.quarantine` (downloaded, see [shield](shield.md)), the default action is **Run in Quarantine**.
Setting in Default apps: `.exe` handler = Store/Bridge (default in Standard/Gaming) / Ask / Off (Minimal profile without Bridge → shows "Install Bridge to run Windows apps").

### Transactions & queue
- Queue model: `Job { id, kind: install|remove|update|repair, source, target, state: queued|downloading|installing|done|failed|cancelled, progress, bytes }`.
- Downloads run in parallel across sources; commits are serialized per backend (apt lock, flatpak installation lock). A Bridge install never blocks apt.
- Cancel allowed until the commit step.
- Failure: show cause in plain language, with "Details" (backend log) and a recovery action (retry, repair `apt --fix-broken` via PackageKit `RepairSystem`, free space).

### Update Center
- Sections: **System** (apt: kernel, Mesa, Lugh components, security), **Apps** (apt desktop apps + Flatpak), **Firmware** (fwupd), **Windows runtimes** (Bridge runners, DXVK/VKD3D, recipe catalog).
- System updates: `lugh-updated` asks snapper for a **pre** snapshot, runs the transaction, then a **post** snapshot (snapper apt hook already does pre/post for apt; Update Center labels them "Before update 2026-11-20"). After a kernel/Mesa update: "Restart to finish" (with "Later").
- Rollback: "Undo last system update" → lists snapshot pairs → `snapper undochange` for config-only rollback, or "Boot previous snapshot" instructions via grub-btrfs for full rollback ([system-base](system-base.md) §Snapshots).
- Policy (Settings → Updates): security updates automatic (unattended-upgrades, default on), others notify; Flatpak auto-update on (default) / off; firmware always manual.
- Metered connections: no automatic downloads.

### D-Bus interface `space.lugh.Store1` (object `/space/lugh/Store1`)
| Member | Signature | Notes |
|---|---|---|
| `Search(query s, flags a{sv}) → aa{sv}` | method | Results include `id`, `name`, `summary`, `icon`, `sources` (as), `recommended_source`, `windows_card` (optional). |
| `GetApp(id s) → a{sv}` | method | Full listing. |
| `ListInstalled() → aa{sv}` | method | Across all sources. |
| `Install(id s, source s, options a{sv}) → o job` | method | polkit `space.lugh.store.install` (apt/system flatpak). |
| `Remove(id s, source s, options a{sv}) → o job` | method | polkit `space.lugh.store.remove`. |
| `OpenWindowsFile(path s) → a{sv}` | method | Returns match result + suggested actions. |
| `RefreshCatalog()` | method | |
| `SetSourceOverride(id s, source s)` | method | |
| `JobChanged(job o, state s, progress d)` | signal | Job objects at `/space/lugh/Store1/jobs/N` with `Cancel()`. |
| `CatalogUpdated()` | signal | |

`space.lugh.Update1`: `Check() → aa{sv}`, `Apply(ids as, options a{sv}) → o job`, `ListSnapshots() → aa{sv}`, `Rollback(snapshot u)`; signals `UpdatesAvailable(u count, b security)`. polkit `space.lugh.update.apply`, `space.lugh.update.rollback` (admin, always ask).

### CLI
```
lugh store search photoshop
lugh store info org.kde.krita
lugh store install org.kde.krita [--source flatpak|apt]
lugh store remove vlc
lugh store list --installed [--source flatpak]
lugh update            # check + list
lugh update apply [--all|--security]
lugh update rollback [--list]
```

### polkit actions
| Action ID | Default |
|---|---|
| `space.lugh.store.install` | auth_admin_keep (admin authenticates once, then installs from signed Lugh/Debian/Flathub sources are allowed for 5 min) |
| `space.lugh.store.remove` | auth_admin_keep |
| `space.lugh.store.install-local-deb` | auth_admin (always) |
| `space.lugh.update.apply` | auth_admin_keep (security auto-updates run as root via timer, no prompt) |
| `space.lugh.update.rollback` | auth_admin |
User-scoped Flatpak and Bridge installs need no admin.

### Lughfile integration
Every successful install/remove triggers `space.lugh.Config1.Record({kind:"apt"|"flatpak"|"bridge", id, action})`. The Lughfile stores the **intent** (app ID + chosen source), not versions (see [lughfile](lughfile.md)).

## UX

### Screens
- **Home:** hero "Featured" (one per week, curated), collections ("Coming from Windows", "Essentials", "Games", "Creative", "Developer"), recently updated.
- **Search:** results grid; the "Coming from Windows?" card when matched; filters: Source, Category, Free/Open source.
- **App page:** primary button reflects state: Install → progress ring + Cancel → Open / Remove. Source chip ("Flathub · verified", "Lugh", "Debian", "Windows (Bridge) · Gold"). Permissions panel for Flatpak ("Can access: your files, network").
- **Installed:** list grouped by source, with size and "Remove".
- **Updates:** Update Center described above; one primary "Update all" button; per-item details collapsed.
- **Queue:** bottom drawer showing active jobs; badge on the sidebar.

### States
- **Loading:** card skeletons; app page skeleton with screenshot placeholders.
- **Empty search:** "No apps match 'xyz'. Try a different name, or search the web for the .exe and open it with Bridge."
- **Offline:** banner "You're offline — showing saved catalog. Installs will be available when you reconnect."
- **Error:** e.g. "Couldn't install VLC: not enough space (needs 120 MB, 40 MB free). [Free up space] [Details]".
- **Up to date:** "Everything is up to date · Last checked 10 min ago · [Check now]".

### Keyboard
| Shortcut | Action |
|---|---|
| Ctrl+F or type | search |
| Ctrl+1/2/3/4 | Home / Search / Installed / Updates |
| Enter | open selected / primary action on app page |
| Ctrl+Q | quit (warns if jobs are running; jobs continue in the daemon) |

## Security & privacy
- Only signed repos (apt) and verified remotes (Flathub). Local `.deb` installs require explicit admin auth and show a warning.
- Bridge recipe catalog is signed (see [bridge](bridge.md) §Catalog); downloads in recipes are hash-pinned.
- Windows files are inspected in a sandboxed helper (no network, read-only access to the file).
- Search queries are local; catalog refresh fetches whole catalogs, so the server never sees what a user searched for. No install analytics.

## Testing
- Unit: source priority resolver (table-driven), alternatives matching (aliases, fuzzy), job state machine.
- Integration (QEMU, CI): install/remove one apt app, one Flatpak, one Bridge recipe (Notepad++); update with snapshot creation verified via `snapper list`; rollback test.
- Offline test: disable network in VM → browse, install disabled, resume after reconnect.
- UI: screenshot tests (light/dark), accessibility tree, search latency benchmark on a 10k-app catalog.

## Open questions
- Hosting for `lugh-store-data` and curated content (tied to the domain decision).
- Should "Prefer Flatpak" be the default for the Windows-switcher audience (newer apps, sandboxed) vs. Debian packages (smaller, integrated)?
- Paid apps / donations links: show upstream donation links only (proposed).
