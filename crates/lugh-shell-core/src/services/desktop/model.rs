//! Pure cores of the desktop services: no I/O, no locks, unit-tested.
//!
//! - [`match_app`]: window class → desktop-entry id.
//! - [`build_dock`]: pinned + running + launching → dock rows.
//! - [`workspace_rows`]: the workspace dots.
//! - [`dock_overlapped`]: does a window reach into the dock's strip.
//! - [`pick_window`]: which window "activate app" focuses.
//! - row types that serialize to the QML model roles.

use serde::Serialize;
use serde_json::{Value, json};

use crate::launch::LaunchError;
use crate::launcher::{DesktopEntry, SearchResult};
use crate::wm::{Monitor, Rect, Toplevel, WindowId, Workspace, WorkspaceId};

/// Icon for apps without one (same as the QML `apps.iconFor` fallback).
pub(crate) const DEFAULT_ICON: &str = "application-x-executable";
/// The hidden workspace minimized windows live on (docs/dev/hyprland.md).
pub(crate) const MINIMIZED_WORKSPACE: &str = "special:minimized";
/// Height of the strip at the bottom of the monitor the dock occupies.
pub(crate) const DOCK_ZONE_PX: i32 = 100;
/// Workspace dots always shown.
pub(crate) const MIN_WORKSPACES: i64 = 4;
/// Upper bound on workspace dots, whatever ids the compositor reports.
pub(crate) const MAX_WORKSPACES: i64 = 32;

/// `wm.workspaces` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct WsRow {
    #[serde(rename = "wsId")]
    pub(crate) ws_id: i64,
    pub(crate) name: String,
    pub(crate) occupied: bool,
}

/// `wm.toplevels` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct TopRow {
    #[serde(rename = "winId")]
    pub(crate) win_id: String,
    #[serde(rename = "appId")]
    pub(crate) app_id: String,
    pub(crate) title: String,
    pub(crate) workspace: i64,
    pub(crate) focused: bool,
}

/// `apps.installed` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct InstalledRow {
    #[serde(rename = "appId")]
    pub(crate) app_id: String,
    pub(crate) name: String,
    #[serde(rename = "genericName")]
    pub(crate) generic_name: String,
    pub(crate) icon: String,
    pub(crate) keywords: String,
}

/// `apps.dock` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DockItem {
    #[serde(rename = "appId")]
    pub(crate) app_id: String,
    pub(crate) name: String,
    pub(crate) icon: String,
    pub(crate) pinned: bool,
    pub(crate) running: bool,
    pub(crate) windows: u32,
    pub(crate) launching: bool,
    pub(crate) attention: bool,
}

/// `launcher.recent` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RecentRow {
    #[serde(rename = "appId")]
    pub(crate) app_id: String,
    pub(crate) name: String,
    pub(crate) icon: String,
}

/// The windows of one app, for [`build_dock`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AppWindows {
    pub(crate) app_id: String,
    pub(crate) windows: u32,
    pub(crate) urgent: bool,
}

/// Finds the desktop entry a window belongs to, from its class (Wayland
/// `app_id` / X11 class). Passes, each over all entries, first hit wins:
///
/// 1. the class is the entry id (`firefox` → `firefox.desktop`);
/// 2. the class is the entry's `StartupWMClass`, exactly, then ignoring case;
/// 3. ignoring case: the class is the id, or the last dot-segment of the id
///    (`foot` → `org.codeberg.dnkl.foot`), or the id is the last dot-segment
///    of the class (`org.mozilla.firefox` → `firefox`).
pub(crate) fn match_app<'a>(entries: &'a [DesktopEntry], class: &str) -> Option<&'a str> {
    if class.is_empty() {
        return None;
    }
    let last = |s: &str| -> String { s.rsplit('.').next().unwrap_or(s).to_owned() };
    let class_last = class.rsplit('.').next().unwrap_or(class);
    let find = |pred: &dyn Fn(&DesktopEntry) -> bool| {
        entries.iter().find(|e| pred(e)).map(|e| e.id.as_str())
    };
    find(&|e| e.id == class)
        .or_else(|| find(&|e| e.startup_wm_class.as_deref() == Some(class)))
        .or_else(|| {
            find(&|e| {
                e.startup_wm_class
                    .as_deref()
                    .is_some_and(|c| c.eq_ignore_ascii_case(class))
            })
        })
        .or_else(|| find(&|e| e.id.eq_ignore_ascii_case(class)))
        .or_else(|| find(&|e| e.id.contains('.') && last(&e.id).eq_ignore_ascii_case(class)))
        .or_else(|| {
            find(&|e| class_last.len() < class.len() && e.id.eq_ignore_ascii_case(class_last))
        })
}

