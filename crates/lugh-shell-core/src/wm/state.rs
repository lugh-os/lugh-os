//! [`WmState`]: applies [`WmEvent`]s to a [`WmSnapshot`] and reports the
//! minimal model changes.

use super::{Monitor, Toplevel, WindowId, WmEvent, WmSnapshot, Workspace, WorkspaceId};

/// One change to forward to the QML models.
///
/// Changes come in an order that keeps the models consistent when applied
/// one by one: a workspace is added before windows that reference it and
/// removed after them.
///
/// The focused-app properties (`focusedAppId`, `focusedTitle`) follow from
/// [`WmChange::FocusChanged`] plus [`WmChange::ToplevelChanged`] of the
/// focused window (e.g. a title change); [`WmState::focused_toplevel`] gives
/// the current values.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WmChange {
    /// A workspace appeared (insert sorted by id).
    WorkspaceAdded(Workspace),
    /// A workspace is gone.
    WorkspaceRemoved(WorkspaceId),
    /// A workspace's name, monitor or window count changed.
    WorkspaceChanged(Workspace),
    /// A window was mapped (append).
    ToplevelAdded(Toplevel),
    /// A window was closed.
    ToplevelRemoved(WindowId),
    /// A window's title, workspace, focus, floating, fullscreen or urgency changed.
    ToplevelChanged(Toplevel),
    /// The workspace on the focused monitor changed (`activeWorkspace`).
    ActiveWorkspaceChanged(Option<WorkspaceId>),
    /// Keyboard focus moved to another window, or to none.
    FocusChanged(Option<WindowId>),
}

/// The window-manager state kept by the shell, updated incrementally.
#[derive(Debug, Clone, Default)]
pub struct WmState {
    workspaces: Vec<Workspace>,
    toplevels: Vec<Toplevel>,
    monitors: Vec<Monitor>,
    active: Option<WorkspaceId>,
    focused: Option<WindowId>,
    resync: bool,
}

impl WmState {
    /// An empty state; [`reset`](Self::reset) it from a snapshot.
    pub fn new() -> Self {
        Self::default()
    }

    /// A state initialised from a snapshot.
    pub fn from_snapshot(snapshot: WmSnapshot) -> Self {
        let mut state = Self::new();
        state.reset(snapshot);
        state
    }

    /// Workspaces, sorted by id.
    pub fn workspaces(&self) -> &[Workspace] {
        &self.workspaces
    }

    /// Windows, in mapping order.
    pub fn toplevels(&self) -> &[Toplevel] {
        &self.toplevels
    }

    /// Outputs.
    pub fn monitors(&self) -> &[Monitor] {
        &self.monitors
    }

    /// Workspace on the focused monitor.
    pub fn active_workspace(&self) -> Option<WorkspaceId> {
        self.active
    }

    /// Focused window id.
    pub fn focused(&self) -> Option<&WindowId> {
        self.focused.as_ref()
    }

    /// Focused window.
    pub fn focused_toplevel(&self) -> Option<&Toplevel> {
        self.focused.as_ref().and_then(|id| self.toplevel(id))
    }

    /// A window by id.
    pub fn toplevel(&self, id: &WindowId) -> Option<&Toplevel> {
        self.toplevels.iter().find(|t| &t.id == id)
    }

    /// A workspace by id.
    pub fn workspace(&self, id: WorkspaceId) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    /// Copies the current state out.
    pub fn snapshot(&self) -> WmSnapshot {
        WmSnapshot {
            workspaces: self.workspaces.clone(),
            toplevels: self.toplevels.clone(),
            monitors: self.monitors.clone(),
            active_workspace: self.active,
            focused: self.focused.clone(),
        }
    }

    /// Whether events since the last snapshot could not be applied exactly.
    /// Returns the flag and clears it; when `true`, take a fresh snapshot and
    /// [`reset`](Self::reset).
    pub fn take_resync(&mut self) -> bool {
        std::mem::take(&mut self.resync)
    }

