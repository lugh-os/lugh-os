//! `~/.config/lugh/desktop.toml`, schema v0 (`schema = 1`).
//!
//! The file is owned by `lugh-settingsd`; the shell and the first-run app
//! read it, and write it only through [`DesktopConfig::save_atomic`].
//!
//! ```toml
//! schema = 1
//!
//! [appearance]
//! theme = "light"                       # light | dark | auto
//! accent = "amber"                      # amber | teal | green | blue | red | graphite
//! wallpaper = "lugh://wallpapers/dawn"  # or a file/folder path
//! wallpaper_dark = ""                   # dark-theme wallpaper; "" = same rule as `wallpaper`
//! icon_theme = "Papirus"                # freedesktop icon theme name
//! transparency = true
//! reduce_motion = false                 # also see accessibility.reduce_motion
//!
//! [desktop]
//! mode = "lugh"                         # lugh | classic | focus
//! window_buttons = "auto"               # auto (per mode) | left | right
//!
//! [dock]                                # Lugh mode
//! autohide = false
//! magnify = false
//! icon_size = 56                        # 40..=80 px
//! pinned = ["firefox", "lugh-files", "org.codeberg.dnkl.foot", "lugh-store", "lugh-settings"]
//!
//! [bar]
//! show_date = true
//! clock_24h = true
//! show_battery_percent = false
//!
//! [notifications]
//! do_not_disturb = false                # `dnd` is read as an alias
//! popup_timeout_ms = 5000               # 1000..=120000
//! per_app = { "org.telegram.desktop" = { banners = false } }
//!
//! [accessibility]
//! reduce_motion = "system"              # system | on | off (true/false accepted)
//! large_text = false
//! high_contrast = false
//!
//! [bindings.lugh]                       # preset for Lugh (and, for now, Classic) mode
//! "Super+Space" = "shell.launcher"
//! [bindings.focus]                      # preset for Focus mode
//! "Super+Return" = "exec foot"
//! [bindings.user]                       # applied on top of the active preset
//! "Super+E" = "exec lugh-files"
//! ```
//!
//! Reading never fails because of the content: a key with an invalid value
//! falls back to its default (numbers out of range are clamped) and a
//! [`ConfigWarning`] is logged; a file that is not TOML at all yields the
//! defaults. Unknown keys and sections (e.g. `[taskbar]`, `[input]` from
//! settings.md) are kept and written back unchanged, so newer files survive
//! older software.

use std::collections::BTreeMap;
use std::fmt::{self, Write as _};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use toml::{Table, Value};

/// Schema version this code reads and writes.
pub const SCHEMA_VERSION: u32 = 1;

/// File name inside the Lugh config directory.
pub const FILE_NAME: &str = "desktop.toml";

/// Allowed dock icon sizes in pixels.
pub const DOCK_ICON_SIZES: std::ops::RangeInclusive<u32> = 40..=80;

/// Allowed notification popup timeouts in milliseconds.
pub const POPUP_TIMEOUTS_MS: std::ops::RangeInclusive<u32> = 1000..=120_000;

/// Errors from locating, reading or writing the file. Bad content is never
/// an error.
#[derive(Debug, thiserror::Error)]
pub enum DesktopConfigError {
    /// The config directory cannot be determined.
    #[error(transparent)]
    Location(#[from] lugh_common::ConfigError),

    /// The file exists but cannot be read.
    #[error("cannot read {}: {source}", path.display())]
    Read {
        /// File.
        path: PathBuf,
        /// Underlying error.
        #[source]
        source: io::Error,
    },

    /// The file cannot be written.
    #[error("cannot write {}: {source}", path.display())]
    Write {
        /// File.
        path: PathBuf,
        /// Underlying error.
        #[source]
        source: io::Error,
    },

    /// The settings cannot be represented as TOML (should not happen).
    #[error("cannot serialise settings: {0}")]
    Serialize(#[from] toml::ser::Error),
}

/// A problem found while reading; the affected key uses its default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigWarning {
    /// Dotted key (`dock.icon_size`); empty for the whole file.
    pub key: String,
    /// What was wrong and what was used instead.
    pub message: String,
}

impl fmt::Display for ConfigWarning {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.key.is_empty() {
            f.write_str(&self.message)
        } else {
            write!(f, "{}: {}", self.key, self.message)
        }
    }
}

/// Colour scheme.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    /// Light (the default).
    #[default]
    Light,
    /// Dark.
    Dark,
    /// Follows `appearance.auto_dark` (sun or fixed times).
    Auto,
}

/// Accent colour (DESIGN-SYSTEM accent variants).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Accent {
    /// Amber (the default, Lugh's brand colour).
    #[default]
    Amber,
    /// Teal.
    Teal,
    /// Green.
    Green,
    /// Blue.
    Blue,
    /// Red.
    Red,
    /// Graphite.
    Graphite,
}