/// Builds the dock: pinned apps in their order (ids that are not installed
/// are skipped), then running apps that are not pinned in the order their
/// first window appeared, then apps that are still starting.
///
/// `info` gives the display name and icon of an installed app.
pub(crate) fn build_dock(
    pinned: &[String],
    running: &[AppWindows],
    launching: &[&str],
    info: impl Fn(&str) -> Option<(String, String)>,
) -> Vec<DockItem> {
    let mut out: Vec<DockItem> = Vec::with_capacity(pinned.len() + running.len());
    let is_launching = |id: &str| launching.contains(&id);
    for id in pinned {
        if out.iter().any(|d| &d.app_id == id) {
            continue;
        }
        let Some((name, icon)) = info(id) else {
            continue;
        };
        let r = running.iter().find(|r| &r.app_id == id);
        out.push(DockItem {
            app_id: id.clone(),
            name,
            icon,
            pinned: true,
            running: r.is_some(),
            windows: r.map_or(0, |r| r.windows),
            launching: is_launching(id),
            attention: r.is_some_and(|r| r.urgent),
        });
    }
    for r in running {
        if r.app_id.is_empty() || out.iter().any(|d| d.app_id == r.app_id) {
            continue;
        }
        let (name, icon) =
            info(&r.app_id).unwrap_or_else(|| (r.app_id.clone(), DEFAULT_ICON.to_owned()));
        out.push(DockItem {
            app_id: r.app_id.clone(),
            name,
            icon,
            pinned: false,
            running: true,
            windows: r.windows,
            launching: is_launching(&r.app_id),
            attention: r.urgent,
        });
    }
    for id in launching {
        if out.iter().any(|d| d.app_id == *id) {
            continue;
        }
        if let Some((name, icon)) = info(id) {
            out.push(DockItem {
                app_id: (*id).to_owned(),
                name,
                icon,
                pinned: false,
                running: false,
                windows: 0,
                launching: true,
                attention: false,
            });
        }
    }
    out
}

/// Adds `id` at the end of the pinned list. Returns whether it changed.
pub(crate) fn pin(pinned: &mut Vec<String>, id: &str) -> bool {
    if id.is_empty() || pinned.iter().any(|p| p == id) {
        return false;
    }
    pinned.push(id.to_owned());
    true
}

/// Removes `id` from the pinned list. Returns whether it changed.
pub(crate) fn unpin(pinned: &mut Vec<String>, id: &str) -> bool {
    let before = pinned.len();
    pinned.retain(|p| p != id);
    pinned.len() != before
}

/// The workspace dots: ids `1..=max(4, highest regular id)`, capped at
/// [`MAX_WORKSPACES`]. Special workspaces are skipped; ids the compositor
/// does not have (yet) are listed as empty and named by their number.
pub(crate) fn workspace_rows(workspaces: &[Workspace]) -> Vec<WsRow> {
    let highest = workspaces
        .iter()
        .map(|w| w.id.0)
        .filter(|&id| (1..=MAX_WORKSPACES).contains(&id))
        .max()
        .unwrap_or(0);
    (1..=highest.max(MIN_WORKSPACES))
        .map(|id| match workspaces.iter().find(|w| w.id.0 == id) {
            Some(w) => WsRow {
                ws_id: id,
                name: w.name.clone(),
                occupied: w.occupied,
            },
            None => WsRow {
                ws_id: id,
                name: id.to_string(),
                occupied: false,
            },
        })
        .collect()
}

