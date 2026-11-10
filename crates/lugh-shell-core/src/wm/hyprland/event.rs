//! Parsing of `.socket2.sock` event lines (`EVENT>>DATA`).
//!
//! Payload fields are comma-separated, but titles and workspace names may
//! contain commas (and `>>`), so every event splits off exactly as many
//! leading fields as it has and keeps the rest verbatim. Anything that does
//! not parse becomes [`WmEvent::Unknown`]; parsing never panics.

use crate::wm::{WindowId, WmEvent, WorkspaceId};

/// Parses one event line (without its trailing newline).
pub fn parse_event(line: &str) -> WmEvent {
    let line = line.strip_suffix('\r').unwrap_or(line);
    let Some((name, data)) = line.split_once(">>") else {
        return unknown(line, "");
    };
    parse_known(name, data).unwrap_or_else(|| unknown(name, data))
}

fn unknown(name: &str, data: &str) -> WmEvent {
    WmEvent::Unknown {
        name: name.to_owned(),
        data: data.to_owned(),
    }
}

fn parse_known(name: &str, data: &str) -> Option<WmEvent> {
    let ev = match name {
        "workspace" => WmEvent::Workspace {
            name: data.to_owned(),
        },
        "workspacev2" => {
            let (id, name) = id_name(data)?;
            WmEvent::WorkspaceV2 { id, name }
        }
        "focusedmon" => {
            let (monitor, workspace) = data.split_once(',')?;
            WmEvent::FocusedMon {
                monitor: monitor.to_owned(),
                workspace: workspace.to_owned(),
            }
        }
        "focusedmonv2" => {
            let (monitor, id) = data.split_once(',')?;
            WmEvent::FocusedMonV2 {
                monitor: monitor.to_owned(),
                workspace: ws_id(id)?,
            }
        }
        "activewindow" => {
            let (class, title) = data.split_once(',').unwrap_or((data, ""));
            WmEvent::ActiveWindow {
                class: class.to_owned(),
                title: title.to_owned(),
            }
        }
        "activewindowv2" => {
            let addr = data.trim();
            let id = if addr.is_empty() || addr == "," {
                None
            } else {
                Some(WindowId::from_hyprland(addr)?)
            };
            WmEvent::ActiveWindowV2 { id }
        }
        "openwindow" => {
            let mut f = data.splitn(4, ',');
            let id = window(f.next()?)?;
            let workspace = f.next()?.to_owned();
            let class = f.next()?.to_owned();
            let title = f.next().unwrap_or_default().to_owned();
            WmEvent::OpenWindow {
                id,
                workspace,
                class,
                title,
            }
        }
        "closewindow" => WmEvent::CloseWindow { id: window(data)? },
        "movewindow" => {
            let (addr, workspace) = data.split_once(',')?;
            WmEvent::MoveWindow {
                id: window(addr)?,
                workspace: workspace.to_owned(),
            }
        }
        "movewindowv2" => {
            let mut f = data.splitn(3, ',');
            let id = window(f.next()?)?;
            let workspace = ws_id(f.next()?)?;
            let name = f.next().unwrap_or_default().to_owned();
            WmEvent::MoveWindowV2 {
                id,
                workspace,
                name,
            }
        }
        "windowtitle" => WmEvent::WindowTitle { id: window(data)? },
        "windowtitlev2" => {
            let (addr, title) = data.split_once(',')?;
            WmEvent::WindowTitleV2 {
                id: window(addr)?,
                title: title.to_owned(),
            }
        }
        "fullscreen" => WmEvent::Fullscreen { on: flag(data)? },
        "changefloatingmode" => {
            let (addr, floating) = data.split_once(',')?;
            WmEvent::ChangeFloatingMode {
                id: window(addr)?,
                floating: flag(floating)?,
            }
        }
        "createworkspace" => WmEvent::CreateWorkspace {
            name: data.to_owned(),
        },
        "createworkspacev2" => {
            let (id, name) = id_name(data)?;
            WmEvent::CreateWorkspaceV2 { id, name }
        }
        "destroyworkspace" => WmEvent::DestroyWorkspace {
            name: data.to_owned(),
        },
        "destroyworkspacev2" => {
            let (id, name) = id_name(data)?;
            WmEvent::DestroyWorkspaceV2 { id, name }
        }
        "renameworkspace" => {
            let (id, name) = id_name(data)?;
            WmEvent::RenameWorkspace { id, name }
        }
        "moveworkspacev2" => {
            // ID,NAME,MONNAME: the name may contain commas, the monitor not.
            let (id, rest) = data.split_once(',')?;
            let (name, monitor) = rest.rsplit_once(',')?;
            WmEvent::MoveWorkspaceV2 {
                id: ws_id(id)?,
                name: name.to_owned(),
                monitor: monitor.to_owned(),
            }
        }
        "monitoradded" => WmEvent::MonitorAdded {
            name: nonempty(data)?,
        },
        "monitorremoved" => WmEvent::MonitorRemoved {
            name: nonempty(data)?,
        },
        "monitoraddedv2" => WmEvent::MonitorAdded {
            name: nonempty(data.split(',').nth(1)?)?,
        },
        "monitorremovedv2" => WmEvent::MonitorRemoved {
            name: nonempty(data.split(',').nth(1)?)?,
        },
        "urgent" => WmEvent::Urgent { id: window(data)? },
        "configreloaded" => WmEvent::ConfigReloaded,
        _ => return None,
    };
    Some(ev)
}

