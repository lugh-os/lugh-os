//! `Services.appearance`: theme, accent, motion, glass, wallpapers, icons.
//!
//! State: `dark`, `accent`, `reduceMotion`, `transparency`, `wallpaperLight`,
//! `wallpaperDark`, `wallpaperDir`, `iconTheme`.
//! Methods: `setDark(on)`, `setAccent(name)`, `setReduceMotion(on)`,
//! `setTransparency(on)`, `setWallpaper(light, dark)`, `reload()`.
//!
//! The values live in `desktop.toml` (`[appearance]`); this service is the
//! one that writes them, through [`Context::update_config`]. There is no
//! file watcher: whoever edits the file from outside (Settings, the `lugh`
//! CLI) calls `appearance.reload`, which re-reads it when its mtime changed.
//!
//! - `theme = "auto"` is shown as light for now (no day/night schedule yet).
//! - `wallpaper = "lugh://wallpapers/<name>"` is the bundled art, which the
//!   UI finds itself: the state carries `""` for it, and a `file://` URL for
//!   a path.
//! - Inside a Lugh session the theme is mirrored to GTK apps with
//!   `gsettings` (colour scheme and a GTK theme hint), in the background and
//!   best-effort. Outside one (a developer running the shell core on another
//!   desktop) the host desktop's settings are left alone.
//! - The window title-bar buttons are mirrored the same way, to
//!   `org.gnome.desktop.wm.preferences button-layout` (GTK 3/4, libadwaita,
//!   Firefox and Qt's Adwaita decoration read it): always on the right, in
//!   the order of `[shell] titlebarButtons` in `lugh-shell.conf` (written by
//!   the shell's settings), `minimize,maximize,close` by default. It is
//!   applied at start, on theme changes and on every `reload()`.
//! - Hyprland's own title bars (lugh-hyprbars, styled by
//!   `/usr/share/lugh/hypr/lugh/titlebars.lua` from `desktop.toml` and
//!   `[shell] titlebarButtons`) are re-styled with
//!   `hyprctl reload config-only` when the theme or the buttons change.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use serde_json::{Map, Value, json};

use super::{CallError, Context, Service, args};
use crate::config::{Accent, DesktopConfig, ReduceMotion, Theme};

const NAME: &str = "appearance";

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let service = AppearanceService::new(ctx.clone(), DesktopConfig::default_path().ok());
    let dark = service.view().dark;
    // The compositor read both files itself when it loaded its config.
    service.remember_title_bars(dark);
    service.mirror_theme(dark);
    Box::new(service)
}

/// The QML-visible state, derived from the config.
#[derive(Debug, Clone, PartialEq, Eq)]
struct View {
    dark: bool,
    accent: &'static str,
    reduce_motion: bool,
    transparency: bool,
    wallpaper_light: String,
    wallpaper_dark: String,
    icon_theme: String,
}

/// What the UI should load for a `wallpaper` setting: `""` for the bundled
/// art (`lugh://…` or empty), URLs as they are, a `file://` URL for an
/// absolute path (`~/` is the home directory).
fn wallpaper_source(setting: &str, home: Option<&Path>) -> String {
    let s = setting.trim();
    if s.is_empty() || s.starts_with("lugh://") {
        return String::new();
    }
    if s.contains("://") || s.starts_with("qrc:") {
        return s.to_owned();
    }
    let path = match (s.strip_prefix("~/"), home) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => PathBuf::from(s),
    };
    if !path.is_absolute() {
        return String::new();
    }
    let mut url = String::from("file://");
    for &b in path.to_string_lossy().as_bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
            url.push(char::from(b));
        } else {
            url.push_str(&format!("%{b:02X}"));
        }
    }
    url
}