/// Whether a window overlaps the dock's strip: a non-fullscreen window on
/// the workspace shown on the focused monitor whose rectangle reaches into
/// the bottom [`DOCK_ZONE_PX`] of that monitor. Windows without known
/// geometry do not count.
pub(crate) fn dock_overlapped(
    toplevels: &[Toplevel],
    monitors: &[Monitor],
    active: Option<WorkspaceId>,
) -> bool {
    let Some(mon) = monitors.iter().find(|m| m.focused).or(monitors.first()) else {
        return false;
    };
    let ws = if mon.active_workspace.0 > 0 {
        mon.active_workspace
    } else {
        match active {
            Some(ws) => ws,
            None => return false,
        }
    };
    let area = mon.logical_rect();
    let zone = Rect {
        x: area.x,
        y: area.y + area.h - DOCK_ZONE_PX.min(area.h),
        w: area.w,
        h: DOCK_ZONE_PX.min(area.h),
    };
    toplevels.iter().any(|t| {
        t.workspace == ws && !t.fullscreen && t.geometry.is_some_and(|g| g.intersects(&zone))
    })
}

/// Which window "activate this app" focuses. `by_recency` are the app's
/// windows, most recently focused first. When the app already has the focus
/// the least recently focused one is chosen, so repeated activation cycles
/// through all of them; otherwise the most recent one.
pub(crate) fn pick_window<'a>(
    by_recency: &'a [WindowId],
    focused: Option<&WindowId>,
) -> Option<&'a WindowId> {
    let has_focus = focused.is_some_and(|f| by_recency.contains(f));
    if has_focus {
        by_recency.last()
    } else {
        by_recency.first()
    }
}

/// `launcher.results` row: exactly `{kind, group, title, subtitle, icon, target}`.
pub(crate) fn result_row(r: &SearchResult) -> Value {
    json!({
        "kind": r.kind.as_str(),
        "group": r.group,
        "title": r.title,
        "subtitle": r.subtitle,
        "icon": r.icon,
        "target": r.target,
    })
}

