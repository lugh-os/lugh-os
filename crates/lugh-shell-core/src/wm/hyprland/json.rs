//! Hyprland `j/…` request replies, tolerant of the field changes between
//! 0.4x and 0.5x (e.g. `fullscreen` went from a bool to a mode number).

use serde::{Deserialize, Deserializer};

use crate::wm::{Monitor, Rect, Toplevel, WindowId, Workspace, WorkspaceId};

#[derive(Debug, Default, Deserialize)]
pub(super) struct WsRef {
    #[serde(default)]
    pub(super) id: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Client {
    #[serde(default)]
    pub(super) address: Option<String>,
    #[serde(default = "yes")]
    mapped: bool,
    #[serde(default)]
    workspace: WsRef,
    #[serde(default)]
    floating: bool,
    #[serde(default, deserialize_with = "bool_or_mode")]
    fullscreen: bool,
    #[serde(default)]
    pid: i64,
    #[serde(default)]
    class: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    initial_class: String,
    #[serde(default)]
    at: Option<(i32, i32)>,
    #[serde(default)]
    size: Option<(i32, i32)>,
}

#[derive(Debug, Deserialize)]
pub(super) struct WorkspaceJson {
    id: i64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    monitor: String,
    #[serde(default)]
    windows: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct MonitorJson {
    #[serde(default)]
    id: i64,
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    width: u32,
    #[serde(default)]
    height: u32,
    #[serde(default)]
    x: i32,
    #[serde(default)]
    y: i32,
    #[serde(default = "one")]
    scale: f64,
    #[serde(default)]
    active_workspace: WsRef,
    #[serde(default)]
    focused: bool,
    #[serde(default)]
    disabled: bool,
    #[serde(default)]
    transform: u8,
}

fn yes() -> bool {
    true
}

fn one() -> f64 {
    1.0
}

/// `fullscreen` is a bool before Hyprland 0.42 and a mode (0 none,
/// 1 maximised, 2 fullscreen, 3 both) since.
fn bool_or_mode<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum BoolOrInt {
        Bool(bool),
        Int(i64),
    }
    Ok(match BoolOrInt::deserialize(d)? {
        BoolOrInt::Bool(b) => b,
        BoolOrInt::Int(n) => n != 0,
    })
}

impl Client {
    /// The window as a [`Toplevel`]; `None` for unmapped clients and ones
    /// without a usable address.
    pub(super) fn into_toplevel(self) -> Option<Toplevel> {
        if !self.mapped {
            return None;
        }
        let id = WindowId::from_hyprland(self.address.as_deref()?)?;
        let app_id = if self.class.is_empty() {
            self.initial_class
        } else {
            self.class
        };
        Some(Toplevel {
            id,
            app_id,
            title: self.title,
            workspace: WorkspaceId(self.workspace.id?),
            floating: self.floating,
            fullscreen: self.fullscreen,
            pid: u32::try_from(self.pid).ok().filter(|&p| p > 0),
            focused: false,
            urgent: false,
            geometry: match (self.at, self.size) {
                (Some((x, y)), Some((w, h))) => Some(Rect { x, y, w, h }),
                _ => None,
            },
        })
    }
}

impl From<WorkspaceJson> for Workspace {
    fn from(w: WorkspaceJson) -> Self {
        Self {
            id: WorkspaceId(w.id),
            name: if w.name.is_empty() {
                w.id.to_string()
            } else {
                w.name
            },
            monitor: w.monitor,
            windows: w.windows,
            occupied: w.windows > 0,
        }
    }
}

impl MonitorJson {
    /// The output as a [`Monitor`]; `None` when it is disabled.
    pub(super) fn into_monitor(self) -> Option<Monitor> {
        if self.disabled {
            return None;
        }
        Some(Monitor {
            id: self.id,
            name: self.name,
            description: self.description,
            width: self.width,
            height: self.height,
            x: self.x,
            y: self.y,
            scale: self.scale,
            transform: self.transform,
            active_workspace: WorkspaceId(self.active_workspace.id.unwrap_or_default()),
            focused: self.focused,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clients(json: &str) -> Vec<Toplevel> {
        serde_json::from_str::<Vec<Client>>(json)
            .unwrap()
            .into_iter()
            .filter_map(Client::into_toplevel)
            .collect()
    }

    #[test]
    fn clients_050() {
        let t = clients(include_str!("fixtures/clients-0.50.json"));
        assert_eq!(t.len(), 3, "the unmapped client is skipped");
        assert_eq!(t[0].id.as_str(), "0x5a3e1d2c4a00");
        assert_eq!(t[0].app_id, "firefox");
        assert_eq!(t[0].pid, Some(2731));
        assert!(t[0].floating && !t[0].fullscreen);
        assert_eq!(
            t[0].geometry,
            Some(Rect {
                x: 26,
                y: 52,
                w: 1868,
                h: 1002
            })
        );
        assert!(t[1].fullscreen && !t[1].floating);
        assert_eq!(t[2].app_id, "vlc", "falls back to initialClass");
        assert_eq!(t[2].workspace, WorkspaceId(2));
    }

    #[test]
    fn clients_041_bool_fullscreen() {
        let t = clients(include_str!("fixtures/clients-0.41.json"));
        assert_eq!(t.len(), 2);
        assert!(t[0].fullscreen);
        assert_eq!(t[1].workspace, WorkspaceId(-98));
    }

    #[test]
    fn workspaces_and_monitors() {
        let ws: Vec<Workspace> = serde_json::from_str::<Vec<WorkspaceJson>>(include_str!(
            "fixtures/workspaces-0.50.json"
        ))
        .unwrap()
        .into_iter()
        .map(Workspace::from)
        .collect();
        assert_eq!(ws.len(), 3);
        assert_eq!(ws[2].name, "music, loud");
        assert_eq!(ws[2].monitor, "HDMI-A-1");
        assert!(!ws[2].occupied && ws[1].occupied);

        for (json, n) in [
            (include_str!("fixtures/monitors-0.50.json"), 2),
            (include_str!("fixtures/monitors-0.41.json"), 1),
        ] {
            let m: Vec<Monitor> = serde_json::from_str::<Vec<MonitorJson>>(json)
                .unwrap()
                .into_iter()
                .filter_map(MonitorJson::into_monitor)
                .collect();
            assert_eq!(m.len(), n, "disabled outputs are skipped");
            assert!(m[0].focused);
            assert_eq!(m[0].active_workspace, WorkspaceId(1));
        }
    }

    #[test]
    fn empty_active_window() {
        let c: Client = serde_json::from_str("{}").unwrap();
        assert!(c.address.is_none());
        assert!(c.into_toplevel().is_none());
        let w: WsRef = serde_json::from_str("{}").unwrap();
        assert!(w.id.is_none());
    }
}
