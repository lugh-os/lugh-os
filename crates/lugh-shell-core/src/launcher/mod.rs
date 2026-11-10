//! Launcher core (docs/specs/shell.md §Launcher): the desktop-entry index,
//! fuzzy app search ranked by match quality × frequency × recency, Windows-name
//! aliases, the calculator and unit converter, launch history, and the
//! [`Provider`] trait through which the shell plugs in settings, open-window
//! and file results.
//!
//! The entry point is [`Launcher`]:
//!
//! ```no_run
//! use lugh_shell_core::launcher::Launcher;
//!
//! let mut launcher = Launcher::from_env();
//! for r in launcher.search("firef", 50) {
//!     // r.kind, r.group, r.title, r.subtitle, r.icon, r.target
//!     let _ = r;
//! }
//! launcher.record_launch("firefox").ok();
//! ```
//!
//! Results map one-to-one onto the QML `launcher.results` roles in
//! `ui/shell/qml/Lugh/Shell/Services.qml` (`kind`, `group`, `title`,
//! `subtitle`, `icon`, `target`); [`RecentApp`] maps onto `launcher.recent`.

mod aliases;
pub mod calc;
mod desktop_entry;
mod history;
mod index;
mod search;
mod settings;

use std::ffi::OsString;
use std::path::PathBuf;

use serde::Serialize;

pub use aliases::{AliasError, AliasTable, AliasTarget, SYSTEM_ALIASES, WindowsAlias};
pub use desktop_entry::{DesktopAction, DesktopEntry, EntryType, Locale, ParseError};
pub use history::{HISTORY_FILE, History, HistoryError, Usage};
pub use index::AppIndex;
pub use search::{Launcher, RecentApp};
pub use settings::{SETTINGS_INDEX, SettingsPage, SettingsProvider};

/// Result groups, in display order. The QML view shows them as section headers.
pub mod groups {
    /// Installed applications (and app aliases).
    pub const APPS: &str = "Apps";
    /// Calculator and unit conversion.
    pub const CALCULATOR: &str = "Calculator";
    /// Settings pages.
    pub const SETTINGS: &str = "Settings";
    /// Open windows ("Switch to …").
    pub const WINDOWS: &str = "Open windows";
    /// Files (recent files, name search).
    pub const FILES: &str = "Files";
    /// `>` commands run in a terminal.
    pub const RUN: &str = "Run";

    /// All known groups, in display order.
    pub const ORDER: [&str; 6] = [APPS, CALCULATOR, SETTINGS, WINDOWS, FILES, RUN];

    /// Display position of a group. Unknown groups sort after Files and
    /// before Run.
    pub fn rank(group: &str) -> usize {
        match group {
            APPS => 0,
            CALCULATOR => 1,
            SETTINGS => 2,
            WINDOWS => 3,
            FILES => 4,
            RUN => 6,
            _ => 5,
        }
    }
}

/// What a result is, which decides what activating it does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ResultKind {
    /// `target` is an app id (desktop-file id without `.desktop`).
    App,
    /// `target` is a settings page path (e.g. `network/wifi`).
    Setting,
    /// `target` is a window id.
    Window,
    /// `target` is an absolute file path.
    File,
    /// `target` is the value to copy.
    Calc,
    /// `target` is a command line to run in a terminal.
    Command,
}

impl ResultKind {
    /// The QML `kind` role value: `"app"`, `"setting"`, `"window"`, `"file"`,
    /// `"calc"` or `"command"`.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Setting => "setting",
            Self::Window => "window",
            Self::File => "file",
            Self::Calc => "calc",
            Self::Command => "command",
        }
    }
}

/// One launcher result row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SearchResult {
    /// What activating the row does.
    pub kind: ResultKind,
    /// Section header ([`groups`]).
    pub group: String,
    /// Main label.
    pub title: String,
    /// Secondary label ("Web Browser", "Matches ‘control panel’", …).
    pub subtitle: String,
    /// Freedesktop icon name for apps, symbolic Lucide name otherwise.
    pub icon: String,
    /// App id, settings page, window id, path, value or command.
    pub target: String,
    /// Ranking score within the group (higher is better). Only comparable
    /// between results of the same provider.
    pub score: i64,
}