    /// Replaces the state with `snapshot` and returns the difference.
    ///
    /// Window counts and per-window focus flags are recomputed so they agree
    /// with what incremental updates would produce.
    pub fn reset(&mut self, snapshot: WmSnapshot) -> Vec<WmChange> {
        let WmSnapshot {
            mut workspaces,
            mut toplevels,
            monitors,
            active_workspace,
            focused,
        } = snapshot;

        workspaces.sort_by_key(|w| w.id);
        workspaces.dedup_by_key(|w| w.id);
        for t in &mut toplevels {
            t.focused = focused.as_ref() == Some(&t.id);
            if t.focused {
                t.urgent = false;
            } else if self.toplevel(&t.id).is_some_and(|old| old.urgent) {
                // Snapshots do not carry urgency: keep what the events said.
                t.urgent = true;
            }
        }
        for w in &mut workspaces {
            set_count(w, count_on(&toplevels, w.id));
        }

        let mut out = Vec::new();
        for w in &workspaces {
            match self.workspace(w.id) {
                None => out.push(WmChange::WorkspaceAdded(w.clone())),
                Some(old) if old != w => out.push(WmChange::WorkspaceChanged(w.clone())),
                Some(_) => {}
            }
        }
        for old in &self.toplevels {
            if !toplevels.iter().any(|t| t.id == old.id) {
                out.push(WmChange::ToplevelRemoved(old.id.clone()));
            }
        }
        for t in &toplevels {
            match self.toplevel(&t.id) {
                None => out.push(WmChange::ToplevelAdded(t.clone())),
                Some(old) if old != t => out.push(WmChange::ToplevelChanged(t.clone())),
                Some(_) => {}
            }
        }
        for old in &self.workspaces {
            if !workspaces.iter().any(|w| w.id == old.id) {
                out.push(WmChange::WorkspaceRemoved(old.id));
            }
        }
        if self.active != active_workspace {
            out.push(WmChange::ActiveWorkspaceChanged(active_workspace));
        }
        if self.focused != focused {
            out.push(WmChange::FocusChanged(focused.clone()));
        }

        self.workspaces = workspaces;
        self.toplevels = toplevels;
        self.monitors = monitors;
        self.active = active_workspace;
        self.focused = focused;
        self.resync = false;
        out
    }

    /// Applies one event and returns the resulting model changes (often
    /// none: Hyprland sends legacy and `v2` forms of most events).
    pub fn apply(&mut self, event: &WmEvent) -> Vec<WmChange> {
        let mut out = Vec::new();
        match event {
            WmEvent::Workspace { name } => match self.ws_by_name(name) {
                Some(id) => self.set_active(id, &mut out),
                None => self.resync = true,
            },
            WmEvent::WorkspaceV2 { id, name } => {
                self.ensure_workspace(*id, name, &mut out);
                self.set_active(*id, &mut out);
            }
            WmEvent::FocusedMon { monitor, workspace } => {
                self.focus_monitor(monitor);
                match self.ws_by_name(workspace) {
                    Some(id) => self.set_active(id, &mut out),
                    None => self.resync = true,
                }
            }
            WmEvent::FocusedMonV2 { monitor, workspace } => {
                self.focus_monitor(monitor);
                if self.workspace(*workspace).is_none() {
                    self.resync = true;
                }
                self.set_active(*workspace, &mut out);
            }
            // The v2 form carries the address; the class/title pair adds nothing.
            WmEvent::ActiveWindow { .. } | WmEvent::WindowTitle { .. } => {}
            WmEvent::ActiveWindowV2 { id } => self.set_focus(id.clone(), &mut out),
            WmEvent::OpenWindow {
                id,
                workspace,
                class,
                title,
            } => {
                if self.toplevel(id).is_some() {
                    return out;
                }
                let Some(ws) = self.ws_by_name(workspace) else {
                    self.resync = true;
                    return out;
                };
                let t = Toplevel {
                    id: id.clone(),
                    app_id: class.clone(),
                    title: title.clone(),
                    workspace: ws,
                    floating: false,
                    fullscreen: false,
                    pid: None,
                    focused: self.focused.as_ref() == Some(id),
                    urgent: false,
                    geometry: None,
                };
                self.toplevels.push(t.clone());
                out.push(WmChange::ToplevelAdded(t));
                self.recount(ws, &mut out);
            }
            WmEvent::CloseWindow { id } => {
                let Some(pos) = self.toplevels.iter().position(|t| &t.id == id) else {
                    return out;
                };
                let t = self.toplevels.remove(pos);
                out.push(WmChange::ToplevelRemoved(t.id));
                self.recount(t.workspace, &mut out);
                if self.focused.as_ref() == Some(id) {
                    self.focused = None;
                    out.push(WmChange::FocusChanged(None));
                }
            }
            WmEvent::MoveWindow { id, workspace } => match self.ws_by_name(workspace) {
                Some(ws) => self.move_window(id, ws, &mut out),
                None => self.resync = true,
            },
            WmEvent::MoveWindowV2 { id, workspace, .. } => {
                if self.workspace(*workspace).is_none() {
                    self.resync = true;
                }
                self.move_window(id, *workspace, &mut out);
            }
            WmEvent::WindowTitleV2 { id, title } => {
                self.update_toplevel(id, &mut out, |t| t.title.clone_from(title));
            }
            WmEvent::Fullscreen { on } => {
                if let Some(id) = self.focused.clone() {
                    self.update_toplevel(&id, &mut out, |t| t.fullscreen = *on);
                }
            }
            WmEvent::ChangeFloatingMode { id, floating } => {
                self.update_toplevel(id, &mut out, |t| t.floating = *floating);
            }
            WmEvent::CreateWorkspace { name } => {
                // Named workspaces are added by the v2 event, which has the id.
                if self.ws_by_name(name).is_none()
                    && let Ok(id) = name.parse::<i64>()
                {
                    self.ensure_workspace(WorkspaceId(id), name, &mut out);
                }
            }
            WmEvent::CreateWorkspaceV2 { id, name } => self.ensure_workspace(*id, name, &mut out),
            WmEvent::DestroyWorkspace { name } => {
                if let Some(id) = self
                    .workspaces
                    .iter()
                    .find(|w| &w.name == name)
                    .map(|w| w.id)
                {
                    self.remove_workspace(id, &mut out);
                }
            }
            WmEvent::DestroyWorkspaceV2 { id, .. } => self.remove_workspace(*id, &mut out),
            WmEvent::RenameWorkspace { id, name } => {
                self.update_workspace(*id, &mut out, |w| w.name.clone_from(name));
            }
            WmEvent::MoveWorkspaceV2 { id, monitor, .. } => {
                self.update_workspace(*id, &mut out, |w| w.monitor.clone_from(monitor));
            }
            WmEvent::Urgent { id } => {
                if self.focused.as_ref() != Some(id) {
                    self.update_toplevel(id, &mut out, |t| t.urgent = true);
                }
            }
            WmEvent::MonitorAdded { .. }
            | WmEvent::MonitorRemoved { .. }
            | WmEvent::ConfigReloaded
            | WmEvent::Reconnected => self.resync = true,
            WmEvent::Unknown { .. } | WmEvent::Disconnected => {}
        }
        out
    }