impl Accent {
    /// The six presets, in display order.
    pub const ALL: [Self; 6] = [
        Self::Amber,
        Self::Teal,
        Self::Green,
        Self::Blue,
        Self::Red,
        Self::Graphite,
    ];

    /// The name used in `desktop.toml` and by the QML theme (`"amber"`).
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Amber => "amber",
            Self::Teal => "teal",
            Self::Green => "green",
            Self::Blue => "blue",
            Self::Red => "red",
            Self::Graphite => "graphite",
        }
    }

    /// The preset called `name`, if it is one of the six.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.name() == name)
    }
}

/// Desktop mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Lugh mode: top bar and dock (the default).
    #[default]
    Lugh,
    /// Classic mode: taskbar and start menu.
    Classic,
    /// Focus mode: tiling, thin bar.
    Focus,
}

/// Side of the window buttons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WindowButtons {
    /// Per mode (the default).
    #[default]
    Auto,
    /// Left.
    Left,
    /// Right.
    Right,
}

/// Reduce-motion preference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReduceMotion {
    /// Follow the system/toolkit setting (the default).
    #[default]
    System,
    /// Always reduce motion.
    On,
    /// Never reduce motion.
    Off,
}

/// `[appearance]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Appearance {
    /// Colour scheme (`light`).
    pub theme: Theme,
    /// Accent colour (`amber`).
    pub accent: Accent,
    /// `lugh://wallpapers/<name>`, or a file or folder path.
    pub wallpaper: String,
    /// Wallpaper for the dark theme, same forms; `""` (default) means the
    /// bundled dark art.
    pub wallpaper_dark: String,
    /// Freedesktop icon theme name (`Papirus`).
    pub icon_theme: String,
    /// Glass surfaces (`true`).
    pub transparency: bool,
    /// Reduce animations (`false`); `accessibility.reduce_motion` wins when
    /// set to `on` or `off`.
    pub reduce_motion: bool,
}

impl Default for Appearance {
    fn default() -> Self {
        Self {
            theme: Theme::default(),
            accent: Accent::default(),
            wallpaper: "lugh://wallpapers/dawn".into(),
            wallpaper_dark: String::new(),
            icon_theme: "Papirus".into(),
            transparency: true,
            reduce_motion: false,
        }
    }
}

/// `[desktop]`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Desktop {
    /// Desktop mode (`lugh`).
    pub mode: Mode,
    /// Window button side (`auto`).
    pub window_buttons: WindowButtons,
}

/// `[dock]` (Lugh mode).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Dock {
    /// Hide until the pointer reaches the bottom edge (`false`).
    pub autohide: bool,
    /// Magnify icons under the pointer (`false`).
    pub magnify: bool,
    /// Icon size in px, within [`DOCK_ICON_SIZES`] (`56`).
    pub icon_size: u32,
    /// Pinned desktop-entry ids, in order.
    pub pinned: Vec<String>,
}

impl Default for Dock {
    fn default() -> Self {
        Self {
            autohide: false,
            magnify: false,
            icon_size: 56,
            pinned: [
                "firefox",
                "lugh-files",
                "org.codeberg.dnkl.foot",
                "lugh-store",
                "lugh-settings",
            ]
            .map(String::from)
            .to_vec(),
        }
    }
}

/// `[bar]` (top bar).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Bar {
    /// Show the date next to the clock (`true`).
    pub show_date: bool,
    /// 24-hour clock (`true`).
    pub clock_24h: bool,
    /// Show the battery percentage next to its icon (`false`).
    pub show_battery_percent: bool,
}

impl Default for Bar {
    fn default() -> Self {
        Self {
            show_date: true,
            clock_24h: true,
            show_battery_percent: false,
        }
    }
}

/// Per-app notification settings (`[notifications.per_app."<app id>"]`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AppNotifications {
    /// Show popups (`true`); when `false` notifications only go to history.
    pub banners: bool,
}

impl Default for AppNotifications {
    fn default() -> Self {
        Self { banners: true }
    }
}

/// `[notifications]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Notifications {
    /// Do Not Disturb (`false`). Read from `do_not_disturb` or `dnd`.
    pub do_not_disturb: bool,
    /// Popup lifetime in ms, within [`POPUP_TIMEOUTS_MS`] (`5000`).
    pub popup_timeout_ms: u32,
    /// Per-app overrides, by desktop-entry id.
    pub per_app: BTreeMap<String, AppNotifications>,
}

impl Default for Notifications {
    fn default() -> Self {
        Self {
            do_not_disturb: false,
            popup_timeout_ms: 5000,
            per_app: BTreeMap::new(),
        }
    }
}

