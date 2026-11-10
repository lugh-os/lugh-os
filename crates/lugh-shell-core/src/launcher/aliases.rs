//! Windows-name aliases ("control panel" → Settings, "cmd" → Terminal, …),
//! loaded from `data/aliases.toml` (built in) and
//! `/usr/share/lugh/launcher/aliases.toml` (merged on top when present).

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Deserialize;

/// The built-in alias table.
const EMBEDDED: &str = include_str!("../../data/aliases.toml");

/// Distribution override, merged on top of the built-in table.
pub const SYSTEM_ALIASES: &str = "/usr/share/lugh/launcher/aliases.toml";

/// What an alias opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AliasTarget {
    /// The first installed of `apps`, else the first installed app (non-terminal
    /// preferred) in one of `categories`.
    App {
        /// Candidate app ids, in preference order.
        apps: Vec<String>,
        /// Fallback desktop categories.
        categories: Vec<String>,
    },
    /// A settings page.
    Setting {
        /// Page path (`devices`).
        page: String,
        /// Row title.
        title: String,
        /// Symbolic icon name.
        icon: String,
    },
    /// A help card that opens a file.
    Help {
        /// File to open (`~` expanded).
        path: PathBuf,
        /// Row title.
        title: String,
        /// Row subtitle.
        subtitle: String,
        /// Symbolic icon name.
        icon: String,
    },
}

/// One alias entry: several names for one target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowsAlias {
    /// Names as typed (lowercase).
    pub names: Vec<String>,
    /// Target.
    pub target: AliasTarget,
    /// Only offered when this app is installed.
    pub requires: Option<String>,
}

/// A set of aliases.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AliasTable {
    aliases: Vec<WindowsAlias>,
}

/// Errors loading an alias file.
#[derive(Debug, thiserror::Error)]
pub enum AliasError {
    /// The file could not be read.
    #[error("cannot read {}: {source}", path.display())]
    Read {
        /// File that failed.
        path: PathBuf,
        /// Underlying error.
        #[source]
        source: std::io::Error,
    },
    /// Not valid TOML or not the expected shape.
    #[error("invalid alias table: {0}")]
    Parse(#[from] toml::de::Error),
    /// An `[[alias]]` with no target or several.
    #[error("alias {0:?} must have exactly one of apps/categories, setting or help")]
    Target(Vec<String>),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFile {
    #[serde(default)]
    alias: Vec<RawAlias>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAlias {
    names: Vec<String>,
    #[serde(default)]
    apps: Vec<String>,
    #[serde(default)]
    categories: Vec<String>,
    setting: Option<String>,
    help: Option<String>,
    title: Option<String>,
    subtitle: Option<String>,
    icon: Option<String>,
    requires: Option<String>,
}

impl AliasTable {
    /// The built-in table.
    pub fn embedded() -> Self {
        Self::parse(EMBEDDED).unwrap_or_else(|e| {
            tracing::error!(%e, "built-in alias table is invalid");
            Self::default()
        })
    }

    /// The built-in table with [`SYSTEM_ALIASES`] merged on top. A broken
    /// system file is logged and ignored.
    pub fn system() -> Self {
        let mut table = Self::embedded();
        match Self::load(Path::new(SYSTEM_ALIASES)) {
            Ok(Some(sys)) => table.merge(sys),
            Ok(None) => {}
            Err(e) => tracing::warn!(%e, "ignoring {SYSTEM_ALIASES}"),
        }
        table
    }

    /// Parses alias TOML.
    pub fn parse(text: &str) -> Result<Self, AliasError> {
        let raw: RawFile = toml::from_str(text)?;
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let aliases = raw
            .alias
            .into_iter()
            .map(|a| convert(a, home.as_deref()))
            .collect::<Result<_, _>>()?;
        Ok(Self { aliases })
    }

    /// Loads an alias file; `Ok(None)` when it does not exist.
    pub fn load(path: &Path) -> Result<Option<Self>, AliasError> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text).map(Some),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(source) => Err(AliasError::Read {
                path: path.to_owned(),
                source,
            }),
        }
    }

    /// Adds `other`'s aliases, which win over existing ones with the same
    /// name (the losing names are dropped from the older entries).
    pub fn merge(&mut self, other: Self) {
        let taken: HashSet<String> = other
            .aliases
            .iter()
            .flat_map(|a| a.names.iter().cloned())
            .collect();
        for a in &mut self.aliases {
            a.names.retain(|n| !taken.contains(n));
        }
        self.aliases.retain(|a| !a.names.is_empty());
        let mut merged = other.aliases;
        merged.append(&mut self.aliases);
        self.aliases = merged;
    }