    fn ws_by_name(&self, name: &str) -> Option<WorkspaceId> {
        self.workspaces
            .iter()
            .find(|w| w.name == name)
            .map(|w| w.id)
            .or_else(|| {
                // Unnamed workspaces are called by their id.
                let id = WorkspaceId(name.parse().ok()?);
                self.workspace(id).map(|w| w.id)
            })
    }

    fn focused_monitor(&self) -> Option<&Monitor> {
        self.monitors.iter().find(|m| m.focused)
    }

    fn focus_monitor(&mut self, name: &str) {
        if !self.monitors.iter().any(|m| m.name == name) {
            self.resync = true;
        }
        for m in &mut self.monitors {
            m.focused = m.name == name;
        }
    }

    fn set_active(&mut self, id: WorkspaceId, out: &mut Vec<WmChange>) {
        if let Some(m) = self.monitors.iter_mut().find(|m| m.focused) {
            m.active_workspace = id;
        }
        if self.active != Some(id) {
            self.active = Some(id);
            out.push(WmChange::ActiveWorkspaceChanged(Some(id)));
        }
    }

    fn set_focus(&mut self, id: Option<WindowId>, out: &mut Vec<WmChange>) {
        if self.focused == id {
            return;
        }
        if let Some(old) = self.focused.take() {
            self.update_toplevel(&old, out, |t| t.focused = false);
        }
        if let Some(new) = &id {
            if self.toplevel(new).is_none() {
                self.resync = true;
            }
            self.update_toplevel(new, out, |t| {
                t.focused = true;
                t.urgent = false;
            });
        }
        self.focused.clone_from(&id);
        out.push(WmChange::FocusChanged(id));
    }

    fn ensure_workspace(&mut self, id: WorkspaceId, name: &str, out: &mut Vec<WmChange>) {
        if self.workspace(id).is_some() {
            return;
        }
        let mut ws = Workspace {
            id,
            name: name.to_owned(),
            monitor: self
                .focused_monitor()
                .map(|m| m.name.clone())
                .unwrap_or_default(),
            windows: 0,
            occupied: false,
        };
        set_count(&mut ws, count_on(&self.toplevels, id));
        let pos = self.workspaces.partition_point(|w| w.id < id);
        self.workspaces.insert(pos, ws.clone());
        out.push(WmChange::WorkspaceAdded(ws));
    }

