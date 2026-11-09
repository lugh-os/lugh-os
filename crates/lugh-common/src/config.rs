//! Configuration paths and TOML loading (ARCHITECTURE §7).
//!
//! User files live under the XDG base directories, in a `lugh` subdirectory:
//! [`config_dir`] (`~/.config/lugh/`) and [`data_dir`] (`~/.local/share/lugh/`).
//! `XDG_CONFIG_HOME` / `XDG_DATA_HOME` are honoured when set to absolute paths,
//! as the XDG Base Directory spec requires.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;

/// Name of the Lugh subdirectory inside each XDG base directory.
pub const APP_DIR: &str = "lugh";

/// System-wide configuration directory (holds the optional `system.toml`).
pub const SYSTEM_CONFIG_DIR: &str = "/etc/lugh";

/// System-wide state directory for Lugh daemons.
pub const SYSTEM_STATE_DIR: &str = "/var/lib/lugh";

/// Errors from config path resolution and loading.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// Neither the XDG variable nor `HOME` gave a usable directory.
    #[error("cannot locate the home directory: {0} and HOME are unset or not absolute")]
    NoHome(&'static str),

    /// The file could not be read.
    #[error("cannot read {}: {source}", path.display())]
    Read {
        /// File that failed.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },

    /// The file is not valid TOML or does not match the expected shape.
    #[error("invalid TOML in {}: {source}", path.display())]
    Parse {
        /// File that failed.
        path: PathBuf,
        /// Underlying parse error (carries line and column).
        #[source]
        source: toml::de::Error,
    },
}

/// The user's Lugh config directory: `$XDG_CONFIG_HOME/lugh`, falling back to
/// `~/.config/lugh`. The directory is not created.
pub fn config_dir() -> Result<PathBuf, ConfigError> {
    xdg_app_dir("XDG_CONFIG_HOME", ".config")
}

/// The user's Lugh data directory: `$XDG_DATA_HOME/lugh`, falling back to
/// `~/.local/share/lugh`. The directory is not created.
pub fn data_dir() -> Result<PathBuf, ConfigError> {
    xdg_app_dir("XDG_DATA_HOME", ".local/share")
}

fn xdg_app_dir(var: &'static str, home_relative: &str) -> Result<PathBuf, ConfigError> {
    resolve_xdg(
        std::env::var_os(var),
        std::env::var_os("HOME"),
        home_relative,
    )
    .map(|base| base.join(APP_DIR))
    .ok_or(ConfigError::NoHome(var))
}

/// XDG base directory resolution, kept free of process state for testing.
fn resolve_xdg(
    xdg: Option<OsString>,
    home: Option<OsString>,
    home_relative: &str,
) -> Option<PathBuf> {
    let absolute = |v: OsString| Some(PathBuf::from(v)).filter(|p| p.is_absolute());
    xdg.and_then(absolute)
        .or_else(|| home.and_then(absolute).map(|h| h.join(home_relative)))
}

/// Reads and deserializes a TOML file.
pub fn load_toml<T: DeserializeOwned>(path: impl AsRef<Path>) -> Result<T, ConfigError> {
    let path = path.as_ref();
    let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
        path: path.to_owned(),
        source,
    })?;
    toml::from_str(&text).map_err(|source| ConfigError::Parse {
        path: path.to_owned(),
        source,
    })
}

/// Like [`load_toml`], but a missing file yields `T::default()`.
///
/// Other errors (permissions, bad TOML) are still returned.
pub fn load_toml_or_default<T: DeserializeOwned + Default>(
    path: impl AsRef<Path>,
) -> Result<T, ConfigError> {
    match load_toml(path) {
        Err(ConfigError::Read { source, .. }) if source.kind() == io::ErrorKind::NotFound => {
            Ok(T::default())
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::fs;

    #[derive(Debug, Default, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields)]
    struct Desktop {
        theme: String,
        #[serde(default)]
        scale: Option<f64>,
    }

    fn write(dir: &tempfile::TempDir, name: &str, text: &str) -> PathBuf {
        let path = dir.path().join(name);
        fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn loads_valid_toml() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(&dir, "desktop.toml", "theme = \"light\"\nscale = 1.25\n");
        let cfg: Desktop = load_toml(&path).unwrap();
        assert_eq!(
            cfg,
            Desktop {
                theme: "light".into(),
                scale: Some(1.25)
            }
        );
    }

    #[test]
    fn missing_file_is_read_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("absent.toml");
        let err = load_toml::<Desktop>(&path).unwrap_err();
        assert!(matches!(&err, ConfigError::Read { path: p, .. } if *p == path));
    }

    #[test]
    fn missing_file_or_default() {
        let dir = tempfile::tempdir().unwrap();
        let cfg: Desktop = load_toml_or_default(dir.path().join("absent.toml")).unwrap();
        assert_eq!(cfg, Desktop::default());
    }

    #[test]
    fn bad_toml_is_parse_error_with_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(&dir, "bad.toml", "theme = \n");
        let err = load_toml_or_default::<Desktop>(&path).unwrap_err();
        assert!(matches!(err, ConfigError::Parse { .. }));
        assert!(err.to_string().contains("bad.toml"));
    }

    #[test]
    fn wrong_shape_is_parse_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(&dir, "shape.toml", "theme = 3\n");
        assert!(matches!(
            load_toml::<Desktop>(&path),
            Err(ConfigError::Parse { .. })
        ));
    }

    #[test]
    fn xdg_var_wins_when_absolute() {
        let got = resolve_xdg(Some("/x/cfg".into()), Some("/home/u".into()), ".config");
        assert_eq!(got, Some(PathBuf::from("/x/cfg")));
    }

    #[test]
    fn falls_back_to_home() {
        let home = Some(OsString::from("/home/u"));
        assert_eq!(
            resolve_xdg(None, home.clone(), ".config"),
            Some(PathBuf::from("/home/u/.config"))
        );
        // Relative and empty XDG values are ignored per the spec.
        assert_eq!(
            resolve_xdg(Some("rel".into()), home.clone(), ".local/share"),
            Some(PathBuf::from("/home/u/.local/share"))
        );
        assert_eq!(
            resolve_xdg(Some("".into()), home, ".config"),
            Some(PathBuf::from("/home/u/.config"))
        );
    }

    #[test]
    fn no_home_is_none() {
        assert_eq!(resolve_xdg(None, None, ".config"), None);
        assert_eq!(resolve_xdg(None, Some("relative".into()), ".config"), None);
    }

    #[test]
    fn public_dirs_end_in_lugh() {
        // HOME is set in any normal test environment.
        if let (Ok(c), Ok(d)) = (config_dir(), data_dir()) {
            assert!(c.ends_with(APP_DIR) && c.is_absolute());
            assert!(d.ends_with(APP_DIR) && d.is_absolute());
        }
    }
}