fn window(addr: &str) -> Option<WindowId> {
    WindowId::from_hyprland(addr)
}

fn ws_id(s: &str) -> Option<WorkspaceId> {
    s.trim().parse().ok().map(WorkspaceId)
}

fn id_name(data: &str) -> Option<(WorkspaceId, String)> {
    let (id, name) = data.split_once(',')?;
    Some((ws_id(id)?, name.to_owned()))
}

fn flag(s: &str) -> Option<bool> {
    match s.trim() {
        "0" => Some(false),
        "1" | "2" => Some(true),
        _ => None,
    }
}

fn nonempty(s: &str) -> Option<String> {
    (!s.is_empty()).then(|| s.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> WindowId {
        WindowId::new(s)
    }

    #[test]
    fn captured_session_parses() {
        // A recorded Hyprland 0.50 event log (fixtures/events-0.50.log).
        let log = include_str!("fixtures/events-0.50.log");
        let events: Vec<_> = log.lines().map(parse_event).collect();
        let unknown: Vec<_> = events
            .iter()
            .filter_map(|e| match e {
                WmEvent::Unknown { name, .. } => Some(name.as_str()),
                _ => None,
            })
            .collect();
        // Events the reducer has no use for stay Unknown, nothing else does.
        assert_eq!(
            unknown,
            [
                "activelayout",
                "openlayer",
                "openlayer",
                "activespecial",
                "activespecialv2",
                "bell",
                "closelayer",
            ]
        );
        assert!(events.contains(&WmEvent::OpenWindow {
            id: w("0x5a3e1d2c4b10"),
            workspace: "2".into(),
            class: "org.codeberg.dnkl.foot".into(),
            title: "amara@lugh-laptop: ~".into(),
        }));
    }

    #[test]
    fn workspace_events() {
        assert_eq!(
            parse_event("workspace>>2"),
            WmEvent::Workspace { name: "2".into() }
        );
        assert_eq!(
            parse_event("workspacev2>>3,web, mail"),
            WmEvent::WorkspaceV2 {
                id: WorkspaceId(3),
                name: "web, mail".into()
            }
        );
        assert_eq!(
            parse_event("createworkspacev2>>-98,special:magic"),
            WmEvent::CreateWorkspaceV2 {
                id: WorkspaceId(-98),
                name: "special:magic".into()
            }
        );
        assert_eq!(
            parse_event("destroyworkspacev2>>4,4"),
            WmEvent::DestroyWorkspaceV2 {
                id: WorkspaceId(4),
                name: "4".into()
            }
        );
        assert_eq!(
            parse_event("moveworkspacev2>>2,a,b,HDMI-A-1"),
            WmEvent::MoveWorkspaceV2 {
                id: WorkspaceId(2),
                name: "a,b".into(),
                monitor: "HDMI-A-1".into()
            }
        );
        assert_eq!(
            parse_event("renameworkspace>>2,code"),
            WmEvent::RenameWorkspace {
                id: WorkspaceId(2),
                name: "code".into()
            }
        );
        assert_eq!(
            parse_event("focusedmonv2>>DP-1,3"),
            WmEvent::FocusedMonV2 {
                monitor: "DP-1".into(),
                workspace: WorkspaceId(3)
            }
        );
    }

    #[test]
    fn titles_keep_commas_and_arrows() {
        assert_eq!(
            parse_event("openwindow>>55aa01,1,firefox,Re: a, b >> c — Mozilla Firefox"),
            WmEvent::OpenWindow {
                id: w("0x55aa01"),
                workspace: "1".into(),
                class: "firefox".into(),
                title: "Re: a, b >> c — Mozilla Firefox".into()
            }
        );
        assert_eq!(
            parse_event("windowtitlev2>>55aa01,x,y>>z"),
            WmEvent::WindowTitleV2 {
                id: w("0x55aa01"),
                title: "x,y>>z".into()
            }
        );
        assert_eq!(
            parse_event("activewindow>>firefox,a, b"),
            WmEvent::ActiveWindow {
                class: "firefox".into(),
                title: "a, b".into()
            }
        );
        assert_eq!(
            parse_event("movewindowv2>>55aa01,4,my, ws"),
            WmEvent::MoveWindowV2 {
                id: w("0x55aa01"),
                workspace: WorkspaceId(4),
                name: "my, ws".into()
            }
        );
        // An empty title is still a valid open event.
        assert!(matches!(
            parse_event("openwindow>>55aa02,1,steam,"),
            WmEvent::OpenWindow { title, .. } if title.is_empty()
        ));
    }

    #[test]
    fn focus_none() {
        for line in ["activewindowv2>>", "activewindowv2>>,", "activewindowv2>> "] {
            assert_eq!(parse_event(line), WmEvent::ActiveWindowV2 { id: None });
        }
        assert_eq!(
            parse_event("activewindow>>,"),
            WmEvent::ActiveWindow {
                class: String::new(),
                title: String::new()
            }
        );
    }

    #[test]
    fn flags_and_simple_events() {
        assert_eq!(
            parse_event("fullscreen>>1"),
            WmEvent::Fullscreen { on: true }
        );
        assert_eq!(
            parse_event("changefloatingmode>>55aa01,0"),
            WmEvent::ChangeFloatingMode {
                id: w("0x55aa01"),
                floating: false
            }
        );
        assert_eq!(parse_event("configreloaded>>"), WmEvent::ConfigReloaded);
        assert_eq!(
            parse_event("urgent>>55aa01\r"),
            WmEvent::Urgent { id: w("0x55aa01") }
        );
        assert_eq!(
            parse_event("monitoraddedv2>>1,HDMI-A-1,Dell Inc. U2720Q"),
            WmEvent::MonitorAdded {
                name: "HDMI-A-1".into()
            }
        );
        assert_eq!(
            parse_event("monitorremoved>>HDMI-A-1"),
            WmEvent::MonitorRemoved {
                name: "HDMI-A-1".into()
            }
        );
    }

    #[test]
    fn garbage_is_unknown_never_panics() {
        let cases = [
            "",
            ">>",
            "no separator",
            "openwindow>>",
            "openwindow>>zz,1,a,b",
            "openwindow>>55aa,1",
            "closewindow>>not-hex",
            "workspacev2>>x,1",
            "workspacev2>>1",
            "fullscreen>>maybe",
            "movewindowv2>>55aa,,1",
            "monitoradded>>",
            "activewindowv2>>0xGG",
            "moveworkspacev2>>1,name",
            "\u{0}\u{ff}>>>>>>",
            "openwindow>>55aa,1,é,\u{fffd}",
        ];
        for line in cases {
            let _ = parse_event(line);
        }
        assert_eq!(
            parse_event("closewindow>>not-hex"),
            WmEvent::Unknown {
                name: "closewindow".into(),
                data: "not-hex".into()
            }
        );
        assert_eq!(
            parse_event("no separator"),
            WmEvent::Unknown {
                name: "no separator".into(),
                data: String::new()
            }
        );
    }
}