    fn remove_workspace(&mut self, id: WorkspaceId, out: &mut Vec<WmChange>) {
        let Some(pos) = self.workspaces.iter().position(|w| w.id == id) else {
            return;
        };
        if self.toplevels.iter().any(|t| t.workspace == id) {
            // Hyprland only destroys empty workspaces; our view is stale.
            self.resync = true;
        }
        self.workspaces.remove(pos);
        out.push(WmChange::WorkspaceRemoved(id));
    }

    fn move_window(&mut self, id: &WindowId, ws: WorkspaceId, out: &mut Vec<WmChange>) {
        let Some(from) = self.toplevel(id).map(|t| t.workspace) else {
            return;
        };
        if from == ws {
            return;
        }
        self.update_toplevel(id, out, |t| t.workspace = ws);
        self.recount(from, out);
        self.recount(ws, out);
    }

    fn update_toplevel(
        &mut self,
        id: &WindowId,
        out: &mut Vec<WmChange>,
        f: impl FnOnce(&mut Toplevel),
    ) {
        if let Some(t) = self.toplevels.iter_mut().find(|t| &t.id == id) {
            let before = t.clone();
            f(t);
            if *t != before {
                out.push(WmChange::ToplevelChanged(t.clone()));
            }
        }
    }

    fn update_workspace(
        &mut self,
        id: WorkspaceId,
        out: &mut Vec<WmChange>,
        f: impl FnOnce(&mut Workspace),
    ) {
        if let Some(w) = self.workspaces.iter_mut().find(|w| w.id == id) {
            let before = w.clone();
            f(w);
            if *w != before {
                out.push(WmChange::WorkspaceChanged(w.clone()));
            }
        } else {
            self.resync = true;
        }
    }

    fn recount(&mut self, id: WorkspaceId, out: &mut Vec<WmChange>) {
        let n = count_on(&self.toplevels, id);
        self.update_workspace(id, out, |w| set_count(w, n));
    }
}

fn count_on(toplevels: &[Toplevel], ws: WorkspaceId) -> u32 {
    let n = toplevels.iter().filter(|t| t.workspace == ws).count();
    u32::try_from(n).unwrap_or(u32::MAX)
}