/// `[accessibility]`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Accessibility {
    /// Reduce motion (`system`).
    pub reduce_motion: ReduceMotion,
    /// Larger text (`false`).
    pub large_text: bool,
    /// High-contrast theme (`false`).
    pub high_contrast: bool,
}

/// `[bindings.*]`: key chord → action (`shell.*`, `wm.*`, `session.*`,
/// `exec …`), see docs/specs/shell.md §Configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Bindings {
    /// Lugh-mode preset.
    pub lugh: BTreeMap<String, String>,
    /// Focus-mode preset.
    pub focus: BTreeMap<String, String>,
    /// User bindings, applied on top of the active preset.
    pub user: BTreeMap<String, String>,
}

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

impl Default for Bindings {
    fn default() -> Self {
        Self {
            lugh: map(&[
                ("Super+Space", "shell.launcher"),
                ("Super+Tab", "shell.overview"),
                ("Super+L", "session.lock"),
                ("Super+T", "wm.toggle-tiling"),
                ("Super+Q", "wm.close"),
                ("Print", "shell.screenshot area"),
            ]),
            focus: map(&[
                ("Super+Space", "shell.launcher"),
                ("Super+Return", "exec foot"),
                ("Super+H", "wm.focus left"),
                ("Super+L", "session.lock"),
                ("Super+Q", "wm.close"),
                ("Print", "shell.screenshot area"),
            ]),
            user: BTreeMap::new(),
        }
    }
}

/// The whole of `desktop.toml`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DesktopConfig {
    /// Schema version ([`SCHEMA_VERSION`]).
    pub schema: u32,
    /// `[appearance]`.
    pub appearance: Appearance,
    /// `[desktop]`.
    pub desktop: Desktop,
    /// `[dock]`.
    pub dock: Dock,
    /// `[bar]`.
    pub bar: Bar,
    /// `[notifications]`.
    pub notifications: Notifications,
    /// `[accessibility]`.
    pub accessibility: Accessibility,
    /// `[bindings]`.
    pub bindings: Bindings,
    /// The document as read, keeping keys this version does not know.
    #[serde(skip)]
    raw: Table,
}

impl Default for DesktopConfig {
    fn default() -> Self {
        Self {
            schema: SCHEMA_VERSION,
            appearance: Appearance::default(),
            desktop: Desktop::default(),
            dock: Dock::default(),
            bar: Bar::default(),
            notifications: Notifications::default(),
            accessibility: Accessibility::default(),
            bindings: Bindings::default(),
            raw: Table::new(),
        }
    }
}

impl DesktopConfig {
    /// `<config dir>/desktop.toml` (`~/.config/lugh/desktop.toml`).
    pub fn default_path() -> Result<PathBuf, DesktopConfigError> {
        Ok(lugh_common::config_dir()?.join(FILE_NAME))
    }

    /// Reads the file at the default location; see [`load`](Self::load).
    pub fn load_default_location() -> Result<Self, DesktopConfigError> {
        Self::load(Self::default_path()?)
    }

