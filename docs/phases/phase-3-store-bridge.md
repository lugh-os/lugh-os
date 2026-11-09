# Phase 3 — Store + Bridge

> Status: **Draft** · Size: **XL** · Depends on: Phase 2 · Specs: [store](../specs/store.md), [bridge](../specs/bridge.md), [lughfile](../specs/lughfile.md), [installer](../specs/installer.md), [system-base](../specs/system-base.md) §Updates · Decisions: ADR-003, 009, 013, 015, 016, 018, 019

## Goal

One store for everything. In **Lugh Store** a user can search, install, update and remove apps from Debian/Lugh apt, Flathub and **Windows**, and search is Windows-aware: typing "Notepad++" or "Photoshop" shows the native version, good Linux alternatives, or "Run the Windows version". Double-clicking any `.exe` or `.msi` opens **Lugh Bridge**, which installs it into its own isolated bottle with the right profile, so one Windows app can never break another. Gaming bottles run Proton through umu. A single **update center** updates the system, apps, firmware and Wine runners, takes a Btrfs snapshot first, and lets the user roll back from the boot menu. Lughfiles now carry Store and Bridge apps too, and the installer can **restore a whole setup from a Lughfile git URL**.

## Scope

**In**
- `lugh-stored` (system daemon, `space.lugh.Store1`) + `lugh-store` UI.
- Windows-aware search with the `alternatives.toml` mapping. `.exe`/`.msi`/`.lnk` handlers.
- `lugh-bridged` (user daemon, `space.lugh.Bridge1`) + `lugh-bridge` UI + CLI.
- Runners in the Lugh repo: WineHQ stable and staging builds, umu-launcher; per-bottle DXVK / VKD3D-Proton.
- Profiles: Gaming, Apps, Legacy, Custom. Recipe format v1, signed official catalog, and the first 12 recipes.
- `lugh-updated` (`space.lugh.Update1`): apt + flatpak + fwupd + Bridge runners, snapper pre/post, grub-btrfs boot-to-snapshot, rollback UX.
- Lughfile `[store]` and `[bridge]` sections. Calamares "Restore from my Lughfile".
- Profiles now ship Store and Bridge (Standard, Gaming, Developer). Minimal stays without them, but can add them from Settings.

**Out (deferred)**
- Running installers or bottles **in quarantine** → Phase 4 (the Bridge UI shows the option disabled, with the label "Coming in Shield").
- A community recipe submission website and ratings backend → Phase 7.
- Paid apps or a payments system → not planned.
- **Kernel-level anti-cheat games** (e.g. Valorant, some Battlefield, Call of Duty titles, FACEIT): **will not run**. This is a permanent limit of Wine/Proton, not a roadmap item. The Store says so clearly instead of failing silently.
- Steam's Windows client: not needed, because the native Linux Steam + Proton is the recommended path.

## Deliverables

| Deliverable | Path | Package |
|---|---|---|
| Store daemon | `crates/lugh-stored/` | `lugh-stored` |
| Store UI | `ui/store/` | `lugh-store` |
| Alternatives map | `data/store/alternatives.toml` | `lugh-store-data` |
| Curated Store content (featured, categories) | `data/store/curation/` | `lugh-store-data` |
| Bridge daemon + CLI | `crates/lugh-bridged/` | `lugh-bridge` |
| Bridge UI | `ui/bridge/` | `lugh-bridge` |
| Recipes (official catalog) | `recipes/` | published as a signed index (`recipes.lugh/index.json`), not a .deb |
| Runners | `packaging/wine/`, `packaging/umu-launcher/` | `lugh-wine-stable`, `lugh-wine-staging`, `umu-launcher` |
| Update daemon | `crates/lugh-updated/` | `lugh-updated` |
| grub-btrfs (if missing from Debian) | `packaging/grub-btrfs/` | `grub-btrfs` |
| Calamares Lughfile module | `installer/modules/lughfile/` | `lugh-calamares-config` |
| Lughfile schema v2 | `crates/lugh-common/schema/lugh-v2.json` | `lugh-cli` |
| Release note | `docs/releases/phase-3.md` | — |

## Work breakdown