fn set_count(w: &mut Workspace, n: u32) {
    w.windows = n;
    w.occupied = n > 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws(id: i64) -> Workspace {
        Workspace {
            id: WorkspaceId(id),
            name: id.to_string(),
            monitor: "eDP-1".into(),
            windows: 0,
            occupied: false,
        }
    }

    fn win(addr: &str, app: &str, ws: i64) -> Toplevel {
        Toplevel {
            id: WindowId::new(addr),
            app_id: app.into(),
            title: app.into(),
            workspace: WorkspaceId(ws),
            floating: true,
            fullscreen: false,
            pid: Some(100),
            focused: false,
            urgent: false,
            geometry: None,
        }
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

    fn state() -> WmState {
        WmState::from_snapshot(WmSnapshot {
            workspaces: vec![ws(2), ws(1)],
            toplevels: vec![win("0xa", "firefox", 1), win("0xb", "foot", 2)],
            monitors: vec![monitor()],
            active_workspace: Some(WorkspaceId(1)),
            focused: Some(WindowId::new("0xa")),
        })
    }

    fn id(s: &str) -> WindowId {
        WindowId::new(s)
    }

    #[test]
    fn reset_normalises() {
        let s = state();
        assert_eq!(s.workspaces()[0].id, WorkspaceId(1));
        assert!(s.workspaces().iter().all(|w| w.occupied && w.windows == 1));
        assert!(s.toplevel(&id("0xa")).is_some_and(|t| t.focused));
        assert!(s.toplevel(&id("0xb")).is_some_and(|t| !t.focused));
        assert_eq!(
            s.focused_toplevel().map(|t| t.app_id.as_str()),
            Some("firefox")
        );
    }

    #[test]
    fn reset_from_empty_lists_everything_in_order() {
        let mut s = WmState::new();
        let changes = s.reset(state().snapshot());
        assert!(matches!(changes[0], WmChange::WorkspaceAdded(_)));
        assert!(matches!(changes[1], WmChange::WorkspaceAdded(_)));
        assert!(matches!(changes[2], WmChange::ToplevelAdded(_)));
        assert_eq!(
            changes.last(),
            Some(&WmChange::FocusChanged(Some(id("0xa"))))
        );
        // Same snapshot again: nothing to do.
        assert!(s.reset(state().snapshot()).is_empty());
    }

    #[test]
    fn reset_diff_is_minimal() {
        let mut s = state();
        let mut snap = s.snapshot();
        snap.toplevels.retain(|t| t.id != id("0xb"));
        snap.workspaces.retain(|w| w.id != WorkspaceId(2));
        snap.toplevels[0].title = "New".into();
        let changes = s.reset(snap);
        assert_eq!(changes.len(), 3, "{changes:?}");
        assert_eq!(changes[0], WmChange::ToplevelRemoved(id("0xb")));
        assert!(matches!(&changes[1], WmChange::ToplevelChanged(t) if t.title == "New"));
        assert_eq!(changes[2], WmChange::WorkspaceRemoved(WorkspaceId(2)));
    }

    #[test]
    fn open_move_close() {
        let mut s = state();
        let open = WmEvent::OpenWindow {
            id: id("0xc"),
            workspace: "1".into(),
            class: "vlc".into(),
            title: "VLC, the player >> x".into(),
        };
        let c = s.apply(&open);
        assert!(matches!(&c[0], WmChange::ToplevelAdded(t) if t.app_id == "vlc"));
        assert!(matches!(&c[1], WmChange::WorkspaceChanged(w) if w.windows == 2));
        assert!(s.apply(&open).is_empty(), "duplicate open is ignored");

        let mv = WmEvent::MoveWindowV2 {
            id: id("0xc"),
            workspace: WorkspaceId(2),
            name: "2".into(),
        };
        let c = s.apply(&mv);
        assert_eq!(c.len(), 3, "{c:?}");
        assert!(s.apply(&mv).is_empty());
        assert!(
            s.apply(&WmEvent::MoveWindow {
                id: id("0xc"),
                workspace: "2".into()
            })
            .is_empty()
        );

        let c = s.apply(&WmEvent::CloseWindow { id: id("0xc") });
        assert_eq!(c[0], WmChange::ToplevelRemoved(id("0xc")));
        assert!(matches!(&c[1], WmChange::WorkspaceChanged(w) if w.windows == 1));
        assert!(s.apply(&WmEvent::CloseWindow { id: id("0xc") }).is_empty());
        assert!(!s.take_resync());
    }

    #[test]
    fn focus_moves_and_clears_urgency() {
        let mut s = state();
        let c = s.apply(&WmEvent::Urgent { id: id("0xb") });
        assert!(matches!(&c[0], WmChange::ToplevelChanged(t) if t.urgent));
        let c = s.apply(&WmEvent::ActiveWindowV2 {
            id: Some(id("0xb")),
        });
        assert_eq!(c.len(), 3);
        assert!(matches!(&c[0], WmChange::ToplevelChanged(t) if t.id == id("0xa") && !t.focused));
        assert!(matches!(&c[1], WmChange::ToplevelChanged(t) if t.focused && !t.urgent));
        assert_eq!(c[2], WmChange::FocusChanged(Some(id("0xb"))));
        assert!(
            s.apply(&WmEvent::ActiveWindowV2 {
                id: Some(id("0xb"))
            })
            .is_empty()
        );
        // Closing the focused window clears focus.
        let c = s.apply(&WmEvent::CloseWindow { id: id("0xb") });
        assert_eq!(c.last(), Some(&WmChange::FocusChanged(None)));
        assert!(s.apply(&WmEvent::ActiveWindowV2 { id: None }).is_empty());
    }

    #[test]
    fn workspace_lifecycle() {
        let mut s = state();
        let c = s.apply(&WmEvent::CreateWorkspaceV2 {
            id: WorkspaceId(5),
            name: "5".into(),
        });
        assert!(
            matches!(&c[0], WmChange::WorkspaceAdded(w) if w.id == WorkspaceId(5) && w.monitor == "eDP-1")
        );
        assert!(
            s.apply(&WmEvent::CreateWorkspace { name: "5".into() })
                .is_empty()
        );
        assert_eq!(s.workspaces()[2].id, WorkspaceId(5));

        let c = s.apply(&WmEvent::WorkspaceV2 {
            id: WorkspaceId(5),
            name: "5".into(),
        });
        assert_eq!(
            c,
            vec![WmChange::ActiveWorkspaceChanged(Some(WorkspaceId(5)))]
        );
        assert!(s.apply(&WmEvent::Workspace { name: "5".into() }).is_empty());
        assert_eq!(s.monitors()[0].active_workspace, WorkspaceId(5));

        let c = s.apply(&WmEvent::RenameWorkspace {
            id: WorkspaceId(5),
            name: "music".into(),
        });
        assert!(matches!(&c[0], WmChange::WorkspaceChanged(w) if w.name == "music"));

        let c = s.apply(&WmEvent::DestroyWorkspaceV2 {
            id: WorkspaceId(5),
            name: "music".into(),
        });
        assert_eq!(c, vec![WmChange::WorkspaceRemoved(WorkspaceId(5))]);
        assert!(
            s.apply(&WmEvent::DestroyWorkspace {
                name: "music".into()
            })
            .is_empty()
        );
        assert!(!s.take_resync());
    }

    #[test]
    fn named_workspace_create_waits_for_v2() {
        let mut s = state();
        assert!(
            s.apply(&WmEvent::CreateWorkspace {
                name: "special:magic".into()
            })
            .is_empty()
        );
        let c = s.apply(&WmEvent::CreateWorkspaceV2 {
            id: WorkspaceId(-98),
            name: "special:magic".into(),
        });
        assert_eq!(c.len(), 1);
        assert_eq!(s.workspaces()[0].id, WorkspaceId(-98));
    }

    #[test]
    fn window_properties() {
        let mut s = state();
        let c = s.apply(&WmEvent::WindowTitleV2 {
            id: id("0xa"),
            title: "Docs — Firefox".into(),
        });
        assert!(matches!(&c[0], WmChange::ToplevelChanged(t) if t.title == "Docs — Firefox"));
        let c = s.apply(&WmEvent::Fullscreen { on: true });
        assert!(matches!(&c[0], WmChange::ToplevelChanged(t) if t.fullscreen));
        let c = s.apply(&WmEvent::ChangeFloatingMode {
            id: id("0xa"),
            floating: false,
        });
        assert!(matches!(&c[0], WmChange::ToplevelChanged(t) if !t.floating));
        assert!(s.apply(&WmEvent::WindowTitle { id: id("0xa") }).is_empty());
        // Unknown window: ignored, no panic.
        assert!(
            s.apply(&WmEvent::WindowTitleV2 {
                id: id("0xdead"),
                title: "x".into()
            })
            .is_empty()
        );
    }

    #[test]
    fn unresolvable_events_request_resync() {
        let mut s = state();
        assert!(
            s.apply(&WmEvent::OpenWindow {
                id: id("0xd"),
                workspace: "nowhere".into(),
                class: "x".into(),
                title: "x".into(),
            })
            .is_empty()
        );
        assert!(s.take_resync());
        assert!(!s.take_resync());
        s.apply(&WmEvent::ConfigReloaded);
        assert!(s.take_resync());
        s.apply(&WmEvent::Reconnected);
        assert!(s.take_resync());
        s.apply(&WmEvent::MonitorAdded {
            name: "HDMI-A-1".into(),
        });
        assert!(s.take_resync());
        assert!(
            s.apply(&WmEvent::Unknown {
                name: "bell".into(),
                data: String::new()
            })
            .is_empty()
        );
        assert!(!s.take_resync());
    }

    #[test]
    fn focused_monitor_switch() {
        let mut s = state();
        let mut snap = s.snapshot();
        let mut m2 = monitor();
        m2.id = 1;
        m2.name = "DP-1".into();
        m2.focused = false;
        m2.active_workspace = WorkspaceId(2);
        snap.monitors.push(m2);
        s.reset(snap);
        let c = s.apply(&WmEvent::FocusedMon {
            monitor: "DP-1".into(),
            workspace: "2".into(),
        });
        assert_eq!(
            c,
            vec![WmChange::ActiveWorkspaceChanged(Some(WorkspaceId(2)))]
        );
        assert!(s.monitors()[1].focused && !s.monitors()[0].focused);
        assert!(
            s.apply(&WmEvent::FocusedMonV2 {
                monitor: "DP-1".into(),
                workspace: WorkspaceId(2)
            })
            .is_empty()
        );
        assert!(!s.take_resync());
    }
}