/// The setting to store for what the UI passed to `setWallpaper`: a
/// `file://` URL becomes a plain path, `""` the default.
fn wallpaper_setting(arg: &str, default: &str) -> String {
    let s = arg.trim();
    if s.is_empty() {
        return default.to_owned();
    }
    let Some(rest) = s.strip_prefix("file://") else {
        return s.to_owned();
    };
    // Percent-decode.
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = (bytes[i] == b'%')
            .then(|| rest.get(i + 1..i + 3))
            .flatten()
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match hex {
            Some(b) => {
                out.push(b);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn view_of(config: &DesktopConfig, home: Option<&Path>) -> View {
    let a = &config.appearance;
    View {
        // `auto` follows nothing yet: light.
        dark: a.theme == Theme::Dark,
        accent: a.accent.name(),
        reduce_motion: config.reduce_motion(false),
        transparency: a.transparency,
        wallpaper_light: wallpaper_source(&a.wallpaper, home),
        wallpaper_dark: wallpaper_source(&a.wallpaper_dark, home),
        icon_theme: a.icon_theme.clone(),
    }
}

impl View {
    fn json(&self) -> Map<String, Value> {
        let v = json!({
            "dark": self.dark,
            "accent": self.accent,
            "reduceMotion": self.reduce_motion,
            "transparency": self.transparency,
            "wallpaperLight": self.wallpaper_light,
            "wallpaperDark": self.wallpaper_dark,
            "iconTheme": self.icon_theme,
        });
        match v {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }

    /// Only the keys that differ from `old`.
    fn diff(&self, old: &Self) -> Map<String, Value> {
        let old = old.json();
        self.json()
            .into_iter()
            .filter(|(k, v)| old.get(k) != Some(v))
            .collect()
    }
}

fn mtime(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// The `appearance` service.
#[derive(Debug)]
struct AppearanceService {
    ctx: Context,
    /// `desktop.toml`; `None` when there is no config directory.
    path: Option<PathBuf>,
    home: Option<PathBuf>,
    /// The file's mtime when we last read or wrote it.
    seen: Mutex<Option<SystemTime>>,
    /// Serialises changes so patches leave in order.
    changes: Mutex<()>,
    /// `gsettings`, when mirroring applies (see the module docs).
    gsettings: Option<Arc<PathBuf>>,
    /// `hyprctl`, inside a Lugh session on Hyprland (see the module docs).
    hyprctl: Option<Arc<PathBuf>>,
    /// Theme and button layout the compositor's title bars last got.
    title_bars: Mutex<Option<(bool, String)>>,
}

fn find_in_path(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|p| p.is_file())
}

fn in_lugh_session() -> bool {
    std::env::var("XDG_CURRENT_DESKTOP")
        .is_ok_and(|d| d.split(':').any(|part| part.eq_ignore_ascii_case("lugh")))
}

/// The `gsettings` invocations that mirror the theme.
fn mirror_commands(dark: bool) -> [[&'static str; 4]; 2] {
    const SCHEMA: &str = "org.gnome.desktop.interface";
    [
        [
            "set",
            SCHEMA,
            "color-scheme",
            if dark { "prefer-dark" } else { "default" },
        ],
        [
            "set",
            SCHEMA,
            "gtk-theme",
            if dark { "Adwaita-dark" } else { "Adwaita" },
        ],
    ]
}

/// Title-bar buttons when the shell's settings name none (or none valid).
const DEFAULT_BUTTONS: &str = "minimize,maximize,close";

/// `[shell] titlebarButtons` from the text of `lugh-shell.conf` (a QSettings
/// INI file, which quotes values that contain commas).
fn titlebar_buttons(conf: &str) -> Option<String> {
    let mut in_shell = false;
    let mut found = None;
    for line in conf.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_shell = line == "[shell]";
        } else if in_shell
            && let Some((key, value)) = line.split_once('=')
            && key.trim() == "titlebarButtons"
        {
            found = Some(value.trim().trim_matches('"').to_owned());
        }
    }
    found
}

/// The GTK `button-layout` for a `titlebarButtons` value: the known buttons,
/// in order, once each, on the right (the application menu, if any, left).
fn button_layout(buttons: Option<&str>) -> String {
    let mut kept: Vec<&str> = Vec::new();
    for b in buttons.unwrap_or(DEFAULT_BUTTONS).split(',').map(str::trim) {
        if matches!(b, "minimize" | "maximize" | "close") && !kept.contains(&b) {
            kept.push(b);
        }
    }
    if kept.is_empty() {
        return format!("appmenu:{DEFAULT_BUTTONS}");
    }
    format!("appmenu:{}", kept.join(","))
}

/// `~/.config/lugh/lugh-shell.conf` (honours `XDG_CONFIG_HOME`).
fn shell_conf_path(home: Option<&Path>) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| home.map(|h| h.join(".config")))?;
    Some(base.join("lugh").join("lugh-shell.conf"))
}

impl AppearanceService {
    fn new(ctx: Context, path: Option<PathBuf>) -> Self {
        let seen = path.as_deref().and_then(mtime);
        let gsettings = in_lugh_session()
            .then(|| find_in_path("gsettings"))
            .flatten()
            .map(Arc::new);
        let hyprctl = (in_lugh_session()
            && std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some())
        .then(|| find_in_path("hyprctl"))
        .flatten()
        .map(Arc::new);
        Self {
            ctx,
            path,
            home: std::env::var_os("HOME").map(PathBuf::from),
            seen: Mutex::new(seen),
            changes: Mutex::new(()),
            gsettings,
            hyprctl,
            title_bars: Mutex::new(None),
        }
    }

    fn view(&self) -> View {
        view_of(&self.ctx.config(), self.home.as_deref())
    }

    fn remember_mtime(&self) {
        let now = self.path.as_deref().and_then(mtime);
        match self.seen.lock() {
            Ok(mut seen) => *seen = now,
            Err(poisoned) => *poisoned.into_inner() = now,
        }
    }

    /// Changes the config, saves it and patches what changed.
    fn change(&self, f: impl FnOnce(&mut DesktopConfig)) {
        let _order = self.changes.lock();
        let before = self.view();
        let after = view_of(&self.ctx.update_config(f), self.home.as_deref());
        self.remember_mtime();
        self.publish(&before, &after);
    }

    fn publish(&self, before: &View, after: &View) {
        self.ctx.sink.patch(NAME, Value::Object(after.diff(before)));
        if before.dark != after.dark {
            self.mirror_theme(after.dark);
        }
    }

    /// Re-reads `desktop.toml` if it changed on disk since we last looked.
    /// Returns whether it was read.
    fn reload(&self) -> bool {
        let _order = self.changes.lock();
        // The shell's own settings file may have changed the buttons.
        let layout = self.button_layout_command();
        self.sync_title_bars(self.view().dark, &layout[3]);
        self.run_gsettings(vec![layout]);
        let Some(path) = self.path.as_deref() else {
            return false;
        };
        let now = mtime(path);
        let unchanged = match self.seen.lock() {
            Ok(seen) => *seen == now,
            Err(poisoned) => *poisoned.into_inner() == now,
        };
        if unchanged {
            return false;
        }
        let fresh = match DesktopConfig::load(path) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(%e, "desktop.toml could not be re-read; keeping the current settings");
                return false;
            }
        };
        let before = self.view();
        let after = view_of(&fresh, self.home.as_deref());
        match self.ctx.config.write() {
            Ok(mut shared) => *shared = fresh,
            Err(poisoned) => *poisoned.into_inner() = fresh,
        }
        self.remember_mtime();
        self.publish(&before, &after);
        true
    }

    /// The `gsettings` invocation for the title-bar buttons, from the
    /// shell's settings file as it is now.
    fn button_layout_command(&self) -> [String; 4] {
        let conf = shell_conf_path(self.home.as_deref())
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        [
            "set".into(),
            "org.gnome.desktop.wm.preferences".into(),
            "button-layout".into(),
            button_layout(titlebar_buttons(&conf).as_deref()),
        ]
    }

    /// Tells GTK apps about the theme and the title-bar buttons.
    fn mirror_theme(&self, dark: bool) {
        let mut commands: Vec<[String; 4]> = mirror_commands(dark)
            .iter()
            .map(|c| c.map(str::to_owned))
            .collect();
        let layout = self.button_layout_command();
        self.sync_title_bars(dark, &layout[3]);
        commands.push(layout);
        self.run_gsettings(commands);
    }

    /// Records what the compositor's title bars show now.
    fn remember_title_bars(&self, dark: bool) {
        let layout = self.button_layout_command()[3].clone();
        match self.title_bars.lock() {
            Ok(mut tb) => *tb = Some((dark, layout)),
            Err(poisoned) => *poisoned.into_inner() = Some((dark, layout)),
        }
    }

    /// Re-styles Hyprland's title bars when the theme or the buttons differ
    /// from what they last got (a config reload: the Lua config reads both
    /// files). Fire and forget, like the gsettings mirror.
    fn sync_title_bars(&self, dark: bool, layout: &str) {
        let Some(hyprctl) = self.hyprctl.clone() else {
            return;
        };
        let wanted = Some((dark, layout.to_owned()));
        {
            let mut tb = match self.title_bars.lock() {
                Ok(tb) => tb,
                Err(poisoned) => poisoned.into_inner(),
            };
            if *tb == wanted {
                return;
            }
            *tb = wanted;
        }
        self.ctx.runtime.spawn(async move {
            let run = tokio::process::Command::new(hyprctl.as_path())
                .args(["reload", "config-only"])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .status();
            match tokio::time::timeout(std::time::Duration::from_secs(5), run).await {
                Ok(Ok(status)) if status.success() => {}
                other => tracing::debug!(?other, "hyprctl reload for title bars skipped"),
            }
        });
    }

    /// Runs `gsettings` invocations in order. Fire and forget.
    fn run_gsettings(&self, commands: Vec<[String; 4]>) {
        let Some(gsettings) = self.gsettings.clone() else {
            return;
        };
        self.ctx.runtime.spawn(async move {
            for args in commands {
                let run = tokio::process::Command::new(gsettings.as_path())
                    .args(&args)
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .kill_on_drop(true)
                    .status();
                match tokio::time::timeout(std::time::Duration::from_secs(5), run).await {
                    Ok(Ok(status)) if status.success() => {}
                    other => tracing::debug!(?args, ?other, "gsettings mirror skipped"),
                }
            }
        });
    }
}

