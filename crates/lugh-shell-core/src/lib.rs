//! Qt-free core of `lugh-shell` (docs/specs/shell.md).
//!
//! Everything here is plain Rust so it can be unit-tested and benchmarked
//! without Qt. The cxx-qt bridge in `ui/shell/` wraps these types as QObjects
//! whose names match the QML contract in `ui/shell/qml/Lugh/Shell/Services.qml`.
//!
//! - [`launcher`]: desktop-entry index, fuzzy search with frequency/recency
//!   ranking, Windows-name aliases, calculator.
//! - [`wm`]: the `CompositorAdapter` trait and its Hyprland IPC implementation.
//! - [`launch`]: starting apps in `app-lugh-<appid>-<rand>.scope` units (ADR-015).
//! - [`config`]: `~/.config/lugh/desktop.toml` v0 schema.
//! - [`services`]: the live system services behind the QML `Services` singleton
//!   and the JSON bridge that carries them (docs/specs/shell-bridge.md).

pub mod config;
pub mod launch;
pub mod launcher;
pub mod services;
pub mod wm;