    /// Reads a file. A missing file gives the defaults; content problems are
    /// logged as warnings and never fail. Only I/O errors are returned.
    pub fn load(path: impl AsRef<Path>) -> Result<Self, DesktopConfigError> {
        let path = path.as_ref();
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(source) => {
                return Err(DesktopConfigError::Read {
                    path: path.to_owned(),
                    source,
                });
            }
        };
        let (config, warnings) = Self::from_toml_str(&text);
        for w in &warnings {
            tracing::warn!(file = %path.display(), "{w}");
        }
        Ok(config)
    }

    /// Parses a document, returning the settings and what was wrong with it.
    pub fn from_toml_str(text: &str) -> (Self, Vec<ConfigWarning>) {
        let mut warnings = Vec::new();
        let raw: Table = match text.parse() {
            Ok(t) => t,
            Err(e) => {
                warnings.push(ConfigWarning {
                    key: String::new(),
                    message: format!("not valid TOML, using defaults: {e}"),
                });
                return (Self::default(), warnings);
            }
        };
        let config = Self::from_table(raw, &mut warnings);
        (config, warnings)
    }

    fn from_table(raw: Table, w: &mut Vec<ConfigWarning>) -> Self {
        let d = Self::default();
        let schema = match raw.get("schema") {
            None => SCHEMA_VERSION,
            Some(Value::Integer(n)) if *n >= 1 => {
                let n = u32::try_from(*n).unwrap_or(u32::MAX);
                if n > SCHEMA_VERSION {
                    warn(
                        w,
                        "schema",
                        format!(
                            "schema {n} is newer than {SCHEMA_VERSION}; reading the keys this version knows"
                        ),
                    );
                }
                n
            }
            Some(v) => {
                warn(
                    w,
                    "schema",
                    format!("invalid value {}, using {SCHEMA_VERSION}", inline(v)),
                );
                SCHEMA_VERSION
            }
        };

        let mut s = Section::new(&raw, "appearance", w);
        let appearance = Appearance {
            theme: s.value("theme", d.appearance.theme),
            accent: s.value("accent", d.appearance.accent),
            wallpaper: s.value("wallpaper", d.appearance.wallpaper),
            wallpaper_dark: s.value("wallpaper_dark", d.appearance.wallpaper_dark),
            icon_theme: s.value("icon_theme", d.appearance.icon_theme),
            transparency: s.value("transparency", d.appearance.transparency),
            reduce_motion: s.value("reduce_motion", d.appearance.reduce_motion),
        };

        let mut s = Section::new(&raw, "desktop", w);
        let desktop = Desktop {
            mode: s.value("mode", d.desktop.mode),
            window_buttons: s.value("window_buttons", d.desktop.window_buttons),
        };

        let mut s = Section::new(&raw, "dock", w);
        let dock = Dock {
            autohide: s.value("autohide", d.dock.autohide),
            magnify: s.value("magnify", d.dock.magnify),
            icon_size: s.ranged("icon_size", d.dock.icon_size, DOCK_ICON_SIZES),
            pinned: s.strings("pinned", d.dock.pinned),
        };

        let mut s = Section::new(&raw, "bar", w);
        let bar = Bar {
            show_date: s.value("show_date", d.bar.show_date),
            clock_24h: s.value("clock_24h", d.bar.clock_24h),
            show_battery_percent: s.value("show_battery_percent", d.bar.show_battery_percent),
        };

        let mut s = Section::new(&raw, "notifications", w);
        let dnd_key = if s.has("do_not_disturb") {
            "do_not_disturb"
        } else {
            "dnd"
        };
        let notifications = Notifications {
            do_not_disturb: s.value(dnd_key, d.notifications.do_not_disturb),
            popup_timeout_ms: s.ranged(
                "popup_timeout_ms",
                d.notifications.popup_timeout_ms,
                POPUP_TIMEOUTS_MS,
            ),
            per_app: s.per_app("per_app"),
        };

        let mut s = Section::new(&raw, "accessibility", w);
        let reduce_motion = match s.get("reduce_motion") {
            Some(Value::Boolean(true)) => ReduceMotion::On,
            Some(Value::Boolean(false)) => ReduceMotion::Off,
            _ => s.value("reduce_motion", d.accessibility.reduce_motion),
        };
        let accessibility = Accessibility {
            reduce_motion,
            large_text: s.value("large_text", d.accessibility.large_text),
            high_contrast: s.value("high_contrast", d.accessibility.high_contrast),
        };

        let mut s = Section::new(&raw, "bindings", w);
        let bindings = Bindings {
            lugh: s.string_map("lugh", d.bindings.lugh),
            focus: s.string_map("focus", d.bindings.focus),
            user: s.string_map("user", d.bindings.user),
        };

        Self {
            schema,
            appearance,
            desktop,
            dock,
            bar,
            notifications,
            accessibility,
            bindings,
            raw,
        }
    }

    /// Whether to reduce motion, given the system/toolkit preference.
    pub fn reduce_motion(&self, system: bool) -> bool {
        match self.accessibility.reduce_motion {
            ReduceMotion::On => true,
            ReduceMotion::Off => false,
            ReduceMotion::System => system || self.appearance.reduce_motion,
        }
    }

    /// The bindings in effect for `mode`: its preset (Classic uses the Lugh
    /// preset until it has its own) with the user bindings on top.
    pub fn bindings_for(&self, mode: Mode) -> BTreeMap<String, String> {
        let preset = match mode {
            Mode::Lugh | Mode::Classic => &self.bindings.lugh,
            Mode::Focus => &self.bindings.focus,
        };
        let mut out = preset.clone();
        out.extend(
            self.bindings
                .user
                .iter()
                .map(|(k, v)| (k.clone(), v.clone())),
        );
        out
    }

    /// The document to write: the original with the known keys replaced, so
    /// unknown keys survive.
    pub fn to_toml_string(&self) -> Result<String, DesktopConfigError> {
        let mut doc = self.raw.clone();
        // A struct always serialises to a table.
        let known = match Value::try_from(self)? {
            Value::Table(t) => t,
            _ => Table::new(),
        };
        merge(&mut doc, known, &[]);
        if let Some(Value::Table(n)) = doc.get_mut("notifications") {
            n.remove("dnd");
        }
        Ok(render_document(&doc))
    }

    /// Writes the file atomically: a temporary file in the same directory,
    /// flushed, then renamed over the target. If the existing file is not
    /// valid TOML it is first copied to `<name>.bak`, so a hand-edited file
    /// with a typo is never lost. Creates the directory if needed.
    pub fn save_atomic(&self, path: impl AsRef<Path>) -> Result<(), DesktopConfigError> {
        let path = path.as_ref();
        let werr = |source| DesktopConfigError::Write {
            path: path.to_owned(),
            source,
        };
        let text = self.to_toml_string()?;
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir).map_err(werr)?;
        }
        if let Ok(old) = std::fs::read_to_string(path)
            && old.parse::<Table>().is_err()
        {
            let bak = sibling(path, ".bak");
            std::fs::copy(path, &bak).map_err(werr)?;
            tracing::warn!(backup = %bak.display(), "replacing an unreadable settings file; kept a backup");
        }
        let tmp = sibling(path, &format!(".tmp-{}", std::process::id()));
        let written = (|| {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(text.as_bytes())?;
            f.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            return Err(werr(e));
        }
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty())
            && let Ok(d) = std::fs::File::open(dir)
        {
            let _ = d.sync_all();
        }
        Ok(())
    }
}

