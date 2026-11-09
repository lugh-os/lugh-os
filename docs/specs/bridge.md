# Lugh Bridge (Windows apps & games) — Spec

> Status: **Draft** · Owner phase: **3** · Related ADRs: ADR-003, ADR-007, ADR-015, ADR-016, ADR-017, ADR-018, ADR-019

## Purpose

Make Windows apps and games **first-class** on Lugh: double-click an `.exe` and it runs, installs show up in the launcher like native apps, and fixing one app can never break another. This replaces juggling Wine prefixes, launchers and per-game hacks by hand.

- **Daemon:** `lugh-bridged` (user, session bus `space.lugh.Bridge1`)
- **UI:** `lugh-bridge` (bottles, library, recipes), plus integration in the Store ([store](store.md)) and Shield ([shield](shield.md))
- **CLI:** `lugh bridge …`

## User stories

- **Windows switcher:** "I double-clicked the Notepad++ installer and it installed. It's in my launcher with its icon, and `.txt` files can open with it."
- **Gamer:** "I installed the EA app and Ubisoft Connect. Each runs in its own bottle, so an update to one doesn't break the other. All my games show up in one library."
- **Linux power user:** "I can pick the runner (Wine 10.x, Proton-GE), set DLL overrides and env vars per bottle, write my own recipe, and share it."
- **Minimal user:** "Bridge isn't installed in the Minimal profile and nothing references it."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | **One bottle per app or launcher** by default (ADR-016). Advanced users can install several apps into one bottle. |
| FR-2 | Runners: **Wine** (WineHQ stable + staging builds, packaged in the Lugh repo), **Proton** through **umu-launcher** (Proton-GE and Valve Proton), plus graphics translation layers **DXVK**, **VKD3D-Proton** and **DXVK-NVAPI**. |
| FR-3 | Profiles **Gaming**, **Apps**, **Legacy** and **Custom** with documented defaults (§Profiles). |
| FR-4 | **Recipes:** declarative install scripts for apps and launchers, from a signed official catalog plus local or community recipes. |
| FR-5 | `.exe` / `.msi` handler flow (§`.exe` handler), shared with the Store. |
| FR-6 | Desktop integration: launcher entries with extracted icons, file associations, tray icons (through Wine's SNI support), and uninstall entries. |
| FR-7 | **Library:** a unified games list from Bridge bottles (games installed through launchers are detected), native Steam (read-only listing), and Heroic (if installed). |
| FR-8 | Per-bottle tools: Run `.exe` in bottle, winecfg, regedit, uninstaller, open C: drive, kill bottle, logs, change runner, snapshot and restore. |
| FR-9 | Backup and restore bottles (tar.zst); bottle **manifests** recorded in the Lughfile ([lughfile](lughfile.md)). |
| FR-10 | Compatibility info: per-recipe rating (Platinum / Gold / Silver / Bronze / Broken), known issues, links to ProtonDB/WineHQ AppDB for games and apps without recipes. |
| FR-11 | Run any bottle or `.exe` in Quarantine (through Shield). |
| FR-12 | Shared runners and runtimes: one copy each, not one per bottle. |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | A new empty Apps bottle is ready in ≤ 10 s (prefix creation, with runtimes from cache). |
| NFR-2 | No overhead beyond Wine/Proton itself. Gaming bottles use GameMode, fsync and the compositor's direct scanout. |
| NFR-3 | Bottles are self-describing: `bottle.toml` + the prefix. Deleting `lugh-bridge` leaves bottles runnable with the CLI runner command printed in `bottle.toml`. |
| NFR-4 | Recipe execution is deterministic, logged, and resumable after failure. |
| NFR-5 | Accessible UI and AA contrast. Library cover art has text labels. |

## Design

### Directory layout
```
~/.local/share/lugh/bridge/
├── bottles/
│   └── notepad-plus-plus/
│       ├── bottle.toml          # manifest (profile, runner, overrides, apps, recipe id+version)
│       ├── prefix/              # WINEPREFIX (drive_c, *.reg)
│       ├── logs/
│       └── snapshots/           # optional tar.zst snapshots
├── runners/
│   ├── wine-10.0-lugh1/
│   ├── proton-ge-10-20/
│   └── umu/                     # umu-launcher + Steam Linux Runtime (pressure-vessel) cache
├── components/                  # dxvk-2.x, vkd3d-proton-2.x, dxvk-nvapi, mono, gecko
├── recipes/                     # cached catalog + local recipes (local/)
└── cache/                       # downloaded installers (hash-addressed)
```

### `bottle.toml`
```toml
schema = 1
name = "Notepad++"
id = "notepad-plus-plus"
profile = "apps"
runner = "wine-10.0-lugh1"
arch = "win64"
windows_version = "win10"
recipe = { id = "notepad-plus-plus", version = 3 }
created = "2026-11-20T10:00:00Z"

[env]
WINEDEBUG = "-all"

[dll_overrides]
# "d3d11" = "native,builtin"

[[app]]
name = "Notepad++"
exe = 'C:\Program Files\Notepad++\notepad++.exe'
icon = "notepad++.png"
mime = ["text/plain", "text/x-c", "text/x-python"]
desktop_entry = true

[run_without_lugh]  # documentation for NFR-3
command = "WINEPREFIX=~/.local/share/lugh/bridge/bottles/notepad-plus-plus/prefix ~/.local/share/lugh/bridge/runners/wine-10.0-lugh1/bin/wine 'C:\\Program Files\\Notepad++\\notepad++.exe'"
```

### Profiles (defaults)
| Setting | **Gaming** | **Apps** | **Legacy** | **Custom** |
|---|---|---|---|---|
| Runner | Proton-GE (latest tested) via `umu-run` | Wine stable (Lugh build) | Wine stable | any |
| Arch | win64 | win64 | **win32** (or win64 with WoW64) | any |
| Windows version | win10 | win10 | **winxp / win7** (per recipe) | any |
| DXVK / VKD3D-Proton | on (bundled in Proton) | DXVK on, VKD3D off | off (WineD3D) | toggles |
| DXVK-NVAPI | on for NVIDIA GPUs | off | off | toggle |
| Sync | fsync (fallback esync; NTsync where the kernel supports it) | esync | none | choice |
| GameMode | on (`gamemoderun`) | off | off | toggle |
| MangoHud | available, off by default (toggle in game settings) | off | off | toggle |
| Env | `PROTON_ENABLE_NVAPI=1` (NVIDIA), `DXVK_ASYNC=0`, `PROTON_NO_ESYNC=0`, `WINEDEBUG=-all` | `WINEDEBUG=-all` | `WINEDEBUG=-all` | custom |
| winetricks verbs | none by default (Proton ships needs) | `corefonts`, `vcrun2022` | `corefonts`, `vcrun6`, `mfc42` | custom |
| Fonts | Proton defaults | corefonts + font smoothing (`FontSmoothing=2`) | corefonts | |
| Audio | PipeWire (through PulseAudio compat) | same | same | |
| Integration | game library entry, controller support (SDL), fullscreen tuned | launcher entry, file associations, tray | launcher entry | |

Default runner versions are pinned per Lugh release and updated through the Update Center (Windows runtimes section). Recipes can pin a runner.

### Recipes
- Format: **TOML**. Each recipe has a version, and the catalog is signed with minisign (Ed25519). Lugh ships the public key.
- Steps are declarative where possible. A restricted `run` step allows commands **inside the bottle only** (Wine commands and winetricks), never arbitrary host shell commands.

Example — Notepad++ (portable-friendly app):
```toml
schema = 1
id = "notepad-plus-plus"
name = "Notepad++"
version = 3                       # recipe version
rating = "platinum"
category = "app"
homepage = "https://notepad-plus-plus.org"
alternatives = ["org.kde.kate"]   # shown by the Store first

[bottle]
profile = "apps"
arch = "win64"

[[download]]
id = "installer"
url = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7.1/npp.8.7.1.Installer.x64.exe"
sha256 = "<pinned-hash>"
# update policy: recipe CI bumps url/hash when upstream releases

[[step]]
action = "winetricks"
verbs = ["corefonts"]

[[step]]
action = "install"
file = "installer"
args = ["/S"]                     # silent install

[[app]]
name = "Notepad++"
exe = 'C:\Program Files\Notepad++\notepad++.exe'
mime = ["text/plain"]

[uninstall]
exe = 'C:\Program Files\Notepad++\uninstall.exe'
args = ["/S"]
```

Example — EA app (launcher):
```toml
schema = 1
id = "ea-app"
name = "EA app"
version = 7
rating = "gold"
category = "launcher"
known_issues = [
  "First login window may render blank: resize the window once.",
  "Games with EA Javelin anti-cheat (e.g. Battlefield 2042) do not work.",
]

[bottle]
profile = "gaming"
runner = "proton-ge-latest"       # alias resolved by catalog to a tested version
umu_game_id = "umu-ea-app"        # lets umu apply protonfixes from its database

[[download]]
id = "installer"
url = "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe"
sha256 = "skip"                   # vendor rotates the binary; allowed only for signed-catalog launchers, verified by Authenticode signer instead
authenticode_signer = "Electronic Arts, Inc."

[[step]]
action = "install"
file = "installer"
args = ["/quiet"]
timeout_minutes = 20

[[step]]
action = "registry"
set = [{ key = 'HKCU\Software\Wine\DllOverrides', name = "dwrite", value = "native,builtin" }]

[[app]]
name = "EA app"
exe = 'C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe'
library_provider = "ea"           # enables game detection in this bottle
```

- **Catalog:** the git repo `lugh/recipes`. Community submissions arrive as PRs and are tested in CI (headless install in a VM with Xvfb/cage, screenshot captured, smoke test of launch). Maintainers review and sign releases. The catalog is fetched as a signed tarball.
- **Local recipes** (`recipes/local/`) are unsigned. Installing them shows a warning and defaults to a **quarantined install** (Shield Standard + network, review at the end).
- `sha256 = "skip"` is only allowed in the signed catalog, and only when an Authenticode signer is specified.

### `.exe` handler flow
Entry: the Store's Windows file handler ([store](store.md) §Windows file handler) calls `space.lugh.Bridge1.Inspect(path)`.
1. **Inspect** (sandboxed): PE headers (32- or 64-bit, subsystem GUI/console), version info (product, company), Authenticode signer, installer type detection (NSIS, Inno Setup, InstallShield, WiX/MSI, Squirrel, or none = portable).
2. **Match** a recipe by product name, signer and hash, and offer it if found.
3. **No recipe:**
   - Installer: "Install **<Product>**" → profile suggestion (Gaming if it's a known game launcher or has DirectX 11/12 imports; Legacy if 16-bit or 32-bit and older than Windows 7 per subsystem version; otherwise Apps) → new bottle named after the product → run the installer → watch for new `.lnk` files in the bottle's Start Menu → offer to create launcher entries for them.
   - Portable `.exe`: "Run once" (temporary bottle, deleted after a confirmation) or "Add as app" (copied into a new bottle's `C:\Apps\<name>\`, launcher entry created).
4. If the file has a quarantine mark ([shield](shield.md)), the primary button becomes **Run in Quarantine**.
5. Every choice is visible on one sheet: Product, Bottle (new / existing), Profile, plus an Advanced expander (runner, arch).

### Launchers & games
| Store | Approach |
|---|---|
| Steam | **Native Linux Steam** (Gaming profile installs `steam-installer`), Proton for Windows games. Bridge only lists Steam games in the library (reads `libraryfolders.vdf`) and opens them through `steam://` |
| Epic, GOG, Amazon | **Heroic Games Launcher** (Flatpak) is offered as the recommended path. Bridge recipes for the native Windows clients exist as a fallback (Epic: Silver) |
| EA app, Ubisoft Connect, Battle.net, Rockstar Launcher | Bridge recipes (Gaming profile, one bottle each) |
| Standalone installers (GOG offline, itch.io) | `.exe` flow, Gaming profile |

**Library:** `lugh-bridged` scans each launcher bottle with a provider plugin (EA manifest files, Ubisoft `settings.yaml`/registry, Battle.net `product.db`). It also scans Steam and Heroic's library JSON. Each game card shows cover art (from the launcher's cache or SteamGridDB when the user enables online art), the source, last played time and a Play button. Launching a game goes through its launcher's protocol or command.

### Integration details
- `.desktop` entries in `~/.local/share/applications/lugh-bridge-<bottle>-<app>.desktop` with `Exec=lugh bridge run <bottle> <app>`, icon extracted from the PE resources (icoutils), and `StartupWMClass` mapped so the dock groups windows correctly.
- Every launch runs in a systemd scope `app-lugh-bridge-<bottle>-<id>.scope` (ADR-015), so Tasks shows the bottle as one app and "End task" kills the wineserver tree.
- File associations are registered per app from `mime` in the manifest. Bridge doesn't auto-associate everything a Windows installer registers; the user approves the list.
- Tray: Wine system tray maps to StatusNotifierItem (the shell supports SNI).
- Uninstall: `lugh bridge remove <bottle>` runs the recipe uninstaller (optional), then deletes the bottle and removes entries and associations.

### Backup, restore, Lughfile
- `lugh bridge backup <bottle> [--to file.tar.zst]` and `restore`. Snapshots before risky operations (runner change, recipe update).
- The Lughfile stores **manifests only**: `{ recipe = "ea-app", profile = "gaming" }` or a custom `bridge/<bottle>.toml`. On apply, bottles are recreated by running recipes. Game data and saves are not included; that's a separate backup.

### D-Bus interface `space.lugh.Bridge1` (object `/space/lugh/Bridge1`)
| Member | Signature | Notes |
|---|---|---|
| `Inspect(path s) → a{sv}` | method | PE info, installer type, recipe match, suggested profile |
| `CatalogSearch(query s) → aa{sv}` | method | used by the Store |
| `InstallRecipe(id s, options a{sv}) → o job` | method | options: bottle name, runner override, quarantine |
| `CreateBottle(name s, profile s, options a{sv}) → s bottle_id` | method | |
| `RunInBottle(bottle s, target s, args as, options a{sv}) → o session` | method | `target` = app name or Windows/Linux path |
| `ListBottles() → aa{sv}` / `GetBottle(id s) → a{sv}` / `UpdateBottle(id s, changes a{sv})` / `RemoveBottle(id s, options a{sv})` | method | |
| `ListLibrary() → aa{sv}` | method | games across providers |
| `ListRunners() → aa{sv}` / `InstallRunner(id s) → o job` | method | |
| `Backup(id s, path s) → o job` / `Restore(path s) → o job` | method | |
| `JobChanged(o, s state, d progress, s message)` | signal | |
| `LibraryChanged()` | signal | |

No polkit: everything is user-scoped. Runner packages from the Lugh repo are installed through the Store (`space.lugh.store.install`).

### CLI
```
lugh bridge inspect setup.exe
lugh bridge install <recipe-id> [--bottle name] [--quarantine]
lugh bridge run <bottle> [<app>|<path.exe>] [-- args]
lugh bridge new <name> --profile gaming|apps|legacy|custom
lugh bridge list [--library]
lugh bridge config <bottle> [--runner X] [--env K=V] [--dll name=native,builtin] [--winver win7]
lugh bridge tricks <bottle> <verb…>
lugh bridge winecfg|regedit|explorer|kill <bottle>
lugh bridge backup|restore|remove <bottle>
lugh bridge runners [list|install <id>|remove <id>]
lugh bridge recipe new|lint|test <file.toml>
```

## UX
- **Home:** "Install a Windows app" (search the recipe catalog, or "Choose .exe…"), Library, Bottles.
- **Library:** cover grid, filter by source, search. Each card has Play, plus a menu with Settings, Open folder, Run in Quarantine and Remove.
- **Bottle page:** apps in the bottle, runner and profile chips, toggles (DXVK, GameMode, MangoHud), tools (winecfg, regedit, run .exe, open C:), snapshots, logs, and a danger zone (reset, delete).
- **Install progress:** step list (Download → Prepare bottle → Install runtimes → Run installer → Create shortcuts), with a live log toggle and Cancel. The installer's own windows appear normally.
- **States:**
  - empty: "No Windows apps yet. Search for an app or open an .exe."
  - loading: skeleton cards
  - error: "The installer exited with code 1603 (MSI general failure). Common fixes: [Try Legacy profile] [Install with vcrun2019] [View log] [Report]"
  - broken rating: shown before install, "This app is known not to work on Lugh. Reason: kernel anti-cheat."
- **Keyboard:** Ctrl+N new bottle, Ctrl+O open .exe, Ctrl+F search, Enter on a card = Play/Open.

## Honest limits (shown in docs and in-app on the relevant recipes)
- **Kernel-level anti-cheat** games (Valorant/Vanguard, some EA Javelin, FACEIT, recent Call of Duty with Ricochet) **do not work**. This is a vendor decision, not something Lugh can fix.
- Some DRM (Denuvo usually works; certain older disc-based or kernel-driver DRM like StarForce does not).
- **Adobe Creative Cloud** (installer and recent Photoshop/Premiere/Illustrator) works poorly or not at all. The Store points to alternatives first, and older standalone versions are rated Bronze.
- Microsoft Office: older versions (2013/2016) are Silver at best, and Microsoft 365 desktop apps are unreliable. The Store suggests the web version, LibreOffice or OnlyOffice.
- Apps that need Windows drivers (hardware dongles, some VPNs, anti-virus) cannot work.
- Very new DirectX 12 titles depend on VKD3D-Proton maturity and the GPU driver.

## Security & privacy
- Bottles are separated from each other, but **Wine is not a sandbox**: a Windows app can read your home folder through the `Z:` drive. Mitigations:
  - New bottles remove the `Z:` → `/` mapping by default and map only `~/Documents`, `~/Downloads`, `~/Pictures`, `~/Music` and `~/Videos` as Windows user folders (Gaming bottles also map game library paths).
  - **Run in Quarantine** gives real isolation ([shield](shield.md)).
- Signed catalog, hash-pinned downloads, Authenticode signer checks for launchers.
- No telemetry. Compatibility reports are only sent when the user clicks Report, which opens a pre-filled form showing exactly what will be sent.

## Testing
- **Recipe CI:** every catalog recipe is installed headlessly in a VM nightly. Results include a launch smoke test (process alive after 30 s, window mapped, screenshot) and automatic rating regression alerts.
- Unit: PE inspector (fixtures: NSIS, Inno, MSI, Squirrel, portable, 16-bit), profile suggestion, manifest round-trip, library providers (fixture files).
- Integration: `.exe` double-click → bottle created → launcher entry exists → launch → appears as one app in Tasks → remove cleans everything.
- Gaming performance check on reference hardware: fixed benchmark scenes (e.g. a free DX11 and a DX12 title or benchmark tool) compared with plain Proton under Steam, within ±3%.

## Open questions
- Ship Proton-GE builds ourselves (mirrored and pinned) or download from upstream GitHub releases on demand? (Proposed: mirror in the Lugh repo for reliability.)
- Use umu-launcher for Apps bottles too (unifies runners; protonfixes help some apps) vs. plain Wine (lighter)?
- SteamGridDB art requires an API key per user or a proxy. Is it opt-in only (proposed)?
- NTsync availability depends on the kernel version in the Lugh repo (see [system-base](system-base.md)).