/// The plain-language text of `apps.launchFailed`:
/// "Firefox couldn't start: command not found".
pub(crate) fn launch_failure_message(name: &str, error: &LaunchError) -> String {
    let why = match error {
        LaunchError::Spawn { source, .. } => match source.kind() {
            std::io::ErrorKind::NotFound => "command not found",
            std::io::ErrorKind::PermissionDenied => "permission denied",
            _ => "the system could not run it",
        },
        LaunchError::NoTerminal => "no terminal app is installed",
        LaunchError::InvalidExec { .. } | LaunchError::EmptyCommand => {
            "its launcher entry is broken"
        }
    };
    format!("{name} couldn't start: {why}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launcher::Locale;

    fn entry(id: &str, wm_class: Option<&str>) -> DesktopEntry {
        let mut text = format!("[Desktop Entry]\nType=Application\nName={id}\nExec={id}\n");
        if let Some(c) = wm_class {
            text.push_str(&format!("StartupWMClass={c}\n"));
        }
        DesktopEntry::parse(&text, id, &Locale::untranslated()).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn matcher_real_world_cases() {
        let entries = vec![
            entry("firefox-esr", Some("firefox-esr")),
            entry("org.mozilla.firefox", None),
            entry("org.codeberg.dnkl.foot", None),
            entry("org.codeberg.dnkl.footclient", None),
            entry("org.codeberg.dnkl.foot-server", None),
            entry("code-oss", Some("code-oss")),
            entry("code", Some("Code")),
            entry("google-chrome", Some("Google-chrome")),
            entry("idea", Some("jetbrains-idea")),
            entry("org.kde.dolphin", None),
            entry("vlc", None),
            entry("libreoffice-writer", Some("libreoffice-writer")),
            entry("org.telegram.desktop", None),
            entry("Alacritty", None),
        ];
        let m = |class: &str| match_app(&entries, class);
        // Exact id.
        assert_eq!(m("firefox-esr"), Some("firefox-esr"));
        assert_eq!(m("org.kde.dolphin"), Some("org.kde.dolphin"));
        assert_eq!(m("code-oss"), Some("code-oss"));
        assert_eq!(m("org.codeberg.dnkl.foot"), Some("org.codeberg.dnkl.foot"));
        // Last id segment (reverse-DNS ids, Flatpak).
        assert_eq!(m("firefox"), Some("org.mozilla.firefox"));
        assert_eq!(m("foot"), Some("org.codeberg.dnkl.foot"));
        assert_eq!(m("footclient"), Some("org.codeberg.dnkl.footclient"));
        assert_eq!(m("dolphin"), Some("org.kde.dolphin"));
        // StartupWMClass, exact and case-insensitive.
        assert_eq!(m("Google-chrome"), Some("google-chrome"));
        assert_eq!(m("google-chrome"), Some("google-chrome"));
        assert_eq!(m("jetbrains-idea"), Some("idea"));
        assert_eq!(m("Code"), Some("code"));
        // Case-insensitive id.
        assert_eq!(m("VLC"), Some("vlc"));
        assert_eq!(m("alacritty"), Some("Alacritty"));
        // Unknown, empty, and segments that must not match.
        assert_eq!(m("steam_app_440"), None);
        assert_eq!(m(""), None);
        assert_eq!(m("fire"), None);
        assert_eq!(m("server"), None);
    }

    #[test]
    fn matcher_reverse_dns_class_and_precedence() {
        let entries = vec![
            entry("firefox-beta", Some("firefox")),
            entry("firefox", None),
            entry("thunderbird", None),
        ];
        // The exact id wins over another entry's StartupWMClass.
        assert_eq!(match_app(&entries, "firefox"), Some("firefox"));
        // A Flatpak-style class finds the distro entry.
        assert_eq!(match_app(&entries, "org.mozilla.firefox"), Some("firefox"));
        assert_eq!(
            match_app(&entries, "org.mozilla.Thunderbird"),
            Some("thunderbird")
        );
    }

    fn info(id: &str) -> Option<(String, String)> {
        match id {
            "firefox" => Some(("Firefox".into(), "firefox".into())),
            "files" => Some(("Files".into(), "system-file-manager".into())),
            "vlc" => Some(("VLC".into(), "vlc".into())),
            "foot" => Some(("Terminal".into(), "utilities-terminal".into())),
            _ => None,
        }
    }

    fn running(id: &str, windows: u32, urgent: bool) -> AppWindows {
        AppWindows {
            app_id: id.into(),
            windows,
            urgent,
        }
    }

    #[test]
    fn dock_pinned_then_running_then_launching() {
        let pinned: Vec<String> = ["firefox", "not-installed", "files", "firefox"]
            .map(String::from)
            .to_vec();
        let run = [
            running("vlc", 1, true),
            running("firefox", 2, false),
            running("mystery", 1, false),
            running("", 1, false),
        ];
        let dock = build_dock(&pinned, &run, &["files", "foot", "ghost"], info);
        let ids: Vec<&str> = dock.iter().map(|d| d.app_id.as_str()).collect();
        assert_eq!(ids, ["firefox", "files", "vlc", "mystery", "foot"]);
        assert!(dock[0].pinned && dock[0].running && dock[0].windows == 2);
        assert!(dock[1].pinned && !dock[1].running && dock[1].launching);
        assert!(!dock[2].pinned && dock[2].attention && dock[2].name == "VLC");
        assert_eq!(
            (dock[3].name.as_str(), dock[3].icon.as_str()),
            ("mystery", DEFAULT_ICON)
        );
        assert!(dock[4].launching && !dock[4].running && !dock[4].pinned);
        let json = serde_json::to_value(&dock[0]).unwrap_or_default();
        assert_eq!(
            json,
            json!({ "appId": "firefox", "name": "Firefox", "icon": "firefox", "pinned": true,
                    "running": true, "windows": 2, "launching": false, "attention": false })
        );
    }

    #[test]
    fn unpinning_a_running_app_moves_it_after_the_pinned_block() {
        let mut pinned: Vec<String> = ["firefox", "vlc", "files"].map(String::from).to_vec();
        let run = [running("vlc", 1, false), running("firefox", 1, false)];
        assert!(unpin(&mut pinned, "firefox"));
        assert!(!unpin(&mut pinned, "firefox"));
        let dock = build_dock(&pinned, &run, &[], info);
        let ids: Vec<&str> = dock.iter().map(|d| d.app_id.as_str()).collect();
        assert_eq!(ids, ["vlc", "files", "firefox"]);
        assert!(!dock[2].pinned && dock[2].running);
        assert!(pin(&mut pinned, "firefox"));
        assert!(!pin(&mut pinned, "firefox"));
        assert!(!pin(&mut pinned, ""));
        assert_eq!(pinned, ["vlc", "files", "firefox"]);
    }

    fn ws(id: i64, name: &str, windows: u32) -> Workspace {
        Workspace {
            id: WorkspaceId(id),
            name: name.into(),
            monitor: "eDP-1".into(),
            windows,
            occupied: windows > 0,
        }
    }

    #[test]
    fn workspace_list() {
        let rows = workspace_rows(&[]);
        assert_eq!(rows.len(), 4);
        assert!(rows.iter().all(|r| !r.occupied));
        assert_eq!(rows[2].name, "3");

        let rows = workspace_rows(&[
            ws(-98, "special:minimized", 2),
            ws(1, "web", 1),
            ws(6, "6", 0),
            ws(1337, "huge", 1),
        ]);
        let ids: Vec<i64> = rows.iter().map(|r| r.ws_id).collect();
        assert_eq!(ids, [1, 2, 3, 4, 5, 6]);
        assert_eq!((rows[0].name.as_str(), rows[0].occupied), ("web", true));
        assert!(!rows[1].occupied && !rows[5].occupied);
        assert_eq!(
            serde_json::to_value(&rows[0]).unwrap_or_default(),
            json!({ "wsId": 1, "name": "web", "occupied": true })
        );
    }

    fn monitor() -> Monitor {
        Monitor {
            id: 0,
            name: "eDP-1".into(),
            description: String::new(),
            width: 1920,
            height: 1080,
            x: 0,
            y: 0,
            scale: 1.0,
            transform: 0,
            active_workspace: WorkspaceId(1),
            focused: true,
        }
    }

    fn win(ws: i64, rect: Option<(i32, i32, i32, i32)>) -> Toplevel {
        Toplevel {
            id: WindowId::new("0x1"),
            app_id: "x".into(),
            title: "x".into(),
            workspace: WorkspaceId(ws),
            floating: true,
            fullscreen: false,
            pid: None,
            focused: false,
            urgent: false,
            geometry: rect.map(|(x, y, w, h)| Rect { x, y, w, h }),
        }
    }

    #[test]
    fn overlap() {
        let mons = [monitor()];
        let active = Some(WorkspaceId(1));
        let hit = |t: Toplevel| dock_overlapped(&[t], &mons, active);
        // Ends exactly where the strip starts (y 980): no overlap.
        assert!(!hit(win(1, Some((100, 100, 800, 880)))));
        // One pixel into the strip.
        assert!(hit(win(1, Some((100, 100, 800, 881)))));
        // Other workspace, unknown geometry, fullscreen: no.
        assert!(!hit(win(2, Some((0, 0, 1920, 1080)))));
        assert!(!hit(win(1, None)));
        let mut fs = win(1, Some((0, 0, 1920, 1080)));
        fs.fullscreen = true;
        assert!(!hit(fs));
        // Off to the side of the monitor: no.
        assert!(!hit(win(1, Some((1920, 0, 800, 1080)))));
        assert!(!dock_overlapped(&[], &mons, active));
        assert!(!dock_overlapped(
            &[win(1, Some((0, 0, 10, 2000)))],
            &[],
            active
        ));
    }

    #[test]
    fn overlap_uses_logical_size_and_the_focused_monitor() {
        // 2256×1504 at 1.5 → 1504×1003 logical; the strip starts at y 903.
        let mut hidpi = monitor();
        hidpi.width = 2256;
        hidpi.height = 1504;
        hidpi.scale = 1.5;
        assert!(!dock_overlapped(
            &[win(1, Some((26, 52, 1400, 851)))],
            std::slice::from_ref(&hidpi),
            None
        ));
        assert!(dock_overlapped(
            &[win(1, Some((26, 52, 1400, 852)))],
            std::slice::from_ref(&hidpi),
            None
        ));
        // Second monitor to the right has the focus and shows workspace 2.
        let mut left = monitor();
        left.focused = false;
        let mut right = monitor();
        right.x = 1920;
        right.active_workspace = WorkspaceId(2);
        let mons = [left, right];
        assert!(!dock_overlapped(
            &[win(1, Some((0, 900, 500, 180)))],
            &mons,
            None
        ));
        assert!(dock_overlapped(
            &[win(2, Some((2000, 900, 500, 180)))],
            &mons,
            None
        ));
    }

    #[test]
    fn window_picking_cycles() {
        let a = WindowId::new("0xa");
        let b = WindowId::new("0xb");
        let c = WindowId::new("0xc");
        let list = [a.clone(), b.clone(), c.clone()];
        // App not focused: its most recent window.
        assert_eq!(pick_window(&list, None), Some(&a));
        assert_eq!(pick_window(&list, Some(&WindowId::new("0xz"))), Some(&a));
        // App focused: the least recent one, so presses cycle a → c → b → a.
        assert_eq!(pick_window(&list, Some(&a)), Some(&c));
        assert_eq!(
            pick_window(&[c.clone(), a.clone(), b.clone()], Some(&c)),
            Some(&b)
        );
        assert_eq!(pick_window(std::slice::from_ref(&a), Some(&a)), Some(&a));
        assert_eq!(pick_window(&[], Some(&a)), None);
    }

    #[test]
    fn failure_messages_are_plain() {
        let spawn = |kind| LaunchError::Spawn {
            program: "firefox".into(),
            source: std::io::Error::from(kind),
        };
        assert_eq!(
            launch_failure_message("Firefox", &spawn(std::io::ErrorKind::NotFound)),
            "Firefox couldn't start: command not found"
        );
        assert_eq!(
            launch_failure_message("Firefox", &spawn(std::io::ErrorKind::PermissionDenied)),
            "Firefox couldn't start: permission denied"
        );
        assert_eq!(
            launch_failure_message("htop", &LaunchError::NoTerminal),
            "htop couldn't start: no terminal app is installed"
        );
    }

    #[test]
    fn result_rows_have_exactly_the_model_roles() {
        let r = SearchResult {
            kind: crate::launcher::ResultKind::App,
            group: "Apps".into(),
            title: "Firefox".into(),
            subtitle: "Web Browser".into(),
            icon: "firefox".into(),
            target: "firefox".into(),
            score: 99,
        };
        assert_eq!(
            result_row(&r),
            json!({ "kind": "app", "group": "Apps", "title": "Firefox",
                    "subtitle": "Web Browser", "icon": "firefox", "target": "firefox" })
        );
    }
}