### 1. lugh-stored (`space.lugh.Store1`, system bus, ADR-019)
- [ ] Source backends behind one `Source` trait (`search`, `details`, `install`, `remove`, `updates`, `progress`):
  - **apt**: PackageKit over D-Bus (`org.freedesktop.PackageKit`, `packagekit` with the aptcc backend). Transactions stream progress to clients.
  - **Flatpak**: `libflatpak` bindings (system installation by default, per-user optional). Flathub is added on first use with consent. Its "verified" badge is surfaced.
  - **Windows**: delegates to `lugh-bridged` (user session) for recipe-based installs; stored only orchestrates and lists.
- [ ] Metadata: AppStream (Debian DEP-11 catalogs through `appstream` and the Flathub appstream). Merge by AppStream ID, so one app card shows every available source. Source picker logic: prefer Flatpak for desktop GUI apps that are verified on Flathub, apt for system tools and CLI, and recipes only for Windows-only apps. Users can always override.
- [ ] **Windows-aware search**: `data/store/alternatives.toml`:
  ```toml
  [[app]]
  windows = ["Notepad++", "notepad++.exe"]
  native = []                                   # none exists
  alternatives = ["org.kde.kate", "org.gnome.TextEditor"]
  recipe = "notepad-plus-plus"                  # run the Windows version
  note = "Kate offers tabs, syntax highlighting and plugins."
  [[app]]
  windows = ["Photoshop", "Adobe Photoshop"]
  alternatives = ["org.kde.krita", "org.gimp.GIMP", "com.github.PintaProject.Pinta"]
  recipe = ""                                   # no working recipe — say so
  note = "Recent Photoshop versions don't run reliably on Wine."
  ```
  Seed ~150 common Windows apps. Search ranks: native exact match > alternatives > recipe. The result card explains *why* it's suggested.
