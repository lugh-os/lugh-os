# Phase 7 — Public beta

> Status: Draft · Size: L · Depends on: Phases 0–6 · Specs: [../specs/build-and-release.md](../specs/build-and-release.md), [../specs/system-base.md](../specs/system-base.md), [../specs/bridge.md](../specs/bridge.md) · ADRs: ADR-003, ADR-022

## Goal

Get Lugh into the hands of outside users on real hardware. That means a public, signed apt repo with mirrors, stable and beta release channels, signed ISOs, a website with docs, a way to report bugs (with opt-in crash reports), community recipe submissions, the first four languages, and completed accessibility and security reviews. The phase ends when the **1.0 exit criteria** are met.

## Scope

**In**
- A hardware test matrix and a certification process.
- A public apt repository and mirror network; release channels `stable` and `beta`.
- Signed ISOs, checksums and reproducibility reporting.
- A website (download, docs, hardware list, recipes catalog) and user documentation.
- A bug tracker with issue templates, opt-in crash reporting and a feedback app.
- A community pipeline for Bridge recipes: submission, review, signing and ratings.
- Translations: **English, Kinyarwanda, French, Swahili** first (the founder's audience is in Rwanda and East Africa), on a translation platform.
- An accessibility audit (WCAG 2.2 AA) and a security review (internal + external).
- The beta program: recruiting testers, the feedback loop, and triage SLAs.

**Out (deferred)**
- arm64 images (after 1.0).
- Paid support or an OEM preinstall program.
- More languages beyond the first four (the pipeline supports them; community-driven after 1.0).

## Deliverables

| Deliverable | Path in repo / location | Package / artifact |
|---|---|---|
| Hardware matrix and certification checklist | `docs/hardware/` | n/a |
| Hardware report tool (`lugh report-hw`) | `crates/lugh-cli/src/hw.rs` | `lugh-cli` |
| Public apt repo (stable, beta) + mirror sync scripts | `packaging/repo/` | `repo.lugh` (placeholder) |
| `lugh-archive-keyring` and channel switcher | `packaging/keyring/`, Settings → Updates | `lugh-archive-keyring` |
| Signed ISO release pipeline | `.github/workflows/release.yml` | `lugh-<ver>-amd64.iso`, `SHA256SUMS`, `SHA256SUMS.sig` |
| Website + docs site | separate repo `lugh-website` (static site) | n/a |
| Feedback & crash reporter (opt-in) | `ui/feedback/`, `crates/lugh-crashd/` | `lugh-feedback` |
| Recipe catalog service + review workflow | `recipes/` → separate repo `lugh-recipes` | signed catalog index |
| Translation pipeline (gettext/Qt `.ts`, platform sync) | `i18n/` | `lugh-l10n-*` |
| Accessibility audit report | `docs/audits/a11y-beta.md` | n/a |
| Security review report and fixes | `docs/audits/security-beta.md` | n/a |
| Release notes and known issues | `docs/releases/beta-N.md` | n/a |

## Work breakdown

### 1. Hardware matrix and certification
- [ ] Define tiers. **Certified** (tested every release), **Community-verified** (reports from `lugh report-hw`), **Known issues**.
- [ ] Minimum matrix for Certified:

| Area | Must cover |
|---|---|
| GPU | Intel (Xe/Arc), AMD (RDNA2/3), NVIDIA (Turing+ proprietary; open kernel module where supported) |
| Hybrid graphics | Intel + NVIDIA laptop (PRIME offload, "Run on dedicated GPU" in the launcher), AMD + AMD |
| Wi-Fi | Intel AX2xx/BE2xx, Realtek RTL8852/8822 family, MediaTek MT7921/7922, Broadcom (known pain; document it) |
| Laptop power | Suspend/resume (s2idle and S3), lid close, battery reporting, brightness keys, power profiles |
| Displays | Internal HiDPI at 125/150%, external 4K, VRR monitor, USB-C/Thunderbolt dock hotplug |
| Input | Precision touchpads, gestures, ThinkPad TrackPoint, common gaming mice and controllers (Xbox, DualSense) |
| Audio | Intel SOF laptops (common failure area), USB headsets, Bluetooth A2DP/HFP |
| Firmware | fwupd-supported devices, Secure Boot on/off |

- [ ] `lugh report-hw`: collects anonymized hardware IDs and a pass/fail checklist (user-run, user-reviewed before upload).
- [ ] Publish the hardware list on the website, filterable by laptop model.

### 2. Repository, mirrors and channels
- [ ] Production repo on the chosen host (decision required: domain + hosting; see VISION §16), with a dedicated offline signing key (HSM or air-gapped) and online subkeys.
- [ ] Mirror network: a primary plus at least 2 mirrors, including one in East Africa for Rwandan users if available (mirrors through rsync; `apt-transport-https`).
- [ ] Channels: `beta` (fast, receives new phase work) and `stable` (beta + 2 weeks soak, no regressions). Switchable in Settings → Updates.
- [ ] Phased updates: roll out to a percentage of machines first, so a bad update can be paused.
- [ ] Emergency process: pull a bad package, publish a fix, and post an advisory.

### 3. Release engineering
- [ ] Versioning scheme from [../specs/build-and-release.md](../specs/build-and-release.md) (e.g. `0.9-beta.N`).
- [ ] Signed ISOs: `SHA256SUMS` signed with the release key; verification instructions for Linux, Windows and macOS on the website.
- [ ] Reproducible-build checks: two independent CI builders must produce matching package hashes (report the delta for the ISO).
- [ ] Release checklist automation: changelog generation, known-issues page, mirror sync verification.

### 4. Website and documentation
- [ ] Pages: Home, Download (ISO + Windows Setup), Hardware, Recipes, Docs, Community, Privacy.
- [ ] User docs: installing (Windows Setup, USB), the three desktop modes, Store, Bridge (running Windows apps and games), Shield, Lughfile ("Back up your setup to GitHub"), Tasks, updates and rollback, troubleshooting.
- [ ] "Coming from Windows" guide: where things are, app equivalents, keyboard shortcuts.
- [ ] Contributor docs: building the ISO, the dev environment, code style, and how to write a recipe.
- [ ] Every page available in the four launch languages.

### 5. Bug reporting, crash reports and feedback
- [ ] Public bug tracker with templates (bug, hardware, recipe request, feature request) that ask for `lugh report-hw` output.
- [ ] `lugh-crashd`: catches crashes of Lugh components via `systemd-coredump`, builds a report (stack trace with debuginfod symbols, versions). **Opt-in, off by default**, asked once at first boot, with a preview of exactly what is sent and the option to send per crash.
- [ ] Feedback app in the shell ("Send feedback"): a short form + optional screenshot (user-picked) + optional logs.
- [ ] Privacy policy that states no telemetry by default and lists what opt-in reports contain and their retention.
- [ ] Triage SLA: new issues labeled within 3 working days; crashers and data-loss bugs within 24 hours.

### 6. Community recipes (Bridge)
- [ ] Separate `lugh-recipes` repo: recipe format linted in CI, a sandboxed test install in a VM runner (quarantined Bridge), and screenshot proof.
- [ ] Review workflow: two approvals (one maintainer), and a signed catalog index published to the store.
- [ ] Ratings per recipe (Works, Works with tweaks, Broken) from users, shown in the Store, with an anti-abuse rate limit.
- [ ] Launch catalog targets: Epic (or Heroic in the Store), GOG Galaxy, EA app, Ubisoft Connect, Battle.net, plus 30 popular Windows apps (for example Notepad++, IrfanView, 7-Zip GUI, foobar2000, older Office versions where licensing allows).
- [ ] Honest compatibility page: games with kernel-level anti-cheat that blocks Linux won't work, with a list.

### 7. Translations
- [ ] All strings extracted (Qt `.ts` for QML and gettext for daemons/CLI); no hard-coded UI text (CI lint).
- [ ] A translation platform (Weblate, self-hosted or hosted) connected to the repo.
- [ ] **Kinyarwanda, English, French, Swahili** at 100% for the shell, installer, Windows Setup, Settings, Store and Welcome before 1.0. Other apps ≥ 90%.
- [ ] Locale data: keyboard layouts, date and number formats, default timezone suggestions (Africa/Kigali, Africa/Nairobi and so on), font coverage checks.
- [ ] Native-speaker review for Kinyarwanda and Swahili (recruit community reviewers; technical terms glossary).

### 8. Accessibility audit
- [ ] WCAG 2.2 AA audit of the shell, the greeter, the installer and all Lugh apps (contrast, focus, keyboard, labels, reduced motion).
- [ ] Screen reader pass with Orca on every core flow: install, log in, launch apps, change settings, install from Store.
- [ ] Fix all blockers and serious issues; publish the report.

### 9. Security review
- [ ] Internal review: polkit actions (least privilege), D-Bus APIs (input validation), Shield escape suite, Bridge recipe execution, Windows Setup disk operations, update signing chain.
- [ ] External review (paid or community) focused on Shield, the daemons running as root, and the update/recipe signing.
- [ ] Security policy (`SECURITY.md`), a private disclosure address, and an advisory process.
- [ ] Debian security updates flow through within 24 hours (automated sync and rebuild of affected images).

### 10. Beta program
- [ ] Recruit 100+ testers across the matrix, including Windows switchers (not just Linux users) and testers in Rwanda.
- [ ] Beta releases every 2–4 weeks; each release has a focus (for example "laptops", "gaming", "Windows Setup").
- [ ] Measure: install success rate (opt-in), crash-free sessions (opt-in), top issues, time-to-fix.

## 1.0 exit criteria

1. Install success rate ≥ 95% across opt-in reports (both Windows Setup and USB).
2. No open **data-loss** or **security-critical** bugs; no unresolved crashers in the shell or compositor in the last two beta releases.
3. All Certified-tier hardware passes the full checklist.
4. Crash-free session rate ≥ 99% (opt-in data) over the final four weeks.
5. VISION §12 performance targets hold on the reference hardware.
6. Accessibility audit: no open blockers or serious issues.
7. External security review findings rated high or critical: all fixed.
8. Four launch languages at their coverage targets, with native-speaker review done.
9. Docs cover every core feature in all launch languages.
10. License decided (ADR-022 accepted) and every component's license file in place.

## Acceptance criteria (for this phase's own deliverables)

1. A fresh machine can verify the downloaded ISO's signature by following the website instructions in each launch language.
2. Switching between `beta` and `stable` in Settings works and is reflected in `apt policy`.
3. A phased rollout can be paused, and machines not yet updated don't receive the paused package.
4. A deliberately crashing test component produces a crash report only when the user has opted in, and the preview matches what is uploaded.
5. A community recipe goes from submission to signed catalog to installable in the Store, with a VM test run attached.
6. Kinyarwanda, French and Swahili can be selected at install (Calamares and Windows Setup) and persist into the desktop.
7. `lugh report-hw` produces a report the user can review before submitting it.

## Testing

**Automated**
- Release pipeline dry run each week: build, sign, publish to a staging repo, mirror sync check, QEMU install test from the staging repo.
- Upgrade tests: beta N → beta N+1 and stable → stable, with snapshots and rollback verified.
- i18n lint (untranslated or hard-coded strings) and pseudo-localization screenshots for layout overflow (long French and Kinyarwanda strings).
- Recipe CI: lint + sandboxed VM install.

**Manual**
- [ ] The full hardware matrix checklist per release (Certified tier).
- [ ] The "Coming from Windows" usability session with 5+ first-time Linux users per beta.
- [ ] Orca screen reader walkthrough per beta.

## Performance budget

All earlier budgets remain release gates. Added for beta:

| Metric | Budget |
|---|---|
| ISO size (Standard, amd64) | ≤ 3.5 GB |
| Update download for a typical monthly update | ≤ 300 MB (delta-friendly packaging) |
| Website download page load (3G profile) | ≤ 3 s |
| Mirror sync lag | ≤ 1 h behind primary |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Hardware diversity (Wi-Fi, audio, NVIDIA) overwhelms a small team | Poor first impressions | Clear tiers, a Certified list, honest known-issues, community verification through `report-hw` |
| Opt-in crash reporting gives too little data | Blind spots | Make opting in easy and transparent, send per-crash prompts, and run a tester cohort that opts in by default |
| Signing key compromise | Malicious updates | Offline primary key, subkey rotation, HSM where possible, documented revocation drill |
| Recipe catalog abused (malicious installers) | User harm, reputation | Two-person review, a sandboxed VM test, signed catalog, and quarantine by default for newly published recipes |
| Translation quality in Kinyarwanda/Swahili for technical terms | Confusing UI | Glossary, native reviewers, in-context screenshots for translators |
| Mirror/bandwidth costs, slow downloads in East Africa | Failed installs | Regional mirror, resumable downloads (Windows Setup already resumes), torrent option for the ISO |
| Scope creep from beta feedback | 1.0 slips | Feature freeze during beta; only fixes and exit-criteria work; feature requests go to a post-1.0 list |

## Exit checklist

- [ ] 1.0 exit criteria met and reviewed with the founder.
- [ ] Hardware list, docs and the privacy policy are live on the website in all four launch languages.
- [ ] Public signed repo and mirrors running; channel switching and phased updates verified.
- [ ] Accessibility and security audit reports published, with blockers fixed.
- [ ] ISO builds in CI from a clean checkout; QEMU boot and upgrade tests pass.
- [ ] All UIs follow DESIGN-SYSTEM.md with all states implemented.
- [ ] Every daemon API documented with CLI equivalents, polkit actions and unit tests.
- [ ] All performance budgets pass.
- [ ] Docs updated; decisions (hosting, license, signing) recorded in DECISIONS.md.
- [ ] Release note written in `docs/releases/phase-7.md`, plus the 1.0 release announcement draft.
