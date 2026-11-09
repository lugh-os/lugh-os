# Contributing to Lugh

Thanks for helping build Lugh. This page covers how changes get in: where the plans live, how to build, how to write commits, and the rules code and UI must follow.

## Read first

| What | Where |
|---|---|
| What Lugh is and who it's for | [docs/VISION.md](docs/VISION.md) |
| Build order and phases | [docs/ROADMAP.md](docs/ROADMAP.md), [docs/phases/](docs/phases/) |
| How the pieces fit, repo layout | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Component specs | [docs/specs/](docs/specs/) |
| Decisions (ADRs) | [docs/DECISIONS.md](docs/DECISIONS.md) |
| Colors, type, motion, states | [docs/DESIGN-SYSTEM.md](docs/DESIGN-SYSTEM.md) |

- A change that alters behaviour described in a spec updates that spec in the same PR.
- A new major decision (a dependency, a protocol, a default) gets a new ADR in `DECISIONS.md`. Specs link to ADRs instead of repeating the reasoning.
- Each doc shows its status at the top: **Draft**, **Approved** or **Implemented**.

## Build and run

Set up your machine with [docs/dev/setup.md](docs/dev/setup.md), then:

```sh
make help         # every target, with a one-line description
make iso          # build the ISO inside the Debian trixie build container
make run-uefi     # boot it in QEMU
make test-boot    # headless boot test in all firmware modes
```

ISOs and packages are always built inside the Debian trixie container (`scripts/build-env/Containerfile`), never with the host's live-build. Rust and QML code builds on the host.

## Branches and pull requests

1. Fork, or create a branch from `main` named `<type>/<short-topic>`, e.g. `feat/grub-theme` or `fix/boot-marker-timeout`.
2. Keep each PR to one topic. Small PRs get reviewed faster.
3. Before pushing, run the checks CI runs (see [Code style](#code-style)) and, if you touched `iso/`, `branding/` or `packaging/`, `make iso && make test-boot`.
4. Open the PR against `main`. Describe what changed and why, link the phase task, spec section or ADR it implements, and add screenshots or a short screen recording for any visible change.
5. CI must be green and one maintainer must approve. PRs are merged with **squash**, so the PR title must itself be a conventional commit.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/). Changelogs and version bumps are generated from them.

```
<type>(<scope>): <summary in the imperative, ≤ 72 chars>

<body: what and why, wrapped at 72>

Signed-off-by: Your Name <you@example.com>
```

- **Types:** `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`.
- **Scopes** follow the top-level directory or component: `iso`, `branding`, `common`, `shell`, `compositor`, `installer`, `packaging`, `ci`, `docs`, …
- Breaking changes: add `!` after the type/scope (`feat(shell)!: …`) and a `BREAKING CHANGE:` footer.

Examples:

```
feat(branding): add GRUB theme with Inter font
fix(iso): pin Mozilla repo so firefox wins over firefox-esr
docs(specs): describe boot marker in build-and-release
```

## Sign your work (DCO)

Every commit must carry a `Signed-off-by:` line certifying the [Developer Certificate of Origin](https://developercertificate.org/): that you wrote the change, or otherwise have the right to submit it under the project's license. Use your real name and an email you can be reached at.

```sh
git commit -s                       # adds the line for you
git commit --amend -s --no-edit     # fix the last commit
git rebase --signoff main           # sign every commit on your branch
```

PRs with unsigned commits are not merged.

## Code style

CI enforces all of these; run them locally before you push.

| Language | Rules | Command |
|---|---|---|
| Rust | `rustfmt` defaults; no clippy warnings; toolchain pinned in `rust-toolchain.toml` | `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` |
| QML | `qmllint` clean; components from `ui/components/` (LughUI) instead of one-off styling | `qmllint ui/**/*.qml` |
| Shell | `#!/usr/bin/env bash` with `set -euo pipefail`; `shellcheck` clean | `shellcheck scripts/**/*.sh` |
| Debian packaging | `lintian` with no errors | `lintian <package>.deb` |
| Everything | [`.editorconfig`](.editorconfig): UTF-8, LF, 4 spaces for Rust/QML/shell, 2 for YAML/JSON/TOML/Markdown, tabs in Makefiles | your editor's EditorConfig support |

Also:

- New source files start with an SPDX header: `// SPDX-License-Identifier: GPL-3.0-or-later` (or `#` for shell/TOML).
- D-Bus names use the placeholder `space.lugh.*` until a domain is chosen.
- Performance is a feature: changes on a hot path (compositor, shell, boot) note their effect against the budgets in the phase doc.

## Design system rule

Every piece of UI follows [docs/DESIGN-SYSTEM.md](docs/DESIGN-SYSTEM.md). In particular:

- Use design-system tokens (color, type, spacing, radius, motion) — never hard-coded values.
- **Every interactive component implements all states** from DESIGN-SYSTEM §7: hover, pressed, keyboard focus, selected, disabled, loading, empty and error. A PR that adds a component without them is not done.
- Light theme is the default; check your change in dark too.
- Keyboard focus is always visible, information is never conveyed by color alone, and motion respects "reduce motion" (DESIGN-SYSTEM §10).
- Shared components go in `ui/components/` so all apps and all three desktop modes stay consistent.

## Reporting bugs and security issues

Open an issue with the Lugh version (`cat /etc/os-release`), what you did, what you expected and what happened; attach `journalctl -b` output when relevant. Report security issues privately to the maintainers instead of in a public issue.

## License

By contributing you agree that your contributions are licensed under [GPL-3.0-or-later](LICENSE).