impl Service for AppearanceService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        let mut map = self.view().json();
        // Set by the front-end (preview: the repo's art); "" = system art.
        map.insert("wallpaperDir".into(), Value::String(String::new()));
        Value::Object(map)
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        match method {
            "setDark" => {
                let on = args::bool(a, 0)?;
                self.change(|c| {
                    c.appearance.theme = if on { Theme::Dark } else { Theme::Light };
                });
            }
            "setAccent" => {
                let name = args::string(a, 0)?;
                let accent = Accent::from_name(&name)
                    .ok_or_else(|| CallError::BadArgs(format!("unknown accent `{name}`")))?;
                self.change(|c| c.appearance.accent = accent);
            }
            "setReduceMotion" => {
                let on = args::bool(a, 0)?;
                self.change(|c| {
                    c.appearance.reduce_motion = on;
                    // An explicit accessibility override would hide the
                    // switch's effect; hand control back to this setting.
                    c.accessibility.reduce_motion = ReduceMotion::System;
                });
            }
            "setTransparency" => {
                let on = args::bool(a, 0)?;
                self.change(|c| c.appearance.transparency = on);
            }
            "setWallpaper" => {
                let light = args::string_or_empty(a, 0);
                let dark = args::string_or_empty(a, 1);
                self.change(|c| {
                    let default = DesktopConfig::default().appearance;
                    c.appearance.wallpaper = wallpaper_setting(&light, &default.wallpaper);
                    c.appearance.wallpaper_dark = wallpaper_setting(&dark, &default.wallpaper_dark);
                });
            }
            "reload" => return Ok(Value::Bool(self.reload())),
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{RwLock, mpsc};
    use std::time::Duration;

    use super::*;
    use crate::services::{Event, Sink};

    #[test]
    fn wallpaper_sources() {
        let home = Path::new("/home/amara");
        assert_eq!(wallpaper_source("lugh://wallpapers/dawn", Some(home)), "");
        assert_eq!(wallpaper_source("", Some(home)), "");
        assert_eq!(
            wallpaper_source("/usr/share/a b.jpg", Some(home)),
            "file:///usr/share/a%20b.jpg"
        );
        assert_eq!(
            wallpaper_source("~/Pictures/x.png", Some(home)),
            "file:///home/amara/Pictures/x.png"
        );
        assert_eq!(
            wallpaper_source("file:///x.png", Some(home)),
            "file:///x.png"
        );
        assert_eq!(wallpaper_source("relative.png", None), "");
    }

    #[test]
    fn wallpaper_settings_round_trip() {
        assert_eq!(
            wallpaper_setting("", "lugh://wallpapers/dawn"),
            "lugh://wallpapers/dawn"
        );
        assert_eq!(wallpaper_setting("/a/b.png", "d"), "/a/b.png");
        assert_eq!(
            wallpaper_setting("file:///usr/share/a%20b%C3%A9.jpg", "d"),
            "/usr/share/a bé.jpg"
        );
        assert_eq!(wallpaper_setting("file:///100%.png", "d"), "/100%.png");
        assert_eq!(
            wallpaper_source(&wallpaper_setting("file:///a%20b.jpg", "d"), None),
            "file:///a%20b.jpg"
        );
    }

    #[test]
    fn view_follows_the_config() {
        let (c, _) = DesktopConfig::from_toml_str(
            "[appearance]\ntheme = \"dark\"\naccent = \"teal\"\ntransparency = false\n\
             wallpaper = \"/w/light.jpg\"\nwallpaper_dark = \"/w/dark.jpg\"\nicon_theme = \"Adwaita\"\n\
             [accessibility]\nreduce_motion = \"on\"\n",
        );
        let v = view_of(&c, None);
        assert_eq!(
            Value::Object(v.json()),
            json!({
                "dark": true,
                "accent": "teal",
                "reduceMotion": true,
                "transparency": false,
                "wallpaperLight": "file:///w/light.jpg",
                "wallpaperDark": "file:///w/dark.jpg",
                "iconTheme": "Adwaita",
            })
        );
        // `auto` is light for now; defaults.
        let (c, _) = DesktopConfig::from_toml_str("[appearance]\ntheme = \"auto\"\n");
        let d = view_of(&c, None);
        assert!(!d.dark);
        assert_eq!(d.icon_theme, "Papirus");
        assert_eq!(d.wallpaper_light, "");
        // Diff carries only what changed.
        let mut e = d.clone();
        e.accent = "red";
        assert_eq!(Value::Object(e.diff(&d)), json!({ "accent": "red" }));
        assert!(d.diff(&d).is_empty());
    }

    #[test]
    fn mirror_commands_cover_both_themes() {
        assert_eq!(mirror_commands(true)[0][3], "prefer-dark");
        assert_eq!(mirror_commands(false)[0][3], "default");
        assert_eq!(mirror_commands(true)[1][3], "Adwaita-dark");
    }

    #[test]
    fn titlebar_buttons_are_read_from_the_shell_section() {
        let conf = "[general]\ntitlebarButtons=close\n\n[shell]\nfoo=1\ntitlebarButtons=\"close,minimize\"\n";
        assert_eq!(titlebar_buttons(conf).as_deref(), Some("close,minimize"));
        assert_eq!(
            titlebar_buttons("[shell]\ntitlebarButtons=close\n").as_deref(),
            Some("close")
        );
        assert_eq!(titlebar_buttons("[general]\ntitlebarButtons=close\n"), None);
        assert_eq!(titlebar_buttons(""), None);
    }

    #[test]
    fn button_layout_keeps_known_buttons_on_the_right() {
        assert_eq!(button_layout(None), "appmenu:minimize,maximize,close");
        assert_eq!(button_layout(Some("close")), "appmenu:close");
        assert_eq!(
            button_layout(Some(" maximize , close,close ")),
            "appmenu:maximize,close"
        );
        assert_eq!(
            button_layout(Some("menu:spacer")),
            "appmenu:minimize,maximize,close"
        );
        assert_eq!(button_layout(Some("")), "appmenu:minimize,maximize,close");
    }

    /// A service over a config file in a temp dir. Calls that save go to the
    /// default path, so only `reload` and the pure parts are exercised with
    /// files here; `change` is tested through a context whose save target is
    /// redirected by `XDG_CONFIG_HOME` in the live check (svc_dump).
    fn rig(
        text: &str,
    ) -> (
        AppearanceService,
        mpsc::Receiver<Event>,
        tempfile::TempDir,
        tokio::runtime::Runtime,
    ) {
        let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let path = dir.path().join("desktop.toml");
        std::fs::write(&path, text).unwrap_or_else(|e| panic!("write: {e}"));
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap_or_else(|e| panic!("runtime: {e}"));
        let (tx, rx) = mpsc::channel();
        let config = DesktopConfig::load(&path).unwrap_or_default();
        let ctx = Context {
            sink: Sink::new(move |e| {
                let _ = tx.send(e);
            }),
            runtime: rt.handle().clone(),
            config: Arc::new(RwLock::new(config)),
        };
        let mut svc = AppearanceService::new(ctx, Some(path));
        svc.gsettings = None; // never touch the host desktop from tests
        svc.hyprctl = None;
        (svc, rx, dir, rt)
    }

    #[test]
    fn state_matches_the_contract() {
        let (svc, _rx, _dir, _rt) = rig("[appearance]\naccent = \"green\"\n");
        assert_eq!(
            svc.state(),
            json!({
                "dark": false,
                "accent": "green",
                "reduceMotion": false,
                "transparency": true,
                "wallpaperLight": "",
                "wallpaperDark": "",
                "wallpaperDir": "",
                "iconTheme": "Papirus",
            })
        );
    }

    #[test]
    fn reload_reads_only_a_changed_file_and_patches_the_difference() {
        let (svc, rx, dir, _rt) = rig("[appearance]\naccent = \"green\"\n");
        assert_eq!(svc.call("reload", &[]), Ok(Value::Bool(false)));
        assert!(rx.try_recv().is_err());

        let path = dir.path().join("desktop.toml");
        std::fs::write(&path, "[appearance]\naccent = \"blue\"\ntheme = \"dark\"\n")
            .unwrap_or_else(|e| panic!("write: {e}"));
        // Make sure the mtime differs even on coarse filesystems.
        let later = SystemTime::now() + Duration::from_secs(5);
        let f = std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("open: {e}"));
        f.set_modified(later)
            .unwrap_or_else(|e| panic!("mtime: {e}"));
        drop(f);

        assert_eq!(svc.call("reload", &[]), Ok(Value::Bool(true)));
        match rx.try_recv() {
            Ok(Event::Patch { service, data }) => {
                assert_eq!(service, "appearance");
                assert_eq!(
                    Value::Object(data),
                    json!({ "accent": "blue", "dark": true })
                );
            }
            other => panic!("expected a patch, got {other:?}"),
        }
        // The shared config other services read was replaced too.
        assert_eq!(svc.ctx.config().appearance.accent, Accent::Blue);
        assert_eq!(svc.call("reload", &[]), Ok(Value::Bool(false)));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn bad_calls_are_refused_without_side_effects() {
        let (svc, rx, _dir, _rt) = rig("");
        assert!(matches!(
            svc.call("setAccent", &[json!("purple")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("setDark", &[json!("yes")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("setDark", &[]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("explode", &[]),
            Err(CallError::UnknownMethod(_))
        ));
        assert!(rx.try_recv().is_err());
        assert_eq!(svc.ctx.config().appearance.accent, Accent::Amber);
    }
}