- [ ] Polkit: `space.lugh.store.install` (auth_admin_keep for apt; allowed for active local users for Flatpak system installs, matching Flatpak's own policy), `space.lugh.store.remove`, `space.lugh.store.repo-add` (auth_admin).
- [ ] CLI: `lugh store search|info|install|remove|list|updates`.

### 2. lugh-store (UI)
- [ ] Home: featured (curated, refreshed with `lugh-store-data` updates), categories, "Coming from Windows?" collection (alternatives for the 30 most common apps), plus Office suites (LibreOffice, OnlyOffice, per ADR-013).
- [ ] App page: screenshots, description, source picker (badges: Debian, Lugh, Flathub ✓, Windows), size, permissions summary (Flatpak), license, links, and a single install button with progress.
- [ ] Windows result page: the compatibility tier from the recipe (Platinum/Gold/Silver/Broken), profile used, known issues, and an "Install Windows version" button.
- [ ] Installed tab (uninstall, open, source shown) and Updates tab (shared with the update center).
- [ ] States: offline (cached catalog + banner), empty search ("No results — try the Windows name, or browse categories"), skeleton loading, and error banners with retry.

### 3. `.exe` / `.msi` / `.lnk` handling
- [ ] Register `lugh-bridge --open %f` for `application/x-ms-dos-executable`, `application/x-msdownload`, `application/x-msi`, `application/x-ms-shortcut`, `application/vnd.microsoft.portable-executable`.
- [ ] On open: hash the file and look it up in the recipe catalog (known installer → use that recipe). Otherwise, ask "What is this?" with three choices: Game / App / Old program. This picks the profile and offers a new bottle or an existing one. Advanced: Custom.
- [ ] A non-PE file renamed to `.exe` → show an error with an explanation.

### 4. Runners (Lugh repo)
- [ ] `lugh-wine-stable` / `lugh-wine-staging`: rebuild or mirror the WineHQ Debian trixie packages into the Lugh repo, installed side by side under `/opt/lugh/wine/<version>/` so bottles can pin a version. WoW64 build (no i386 multiarch needed for Wine ≥ 9 new-WoW64) where it's stable. Otherwise depend on i386 libs.
- [ ] `umu-launcher`: package the upstream release. Bridge downloads Proton builds (GE-Proton / UMU-Proton) into `~/.local/share/lugh/bridge/runners/proton/` on demand, with checksum verification.
- [ ] DXVK and VKD3D-Proton: versions downloaded into the shared runners dir, installed per bottle by symlink or copy. Updating these never changes existing bottles unless the user opts in.
- [ ] `winetricks` (Debian contrib) for verbs: `corefonts`, `vcrun2022`, `dotnet48`, and so on.

### 5. lugh-bridged (`space.lugh.Bridge1`, session bus, ADR-016)
- [ ] Bottle layout: `~/.local/share/lugh/bridge/bottles/<bottle>/{prefix/, bottle.toml, logs/, icons/}`. `bottle.toml` records the runner + version, profile, DLL overrides, env vars, the winetricks verbs applied, launch entries and the recipe ID + version.
- [ ] Profiles:
  - **Gaming**: umu + Proton, DXVK, VKD3D-Proton, `WINEFSYNC=1`, `gamemoderun`, MangoHud toggle, `PROTON_ENABLE_NVAPI` on NVIDIA.
  - **Apps**: WineHQ stable, `corefonts`, `vcrun2022`, optional `dotnet48`, Windows 10 version, DPI follows Lugh scale.
  - **Legacy**: 32-bit prefix (`WINEARCH=win32` with an older Wine pinned if needed), Windows XP/7 version, virtual desktop option.
  - **Custom**: everything editable (runner, version, env, DLL overrides, winetricks, registry import).
- [ ] Every bottle run is launched in a systemd scope `app-lugh-bridge-<bottle>-<id>.scope` (ADR-015), so it's visible in Tasks.
- [ ] Integration: create `.desktop` entries in `~/.local/share/applications/lugh-bridge-<bottle>-<app>.desktop` with icons extracted from the exe (`icoutils`/`wrestool`), and file associations per bottle. System-tray icons work through the Wine tray → SNI (the shell's tray).
- [ ] Bottle operations: create, clone, rename, delete, backup (`tar.zst` of the prefix minus caches), restore, "Run .exe in this bottle", open the `C:` drive, run `winecfg`/`regedit`/`taskmgr`, kill all processes, and view logs.
- [ ] Unified **games library** view: Bridge games + native Steam library (read `~/.local/share/Steam/steamapps/*.acf`) + Heroic library (if installed), with launch buttons. A launcher of launchers, not a replacement.
- [ ] CLI: `lugh bridge list|create|run|install <recipe>|backup|restore|delete|logs`.

### 6. Recipe format v1 + first recipes
- [ ] Format (`recipes/<id>/recipe.toml`):
  ```toml
  id = "notepad-plus-plus"
  name = "Notepad++"
  version = 1                         # recipe revision
  profile = "apps"
  runner = { type = "wine", channel = "stable", min = "10.0" }
  tier = "platinum"                   # platinum|gold|silver|broken
  tested = { date = "2026-11-01", lugh = "0.3" }
  [download]
  url = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7/npp.8.7.Installer.x64.exe"
  sha256 = "…"
  [[steps]]
  winetricks = ["corefonts"]
  [[steps]]
  run = { file = "$DOWNLOAD", args = ["/S"] }    # silent install
  [launch]
  exe = "C:/Program Files/Notepad++/notepad++.exe"
  mime = ["text/plain"]
  [notes]
  known_issues = []
  ```
  Steps allowed: `winetricks`, `run`, `dll_override`, `registry`, `env`, `copy`. **No arbitrary shell commands** in official recipes. Local user recipes may opt into `shell`, with a warning.
- [ ] Catalog: `index.json` signed with **minisign**. Bridge verifies the signature and every download's `sha256`. A failed checksum aborts the install.
- [ ] First recipes (each tested on Intel, AMD and NVIDIA):
  1. Notepad++ (Apps)
  2. 7-Zip (Apps)
  3. WinRAR (Apps)
  4. IrfanView (Apps)
  5. Epic Games Launcher (Gaming). **Recommend the Heroic Flatpak** (`com.heroicgameslauncher.hgl`) as the primary route in the Store; the recipe is the "official Windows client" alternative.
  6. EA app (Gaming)
  7. Ubisoft Connect (Gaming)
  8. Battle.net (Gaming)
  9. GOG Galaxy (Gaming); Heroic is also suggested
  10. An older game demo or freeware title (Legacy), for example a freely redistributable classic, to prove the 32-bit path
  11. Microsoft .NET 4.8 app sample (Apps), to prove the `dotnet48` path
  12. A DirectX 12 freeware/demo game (Gaming), to prove VKD3D-Proton
- [ ] The Store lists **native Steam** (`steam-installer`) prominently for gaming. Bridge never installs Steam for Windows.

### 7. lugh-updated (`space.lugh.Update1`) + rollback
- [ ] Sources: apt (through PackageKit `GetUpdates`/`UpdatePackages`), Flatpak updates, fwupd (`org.freedesktop.fwupd`), and Bridge runner updates (opt-in per bottle).
- [ ] Policy: security updates daily in the background (download only by default, apply with the user's consent or automatically if enabled). Regular updates are offered weekly. Notifications go through the shell.
- [ ] Snapshots (ADR-009): `snapper` pre/post around every apt transaction (Debian's snapper apt hook, verified), plus a named snapshot `lugh-update-<ts>` before each update-center run.
- [ ] Package or ship `grub-btrfs` with `grub-btrfsd` watching `/.snapshots`, so snapshots appear in a GRUB submenu ("Lugh snapshots").
- [ ] **Rollback UX**: booting a read-only snapshot shows a banner, "You're running a snapshot from <date>", with a button **Make this the current system**. That runs `snapper rollback` (verified to work with our flat `@` layout; if not, a custom rollback that renames subvolumes and updates the default subvolume, prototyped first). Settings → Updates lists snapshots with "Restore on next boot".
- [ ] Update center UI is shared with the Store's Updates tab: grouped by System / Apps / Firmware / Windows runners, with changelogs where available, and "Restart required" handling.

### 8. Lughfile v2 + installer restore
- [ ] Schema v2 adds:
  ```toml
  [store]
  apps = [ { id = "org.kde.krita", source = "flatpak" }, { id = "htop", source = "apt" } ]
  [bridge]
  bottles = [ { name = "notepadpp", recipe = "notepad-plus-plus" },
              { name = "epic", recipe = "epic-games-launcher", backup = "bridge/epic.tar.zst" } ]
  ```
  `lugh export` includes recipe-based bottles, and optionally full bottle backups (large; off by default, warned, and stored with Git LFS if enabled). `lugh apply` recreates bottles by re-running recipes. v1 files migrate automatically.
- [ ] Calamares: a new page, **"Restore from my Lughfile"** (optional), takes a git URL (HTTPS public, or SSH with a pasted deploy key used only during install) plus a validation check. A Calamares Python job module (`installer/modules/lughfile/`) clones it into `/target/home/<user>/.config/lugh/` and enables a **first-boot** user service `lugh-firstboot-apply.service`, which runs `lugh apply --yes` with a progress notification once the network and session are up. Running at first boot instead of in the installer chroot avoids fragile chroot Flatpak and Wine setup.

## Acceptance criteria

1. Searching "vlc", "krita" and "htop" in the Store shows a single card per app with the right sources. Install and remove work for apt and Flatpak with live progress.
2. Searching "Notepad++" offers Kate (alternative) and "Run the Windows version". Installing it creates a bottle, a launcher entry and an icon, and the app opens and saves a file.
3. Searching "Photoshop" shows alternatives and states that no working recipe exists, with no dead-end button.
4. Searching "Valorant" shows a clear "not supported: kernel anti-cheat" message.
5. Double-clicking an unknown `.exe` opens Bridge, asks Game/App/Old program, creates a bottle and runs it in its own scope (visible in Tasks).
6. Installing two Apps-profile recipes produces two separate prefixes. Breaking one (deleting a DLL) leaves the other working.
7. All 12 recipes install and launch on reference hardware at their declared tier or better. Checksum mismatch and bad signature both abort safely (tested with fixtures).
8. The games library shows Bridge games and native Steam games together, and launches both.
9. The update center applies apt, Flatpak and fwupd updates (with fwupd tested on at least one LVFS-supported laptop or the `fwupd` test device). A `lugh-update-*` snapshot is created first.
10. After a deliberately broken update (a test package that breaks login), the user can boot the pre-update snapshot from GRUB and use **Make this the current system**. After a reboot the system is healthy.
11. `lugh export` includes `[store]` and `[bridge]`. On a fresh install with "Restore from my Lughfile", first boot recreates the apps and recipe bottles without manual steps.
12. The Minimal profile still installs without Store or Bridge, and adding them from Settings works.

## Testing

**Automated**
- Unit: source merge and ranking, alternatives matching (fuzzy, case- and suffix-insensitive), recipe parser and validator, minisign verification, sha256 enforcement, `bottle.toml` round-trip, Lughfile v1→v2 migration, update planning.
- Integration (QEMU, installed image, network): Store installs through `busctl` for apt and Flatpak; Bridge installs 7-Zip and Notepad++ headless (Xvfb-free: run under a nested `cage` in CI), checking that the files exist and the process starts; the snapshot + rollback scenario with a test package; the Calamares Lughfile restore with a fixture repo served locally.
- Recipe CI: a nightly job re-runs every recipe in a VM with a GPU-less profile (Apps/Legacy). Gaming recipes run weekly on a self-hosted GPU runner. Failures open issues automatically.

**Manual checklist**
- [ ] Gaming smoke test on Intel, AMD and NVIDIA (proprietary): one DX11 and one DX12 title through Proton, with MangoHud showing FPS.
- [ ] Controller works in a Bridge game (Steam Input not involved).
- [ ] Offline Store behavior.
- [ ] Rollback on real hardware with LUKS + Btrfs.
- [ ] Windows-user walkthrough: a tester who has never used Linux installs 3 apps they know from Windows, with no help.

## Performance budget for this phase

| Metric | Budget |
|---|---|
| Store cold start → home rendered (cached catalog) | ≤ 800 ms |
| Store search results (local index) | ≤ 100 ms |
| `lugh-stored` / `lugh-bridged` / `lugh-updated` idle | exit after 60 s idle; ≤ 40 MB RSS while active (excluding PackageKit) |
| Bridge bottle creation (Apps profile, runners cached) | ≤ 30 s |
| Game launch overhead vs plain `umu-run` | ≤ 1 s |
| Background update check | ≤ 1% CPU averaged over the check; no UI jank |
| Idle session RAM (Standard profile) | ≤ 800 MB (Phase 5 target is 750 MB) |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Recipes rot as vendors change installers or URLs | broken installs, bad reputation | pinned URLs + sha256; nightly recipe CI; tiers shown honestly; the "known issues" field |
| Launchers (EA, Ubisoft, Battle.net) break often under Wine | Gaming promise undermined | route through Proton (umu) with protonfixes; recommend Heroic or Steam where better; weekly GPU CI |
| Kernel anti-cheat games | user frustration | said clearly in the Store and docs; not attempted |
| WineHQ packaging and WoW64 in the Lugh repo is a maintenance burden | delays | mirror upstream builds where licensing and format allow; pin versions; side-by-side installs |
| PackageKit aptcc quirks (debconf prompts, held packages) | stuck transactions | non-interactive frontend defaults; surface errors clearly; fall back to a guided terminal for rare debconf cases |
| `snapper rollback` with a flat `@` subvolume layout | rollback fails | prototype early in this phase; a custom rollback path if needed; tested in CI |
| Downloading installers from vendors is a supply-chain risk | malware | sha256 pinning, a signed catalog, no shell steps in official recipes, and Shield integration in Phase 4 |
| Legal: distributing proprietary installers or fonts | takedowns | never rehost vendor binaries; recipes only point to official URLs; corefonts through winetricks (the user downloads them) |
| Store scope is huge (3 sources + Windows) | slip | ship apt + Flatpak first (milestone 3a), then Bridge (3b), then updates and rollback (3c), each with its own ISO |
| Lughfile restore during install depends on the network and git auth | failed restore | first-boot apply with retry; clear error and "apply later" option; a public HTTPS repo is the documented happy path |

## Exit checklist

- [ ] All acceptance criteria pass (milestones 3a, 3b and 3c each released as ISOs).
- [ ] ISO builds in CI (DoD 1); boot, install, Store, Bridge and rollback integration tests pass (DoD 2).
- [ ] Store and Bridge UIs follow DESIGN-SYSTEM with every state, including offline and broken tiers (DoD 3).
- [ ] `Store1`, `Bridge1` and `Update1` APIs documented, CLIs shipped, polkit policies installed, unit tests green (DoD 4).
- [ ] Performance budgets met (DoD 5).
- [ ] `specs/store.md`, `specs/bridge.md`, `specs/lughfile.md`, `specs/installer.md` and `specs/system-base.md` (updates and rollback) updated. ADRs added (e.g. rollback mechanism, Proton source, Heroic recommendation) (DoD 6).
- [ ] `docs/releases/phase-3.md` written, including the anti-cheat limitation and the recipe tier list (DoD 7).