/// `path` with `suffix` appended to its file name.
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

fn warn(w: &mut Vec<ConfigWarning>, key: &str, message: String) {
    w.push(ConfigWarning {
        key: key.to_owned(),
        message,
    });
}

/// Lenient reader for one section.
struct Section<'a> {
    name: &'static str,
    table: Option<&'a Table>,
    warnings: &'a mut Vec<ConfigWarning>,
}

impl<'a> Section<'a> {
    fn new(root: &'a Table, name: &'static str, warnings: &'a mut Vec<ConfigWarning>) -> Self {
        let table = match root.get(name) {
            None => None,
            Some(Value::Table(t)) => Some(t),
            Some(v) => {
                warn(
                    warnings,
                    name,
                    format!("expected a table, found {}; using defaults", inline(v)),
                );
                None
            }
        };
        Self {
            name,
            table,
            warnings,
        }
    }

    fn has(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    fn get(&self, key: &str) -> Option<&'a Value> {
        self.table?.get(key)
    }

    fn warn(&mut self, key: &str, message: String) {
        warn(self.warnings, &format!("{}.{key}", self.name), message);
    }

    fn invalid<T: Serialize>(&mut self, key: &str, v: &Value, default: &T) {
        let default =
            Value::try_from(default).map_or_else(|_| "the default".to_owned(), |d| inline(&d));
        self.warn(key, format!("invalid value {}, using {default}", inline(v)));
    }

    fn value<T: DeserializeOwned + Serialize>(&mut self, key: &str, default: T) -> T {
        let Some(v) = self.get(key) else {
            return default;
        };
        match v.clone().try_into::<T>() {
            Ok(x) => x,
            Err(_) => {
                self.invalid(key, v, &default);
                default
            }
        }
    }

    fn ranged(&mut self, key: &str, default: u32, range: std::ops::RangeInclusive<u32>) -> u32 {
        let Some(v) = self.get(key) else {
            return default;
        };
        let Value::Integer(n) = v else {
            self.invalid(key, v, &default);
            return default;
        };
        let (lo, hi) = (i64::from(*range.start()), i64::from(*range.end()));
        let clamped = (*n).clamp(lo, hi);
        if clamped != *n {
            self.warn(key, format!("{n} is outside {lo}..={hi}, using {clamped}"));
        }
        u32::try_from(clamped).unwrap_or(default)
    }

    fn strings(&mut self, key: &str, default: Vec<String>) -> Vec<String> {
        let Some(v) = self.get(key) else {
            return default;
        };
        let Value::Array(items) = v else {
            self.invalid(key, v, &default);
            return default;
        };
        let mut out = Vec::with_capacity(items.len());
        for item in items {
            match item {
                Value::String(s) => out.push(s.clone()),
                other => self.warn(key, format!("ignoring non-string entry {}", inline(other))),
            }
        }
        out
    }

    fn string_map(
        &mut self,
        key: &str,
        default: BTreeMap<String, String>,
    ) -> BTreeMap<String, String> {
        let Some(v) = self.get(key) else {
            return default;
        };
        let Value::Table(t) = v else {
            self.invalid(key, v, &default);
            return default;
        };
        let mut out = BTreeMap::new();
        for (k, v) in t {
            match v {
                Value::String(s) => {
                    out.insert(k.clone(), s.clone());
                }
                other => self.warn(
                    &format!("{key}.{}", key_text(k)),
                    format!("ignoring non-string value {}", inline(other)),
                ),
            }
        }
        out
    }