/// A parsed launcher query, handed to every [`Provider`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    /// The text as typed.
    pub raw: String,
    /// `raw` without surrounding whitespace.
    pub text: String,
    /// `text` case-folded and accent-normalized (`"Écran"` → `"ecran"`),
    /// with runs of whitespace collapsed to one space.
    pub folded: String,
    /// Maximum number of results the caller wants.
    pub limit: usize,
}

impl Query {
    /// Builds a query from typed text.
    pub fn new(raw: &str, limit: usize) -> Self {
        let text = raw.trim().to_owned();
        let folded = fold(&text);
        Self {
            raw: raw.to_owned(),
            text,
            folded,
            limit,
        }
    }

    /// True when there is nothing to search for.
    pub fn is_empty(&self) -> bool {
        self.folded.is_empty()
    }
}

/// A source of launcher results besides apps: settings, open windows, files,
/// Store. Providers must answer fast (NFR-3: ≤ 30 ms per keystroke for
/// settings and windows); slow sources should answer from a cache and refresh
/// it elsewhere.
pub trait Provider: Send + std::fmt::Debug {
    /// Results for `q`, at most `q.limit`, best first. Each result's `group`
    /// decides where it is shown.
    fn search(&self, q: &Query) -> Vec<SearchResult>;
}

/// Case-folds and accent-normalizes `s` for matching, collapsing whitespace
/// runs to one space and trimming.
pub(crate) fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    fold_into(s, &mut out);
    out
}

/// [`fold`] into an existing buffer (cleared first).
pub(crate) fn fold_into(s: &str, out: &mut String) {
    out.clear();
    let mut pending_space = false;
    for c in s.chars() {
        if c.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        if c.is_ascii() {
            out.push(c.to_ascii_lowercase());
        } else {
            let c = nucleo_matcher::chars::normalize(c);
            out.push(nucleo_matcher::chars::to_lower_case(c));
        }
    }
}

/// The user's Lugh state directory: `$XDG_STATE_HOME/lugh`, falling back to
/// `~/.local/state/lugh`. `None` when neither gives an absolute path.
pub fn state_dir() -> Option<PathBuf> {
    resolve_state_dir(std::env::var_os("XDG_STATE_HOME"), std::env::var_os("HOME"))
}

fn resolve_state_dir(xdg: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let absolute = |v: OsString| Some(PathBuf::from(v)).filter(|p| p.is_absolute());
    xdg.and_then(absolute)
        .or_else(|| home.and_then(absolute).map(|h| h.join(".local/state")))
        .map(|base| base.join(lugh_common::config::APP_DIR))
}

/// Seconds since the Unix epoch.
pub(crate) fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold_lowercases_normalizes_and_collapses() {
        assert_eq!(fold("  Écran   de\tVeille "), "ecran de veille");
        assert_eq!(fold("FIREFOX"), "firefox");
        assert_eq!(fold(""), "");
    }

    #[test]
    fn state_dir_resolution() {
        assert_eq!(
            resolve_state_dir(Some("/x/state".into()), Some("/home/a".into())),
            Some(PathBuf::from("/x/state/lugh"))
        );
        assert_eq!(
            resolve_state_dir(Some("relative".into()), Some("/home/a".into())),
            Some(PathBuf::from("/home/a/.local/state/lugh"))
        );
        assert_eq!(resolve_state_dir(None, None), None);
    }

    #[test]
    fn group_order() {
        let mut g = vec!["Run", "Files", "Custom", "Apps", "Calculator"];
        g.sort_by_key(|g| groups::rank(g));
        assert_eq!(g, ["Apps", "Calculator", "Files", "Custom", "Run"]);
    }

    #[test]
    fn kind_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&ResultKind::Setting).unwrap(),
            "\"setting\""
        );
        assert_eq!(ResultKind::Command.as_str(), "command");
    }
}
