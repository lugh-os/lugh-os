//! Shared building blocks for Lugh OS components.
//!
//! Every Lugh daemon, CLI and UI core links this crate so that logging,
//! configuration and D-Bus naming behave the same everywhere:
//!
//! - [`logging`]: `tracing` setup driven by the `LUGH_LOG` environment variable,
//!   with output that reads well in journald.
//! - [`config`]: XDG directory helpers (`~/.config/lugh/`, `~/.local/share/lugh/`)
//!   and typed TOML loading.
//! - [`dbus`]: the `space.lugh.*` naming scheme and thin `zbus` connection helpers.

pub mod config;
pub mod dbus;
pub mod logging;

pub use config::{ConfigError, config_dir, data_dir, load_toml, load_toml_or_default};
pub use dbus::{BUS_PREFIX, bus_name, object_path};
pub use logging::{LOG_ENV, LoggingError, init_logging};