    fn per_app(&mut self, key: &str) -> BTreeMap<String, AppNotifications> {
        let mut out = BTreeMap::new();
        let Some(v) = self.get(key) else {
            return out;
        };
        let Value::Table(t) = v else {
            self.invalid(key, v, &out);
            return out;
        };
        for (app, entry) in t {
            let entry_key = format!("{key}.{}", key_text(app));
            let Value::Table(e) = entry else {
                self.warn(
                    &entry_key,
                    format!("expected a table, found {}", inline(entry)),
                );
                continue;
            };
            let banners = match e.get("banners") {
                None => true,
                Some(Value::Boolean(b)) => *b,
                Some(other) => {
                    self.warn(
                        &format!("{entry_key}.banners"),
                        format!("invalid value {}, using true", inline(other)),
                    );
                    true
                }
            };
            out.insert(app.clone(), AppNotifications { banners });
        }
        out
    }
}

/// Tables whose keys are data (ids, chords), not schema fields: on save,
/// entries missing from the new value are removed rather than kept.
fn is_map(path: &[&str]) -> bool {
    matches!(
        path,
        ["bindings", "lugh" | "focus" | "user"] | ["notifications", "per_app"]
    )
}

/// Overlays `new` onto `doc`, keeping keys of `doc` that `new` lacks except
/// inside [`is_map`] tables.
fn merge(doc: &mut Table, new: Table, path: &[&str]) {
    if is_map(path) {
        doc.retain(|k, _| new.contains_key(k));
    }
    for (k, v) in new {
        match (doc.get_mut(&k), v) {
            (Some(Value::Table(old)), Value::Table(new_t)) => {
                let mut sub: Vec<&str> = path.to_vec();
                sub.push(&k);
                merge(old, new_t, &sub);
            }
            (_, v) => {
                doc.insert(k, v);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// TOML output (the workspace builds `toml` without its `display` feature)
// ---------------------------------------------------------------------------

/// Renders a document: top-level values first, then `[section]` tables.
/// Arrays of tables are written inline.
fn render_document(doc: &Table) -> String {
    let mut out = String::new();
    render_table(&mut out, doc, &mut Vec::new());
    out
}

fn render_table(out: &mut String, table: &Table, path: &mut Vec<String>) {
    for (k, v) in table {
        if !matches!(v, Value::Table(_)) {
            let _ = writeln!(out, "{} = {}", key_text(k), inline(v));
        }
    }
    for (k, v) in table {
        if let Value::Table(t) = v {
            path.push(key_text(k));
            if !out.is_empty() {
                out.push('\n');
            }
            let _ = writeln!(out, "[{}]", path.join("."));
            render_table(out, t, path);
            path.pop();
        }
    }
}

/// A key, bare when possible.
fn key_text(k: &str) -> String {
    if !k.is_empty()
        && k.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        k.to_owned()
    } else {
        quote(k)
    }
}

fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if c.is_control() => {
                let _ = write!(out, "\\u{:04X}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A value in inline form.
fn inline(v: &Value) -> String {
    match v {
        Value::String(s) => quote(s),
        Value::Integer(n) => n.to_string(),
        Value::Float(f) if f.is_nan() => "nan".to_owned(),
        Value::Float(f) if f.is_infinite() => if *f > 0.0 { "inf" } else { "-inf" }.to_owned(),
        Value::Float(f) => {
            let s = format!("{f:?}");
            if s.contains(['.', 'e', 'E']) {
                s
            } else {
                format!("{s}.0")
            }
        }
        Value::Boolean(b) => b.to_string(),
        Value::Datetime(d) => d.to_string(),
        Value::Array(items) => {
            let items: Vec<String> = items.iter().map(inline).collect();
            format!("[{}]", items.join(", "))
        }
        Value::Table(t) => {
            if t.is_empty() {
                return "{}".to_owned();
            }
            let items: Vec<String> = t
                .iter()
                .map(|(k, v)| format!("{} = {}", key_text(k), inline(v)))
                .collect();
            format!("{{ {} }}", items.join(", "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> (DesktopConfig, Vec<ConfigWarning>) {
        DesktopConfig::from_toml_str(text)
    }

    #[test]
    fn empty_file_is_defaults() {
        let (c, w) = parse("");
        assert!(w.is_empty());
        assert_eq!(c, DesktopConfig::default());
        assert_eq!(c.dock.icon_size, 56);
        assert_eq!(c.dock.pinned[2], "org.codeberg.dnkl.foot");
        assert_eq!(c.notifications.popup_timeout_ms, 5000);
        assert_eq!(c.appearance.accent, Accent::Amber);
    }

    #[test]
    fn settings_md_excerpt_reads_cleanly() {
        let text = r#"
schema = 1

[appearance]
theme = "dark"
auto_dark = { mode = "sun", start = "19:00", end = "07:00" }
accent = "teal"
wallpaper = "/home/amara/Pictures/lake.jpg"
transparency = false
cursor_size = 24

[desktop]
mode = "focus"
window_buttons = "left"
hot_corners = { top_left = "overview" }

[dock]
autohide = true
icon_size = 64
pinned = ["firefox", "vlc"]

[taskbar]
position = "bottom"

[notifications]
do_not_disturb = true
per_app = { "org.telegram.desktop" = { banners = false } }

[accessibility]
reduce_motion = "on"
high_contrast = true
text_scale = 1.0

[bindings.user]
"Super+E" = "exec lugh-files"
"#;
        let (c, w) = parse(text);
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(c.appearance.theme, Theme::Dark);
        assert_eq!(c.appearance.accent, Accent::Teal);
        assert!(!c.appearance.transparency);
        assert_eq!(c.desktop.mode, Mode::Focus);
        assert_eq!(c.desktop.window_buttons, WindowButtons::Left);
        assert!(c.dock.autohide);
        assert_eq!(c.dock.icon_size, 64);
        assert_eq!(c.dock.pinned, ["firefox", "vlc"]);
        assert!(c.notifications.do_not_disturb);
        assert!(!c.notifications.per_app["org.telegram.desktop"].banners);
        assert_eq!(c.accessibility.reduce_motion, ReduceMotion::On);
        assert!(c.reduce_motion(false));
        assert_eq!(c.bindings.lugh, Bindings::default().lugh, "preset kept");
        let eff = c.bindings_for(Mode::Focus);
        assert_eq!(eff["Super+E"], "exec lugh-files");
        assert_eq!(eff["Super+Return"], "exec foot");
    }

    #[test]
    fn invalid_values_fall_back_per_key() {
        let text = r#"
schema = "one"
[appearance]
theme = "purple"
accent = 7
wallpaper = "lugh://wallpapers/dusk"
[desktop]
mode = "tablet"
[dock]
icon_size = 300
magnify = "yes"
pinned = ["firefox", 3, "vlc"]
[bar]
clock_24h = false
[notifications]
dnd = true
popup_timeout_ms = -5
per_app = { "a" = 1, "b" = { banners = "no" } }
[accessibility]
reduce_motion = false
large_text = 1
[bindings]
lugh = "nope"
user = { "Super+E" = "exec lugh-files", "Super+X" = 5 }
"#;
        let (c, w) = parse(text);
        let keys: Vec<&str> = w.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(
            keys,
            [
                "schema",
                "appearance.theme",
                "appearance.accent",
                "desktop.mode",
                "dock.magnify",
                "dock.icon_size",
                "dock.pinned",
                "notifications.popup_timeout_ms",
                "notifications.per_app.a",
                "notifications.per_app.b.banners",
                "accessibility.large_text",
                "bindings.lugh",
                "bindings.user.\"Super+X\"",
            ]
        );
        assert!(w[1].message.contains("\"purple\"") && w[1].message.contains("\"light\""));
        assert_eq!(c.schema, 1);
        assert_eq!(c.appearance.theme, Theme::Light);
        assert_eq!(c.appearance.accent, Accent::Amber);
        assert_eq!(c.appearance.wallpaper, "lugh://wallpapers/dusk");
        assert_eq!(c.desktop.mode, Mode::Lugh);
        assert_eq!(c.dock.icon_size, 80, "clamped");
        assert!(!c.dock.magnify);
        assert_eq!(c.dock.pinned, ["firefox", "vlc"]);
        assert!(!c.bar.clock_24h);
        assert!(c.notifications.do_not_disturb, "dnd alias");
        assert_eq!(c.notifications.popup_timeout_ms, 1000);
        assert!(c.notifications.per_app["b"].banners);
        assert!(!c.notifications.per_app.contains_key("a"));
        assert_eq!(c.accessibility.reduce_motion, ReduceMotion::Off);
        assert!(!c.reduce_motion(true));
        assert_eq!(c.bindings.lugh, Bindings::default().lugh);
        assert_eq!(c.bindings.user.len(), 1);
    }

    #[test]
    fn wrong_section_types_and_garbage() {
        let (c, w) = parse("dock = 3\nbar = [1]\n");
        assert_eq!(w.len(), 2);
        assert_eq!(c.dock, Dock::default());
        let (c, w) = parse("this is [not toml");
        assert_eq!(w.len(), 1);
        assert!(w[0].key.is_empty() && w[0].to_string().contains("not valid TOML"));
        assert_eq!(c, DesktopConfig::default());
        let (c, w) = parse("schema = 2\n[dock]\nicon_size = 48\n");
        assert_eq!(w.len(), 1);
        assert_eq!((c.schema, c.dock.icon_size), (2, 48));
    }

    #[test]
    fn round_trip_keeps_unknown_keys() {
        let text = r#"
schema = 1
future_key = [1.5, 2, "x"]
[appearance]
theme = "auto"
auto_dark = { mode = "fixed", start = "19:00", end = "07:00" }
[input]
keyboard_layouts = ["us", "fr"]
touchpad = { tap_to_click = true }
[notifications]
dnd = true
per_app = { "org.telegram.desktop" = { banners = false, sound = "quiet" }, "old.app" = { banners = false } }
[bindings.user]
"Super+E" = "exec lugh-files"
"Super+Old" = "exec old"
"#;
        let (mut c, w) = parse(text);
        assert!(w.is_empty(), "{w:?}");
        c.dock.icon_size = 48;
        c.bindings.user.remove("Super+Old");
        c.notifications.per_app.remove("old.app");
        let out = c.to_toml_string().unwrap();
        let doc: Table = out.parse().expect("output is valid TOML");
        assert_eq!(
            doc["future_key"],
            Value::Array(vec![
                Value::Float(1.5),
                Value::Integer(2),
                Value::String("x".into())
            ])
        );
        assert_eq!(doc["input"]["keyboard_layouts"][1].as_str(), Some("fr"));
        assert_eq!(
            doc["appearance"]["auto_dark"]["mode"].as_str(),
            Some("fixed")
        );
        assert_eq!(doc["appearance"]["theme"].as_str(), Some("auto"));
        assert_eq!(doc["dock"]["icon_size"].as_integer(), Some(48));
        assert_eq!(doc["notifications"]["do_not_disturb"].as_bool(), Some(true));
        assert!(doc["notifications"].get("dnd").is_none());
        let tg = &doc["notifications"]["per_app"]["org.telegram.desktop"];
        assert_eq!(
            tg["sound"].as_str(),
            Some("quiet"),
            "unknown nested key kept"
        );
        assert!(doc["notifications"]["per_app"].get("old.app").is_none());
        assert!(doc["bindings"]["user"].get("Super+Old").is_none());
        assert_eq!(
            doc["bindings"]["lugh"]["Super+Space"].as_str(),
            Some("shell.launcher")
        );

        let (again, w) = parse(&out);
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(again.dock, c.dock);
        assert_eq!(again.bindings, c.bindings);
        assert_eq!(again.to_toml_string().unwrap(), out, "stable output");
    }

    #[test]
    fn emitter_escapes() {
        let mut t = Table::new();
        t.insert(
            "plain".into(),
            Value::String("a \"q\" \\ \n\t\u{1}é".into()),
        );
        t.insert("odd key.x".into(), Value::Float(3.0));
        t.insert("big".into(), Value::Float(1e300));
        t.insert("arr".into(), Value::Array(vec![Value::Table(Table::new())]));
        let out = render_document(&t);
        let back: Table = out.parse().unwrap();
        assert_eq!(back, t);
    }

    #[test]
    fn save_atomic_and_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("lugh").join(FILE_NAME);

        // Missing file: defaults; save creates the directory.
        let c = DesktopConfig::load(&path).unwrap();
        assert_eq!(c, DesktopConfig::default());
        c.save_atomic(&path).unwrap();
        assert_eq!(
            DesktopConfig::load(&path).unwrap(),
            DesktopConfig::load(&path).unwrap()
        );
        assert!(!sibling(&path, ".bak").exists());

        // A corrupt file is backed up before being replaced.
        std::fs::write(&path, "theme = \n[[[").unwrap();
        let mut c = DesktopConfig::load(&path).unwrap();
        c.appearance.theme = Theme::Dark;
        c.save_atomic(&path).unwrap();
        assert_eq!(
            std::fs::read_to_string(sibling(&path, ".bak")).unwrap(),
            "theme = \n[[["
        );
        assert_eq!(
            DesktopConfig::load(&path).unwrap().appearance.theme,
            Theme::Dark
        );

        // No temporary files are left behind.
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names.len(), 2, "{names:?}");
    }

    #[test]
    fn appearance_additions_default_and_round_trip() {
        let (c, w) = parse("[appearance]\ntheme = \"dark\"\n");
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(c.appearance.icon_theme, "Papirus");
        assert_eq!(c.appearance.wallpaper_dark, "");
        let (c, _) =
            parse("[appearance]\nicon_theme = \"Adwaita\"\nwallpaper_dark = \"/a b.jpg\"\n");
        let text = c.to_toml_string().unwrap_or_default();
        let (again, w) = parse(&text);
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(again.appearance.icon_theme, "Adwaita");
        assert_eq!(again.appearance.wallpaper_dark, "/a b.jpg");
        for a in Accent::ALL {
            assert_eq!(Accent::from_name(a.name()), Some(a));
        }
        assert_eq!(Accent::from_name("purple"), None);
    }

    #[test]
    fn unreadable_path_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        // A directory where the file should be.
        let path = dir.path().join(FILE_NAME);
        std::fs::create_dir(&path).unwrap();
        assert!(matches!(
            DesktopConfig::load(&path),
            Err(DesktopConfigError::Read { .. })
        ));
        assert!(DesktopConfig::default().save_atomic(&path).is_err());
    }
}