    /// All aliases.
    pub fn aliases(&self) -> &[WindowsAlias] {
        &self.aliases
    }
}

fn convert(a: RawAlias, home: Option<&Path>) -> Result<WindowsAlias, AliasError> {
    let names: Vec<String> = a
        .names
        .iter()
        .map(|n| super::fold(n))
        .filter(|n| !n.is_empty())
        .collect();
    let has_app = !a.apps.is_empty() || !a.categories.is_empty();
    let target = match (has_app, a.setting, a.help) {
        (true, None, None) => AliasTarget::App {
            apps: a.apps,
            categories: a.categories,
        },
        (false, Some(page), None) => AliasTarget::Setting {
            title: a.title.unwrap_or_else(|| page.clone()),
            page,
            icon: a.icon.unwrap_or_else(|| "settings".into()),
        },
        (false, None, Some(path)) => AliasTarget::Help {
            path: expand_home(&path, home),
            title: a.title.unwrap_or_else(|| path.clone()),
            subtitle: a.subtitle.unwrap_or_default(),
            icon: a.icon.unwrap_or_else(|| "circle-help".into()),
        },
        _ => return Err(AliasError::Target(a.names)),
    };
    if names.is_empty() {
        return Err(AliasError::Target(a.names));
    }
    Ok(WindowsAlias {
        names,
        target,
        requires: a.requires,
    })
}

fn expand_home(path: &str, home: Option<&Path>) -> PathBuf {
    match (path.strip_prefix("~/"), home) {
        (Some(rest), Some(h)) => h.join(rest),
        _ => PathBuf::from(path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_table_is_valid_and_covers_spec() {
        let t = AliasTable::parse(EMBEDDED).unwrap();
        let find = |name: &str| {
            t.aliases()
                .iter()
                .find(|a| a.names.iter().any(|n| n == name))
                .unwrap_or_else(|| panic!("missing alias {name}"))
        };
        for name in [
            "control panel",
            "task manager",
            "add or remove programs",
            "cmd",
            "powershell",
            "device manager",
            "regedit",
            "notepad",
            "file explorer",
        ] {
            find(name);
        }
        assert!(
            matches!(&find("control panel").target, AliasTarget::App { apps, .. } if apps[0] == "lugh-settings")
        );
        assert!(
            matches!(&find("device manager").target, AliasTarget::Setting { page, .. } if page == "devices")
        );
        assert!(
            matches!(&find("regedit").target, AliasTarget::Help { path, .. } if path.ends_with(".config/lugh/desktop.toml"))
        );
    }

    #[test]
    fn merge_overrides_by_name() {
        let mut base = AliasTable::parse(
            "[[alias]]\nnames = [\"cmd\", \"powershell\"]\napps = [\"foot\"]\n[[alias]]\nnames = [\"gone\"]\napps = [\"x\"]\n",
        )
        .unwrap();
        let over =
            AliasTable::parse("[[alias]]\nnames = [\"powershell\", \"gone\"]\napps = [\"pwsh\"]\n")
                .unwrap();
        base.merge(over);
        let a = base.aliases();
        assert_eq!(a.len(), 2);
        assert_eq!(a[0].names, ["powershell", "gone"]);
        assert_eq!(a[1].names, ["cmd"]);
    }

    #[test]
    fn rejects_bad_targets() {
        assert!(matches!(
            AliasTable::parse("[[alias]]\nnames = [\"x\"]\n"),
            Err(AliasError::Target(_))
        ));
        assert!(matches!(
            AliasTable::parse("[[alias]]\nnames = [\"x\"]\napps = [\"a\"]\nsetting = \"s\"\n"),
            Err(AliasError::Target(_))
        ));
        assert!(matches!(
            AliasTable::parse("[[alias]]\nnames = [\"x\"]\nbogus = 1\n"),
            Err(AliasError::Parse(_))
        ));
        assert!(
            AliasTable::load(Path::new("/nonexistent/lugh/aliases.toml"))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn names_are_folded() {
        let t = AliasTable::parse("[[alias]]\nnames = [\"  Control   Panel \"]\napps = [\"a\"]\n")
            .unwrap();
        assert_eq!(t.aliases()[0].names, ["control panel"]);
    }
}
