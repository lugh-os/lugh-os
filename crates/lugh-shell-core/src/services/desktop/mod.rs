//! Shared core of the `wm`, `apps` and `launcher` services.
//!
//! The three services are views of one [`Hub`]: the window-manager state
//! ([`WmState`]), the app index and launch history (inside
//! [`Launcher`]) and what was last published to the UI. One mutex guards it
//! all; nothing slow happens under it (socket round trips and process
//! spawning run outside, on the runtime's blocking pool).
//!
//! Threads: one event thread for the whole core ([`run_loop`]). It blocks on
//! the compositor's event stream, so an idle desktop causes no wakeups. It
//! only uses timeouts while something is pending: a geometry refresh
//! (150 ms debounce) or a coalesced title update (≤ 10 patches/s).
//!
//! Publishing is by comparison: every `sync_*` rebuilds a small typed view,
//! compares it with what the UI already has and patches only the keys that
//! differ, so a patch never carries an unchanged array.

pub(crate) mod model;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock, Weak};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::super::{CallError, Context, Sink};
use crate::config::DesktopConfig;
use crate::launch::{
    AppLauncher, LaunchError, LaunchRequest, ScopeManager, SystemdScopes, exec_to_argv,
    find_program,
};
use crate::launcher::{Launcher, Provider, Query, ResultKind, SearchResult, fold, groups};
use crate::wm::hyprland::HyprlandAdapter;
use crate::wm::{
    CompositorAdapter, Toplevel, WindowId, WmChange, WmError, WmEvent, WmSnapshot, WmState,
};
use model::{
    AppWindows, DEFAULT_ICON, DockItem, InstalledRow, MINIMIZED_WORKSPACE, RecentRow, TopRow, WsRow,
};

/// Geometry is re-read this long after the last event that may have moved
/// or resized a window.
const GEOMETRY_DEBOUNCE: Duration = Duration::from_millis(150);
/// Minimum spacing of patches caused only by title changes.
const TITLE_INTERVAL: Duration = Duration::from_millis(100);
/// How long a dock item stays `launching` without a window appearing.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(10);
const BACKOFF_START: Duration = Duration::from_millis(100);
const BACKOFF_MAX: Duration = Duration::from_secs(5);
/// Launcher results per query.
const RESULT_LIMIT: usize = 50;
/// Apps in `launcher.recent`.
const RECENT_APPS: usize = 5;

/// What the desktop services run on. [`DesktopParts::from_env`] is the
/// session's; tests pass a fake compositor, a temporary app index and
/// [`crate::launch::NoScopes`].
#[derive(Debug)]
pub struct DesktopParts {
    /// The compositor, or `None` when the session has none we can talk to
    /// (`wm.available` stays `false`, nothing retries).
    pub adapter: Option<Arc<dyn CompositorAdapter>>,
    /// App index, history, aliases and providers. The open-windows provider
    /// is added by the hub.
    pub launcher: Launcher,
    /// Where started apps get their systemd scope.
    pub scopes: Arc<dyn ScopeManager>,
}

impl DesktopParts {
    /// Hyprland when `HYPRLAND_INSTANCE_SIGNATURE` names a live instance,
    /// the installed apps, the user's history, scopes on the user's systemd.
    #[must_use]
    pub fn from_env() -> Self {
        let adapter = match HyprlandAdapter::from_env() {
            Ok(a) => Some(Arc::new(a) as Arc<dyn CompositorAdapter>),
            Err(e) => {
                tracing::info!(%e, "no Hyprland in this session; window management is off");
                None
            }
        };
        Self {
            adapter,
            launcher: Launcher::from_env(),
            scopes: Arc::new(SystemdScopes::new()),
        }
    }
}

/// A window as the launcher's "Open windows" group sees it.
#[derive(Debug, Clone)]
struct WindowEntry {
    win_id: String,
    title: String,
    icon: String,
    /// Folded title and app name, for matching.
    hay: String,
}

/// Launcher provider over the open windows ("Switch to window").
#[derive(Debug)]
struct WindowsProvider {
    feed: Arc<Mutex<Vec<WindowEntry>>>,
}

impl Provider for WindowsProvider {
    fn search(&self, q: &Query) -> Vec<SearchResult> {
        if q.folded.chars().count() < 2 {
            return Vec::new();
        }
        let feed = lock(&self.feed);
        feed.iter()
            .filter(|w| w.hay.contains(q.folded.as_str()))
            .take(q.limit)
            .enumerate()
            .map(|(i, w)| SearchResult {
                kind: ResultKind::Window,
                group: groups::WINDOWS.into(),
                title: w.title.clone(),
                subtitle: "Switch to window".into(),
                icon: w.icon.clone(),
                target: w.win_id.clone(),
                score: -i64::try_from(i).unwrap_or(i64::MAX),
            })
            .collect()
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Everything behind the hub's mutex.
#[derive(Debug)]
struct State {
    wm: WmState,
    /// A snapshot has been applied and the event socket is up.
    available: bool,
    launcher: Launcher,
    /// Window class → desktop id (or the class itself when nothing matches).
    resolved: HashMap<String, String>,
    /// Windows, most recently focused first.
    focus_order: Vec<WindowId>,
    /// Apps being started: (app id, token of the start).
    launching: Vec<(String, u64)>,
    next_token: u64,
    feed: Arc<Mutex<Vec<WindowEntry>>>,

    // What the UI has.
    v_available: bool,
    v_workspaces: Vec<WsRow>,
    v_active: i64,
    v_focus: [String; 3],
    v_toplevels: Vec<TopRow>,
    v_overlap: bool,
    v_output: String,
    v_installed: Vec<InstalledRow>,
    v_dock: Vec<DockItem>,
    v_recent: Vec<RecentRow>,
    query: String,
    results: Vec<SearchResult>,
}

fn rows<T: serde::Serialize>(v: &[T]) -> Value {
    serde_json::to_value(v).unwrap_or_else(|_| Value::Array(Vec::new()))
}

impl State {
    fn new(mut launcher: Launcher) -> Self {
        let feed = Arc::new(Mutex::new(Vec::new()));
        launcher.add_provider(Box::new(WindowsProvider {
            feed: Arc::clone(&feed),
        }));
        Self {
            wm: WmState::new(),
            available: false,
            launcher,
            resolved: HashMap::new(),
            focus_order: Vec::new(),
            launching: Vec::new(),
            next_token: 0,
            feed,
            v_available: false,
            v_workspaces: Vec::new(),
            v_active: 1,
            v_focus: Default::default(),
            v_toplevels: Vec::new(),
            v_overlap: false,
            v_output: String::new(),
            v_installed: Vec::new(),
            v_dock: Vec::new(),
            v_recent: Vec::new(),
            query: String::new(),
            results: Vec::new(),
        }
    }

    /// Desktop id for a window class, cached until the index changes.
    fn resolve(&mut self, class: &str) -> String {
        if let Some(id) = self.resolved.get(class) {
            return id.clone();
        }
        let id = model::match_app(self.launcher.index().entries(), class)
            .unwrap_or(class)
            .to_owned();
        self.resolved.insert(class.to_owned(), id.clone());
        id
    }

    fn app_info(&self, id: &str) -> Option<(String, String)> {
        self.launcher.index().get(id).map(|e| {
            (
                e.name.clone(),
                e.icon.clone().unwrap_or_else(|| DEFAULT_ICON.to_owned()),
            )
        })
    }

    /// Follows model changes that the views do not capture: focus history
    /// and "a window of the app being started appeared".
    fn note(&mut self, changes: &[WmChange]) {
        for c in changes {
            match c {
                WmChange::FocusChanged(Some(id)) => {
                    self.focus_order.retain(|w| w != id);
                    self.focus_order.insert(0, id.clone());
                }
                WmChange::ToplevelRemoved(id) => self.focus_order.retain(|w| w != id),
                WmChange::ToplevelAdded(t) if !self.launching.is_empty() => {
                    let app = self.resolve(&t.app_id);
                    self.launching.retain(|(id, _)| *id != app);
                }
                _ => {}
            }
        }
    }

    /// `wm` service state from the published views.
    fn wm_state(&self) -> Value {
        json!({
            "available": self.v_available,
            "workspaces": rows(&self.v_workspaces),
            "activeWorkspace": self.v_active,
            "focusedAppId": self.v_focus[0],
            "focusedAppName": self.v_focus[1],
            "focusedTitle": self.v_focus[2],
            "toplevels": rows(&self.v_toplevels),
            "dockOverlapped": self.v_overlap,
            "activeOutput": self.v_output,
        })
    }

    fn apps_state(&self) -> Value {
        json!({ "installed": rows(&self.v_installed), "dock": rows(&self.v_dock) })
    }

    fn launcher_state(&self) -> Value {
        json!({
            "query": self.query,
            "searching": false,
            "results": self.results.iter().map(model::result_row).collect::<Vec<_>>(),
            "recent": rows(&self.v_recent),
        })
    }

    /// Rebuilds the `wm` views and patches what differs, then refreshes the
    /// dock. (Title storms are held back by the caller.)
    fn sync_wm(&mut self, sink: &Sink, pinned: &[String]) {
        let mut patch = Map::new();
        if self.v_available != self.available {
            self.v_available = self.available;
            patch.insert("available".into(), self.available.into());
        }
        let workspaces = model::workspace_rows(self.wm.workspaces());
        if workspaces != self.v_workspaces {
            patch.insert("workspaces".into(), rows(&workspaces));
            self.v_workspaces = workspaces;
        }
        // While a special workspace is shown, keep the last regular one.
        if let Some(active) = self.wm.active_workspace().filter(|w| w.0 > 0)
            && active.0 != self.v_active
        {
            self.v_active = active.0;
            patch.insert("activeWorkspace".into(), active.0.into());
        }

        let wins: Vec<Toplevel> = self.wm.toplevels().to_vec();
        let mut toplevels = Vec::with_capacity(wins.len());
        let mut feed = Vec::with_capacity(wins.len());
        let mut focus: [String; 3] = Default::default();
        for t in &wins {
            let app_id = self.resolve(&t.app_id);
            let info = self.app_info(&app_id);
            let name = info
                .as_ref()
                .map_or_else(|| app_id.clone(), |i| i.0.clone());
            if t.focused {
                focus = [app_id.clone(), name.clone(), t.title.clone()];
            }
            feed.push(WindowEntry {
                win_id: t.id.as_str().to_owned(),
                title: if t.title.is_empty() {
                    name.clone()
                } else {
                    t.title.clone()
                },
                icon: info.map_or_else(|| DEFAULT_ICON.to_owned(), |i| i.1),
                hay: fold(&format!("{} {name}", t.title)),
            });
            let at = model::toplevel_geometry(t, self.wm.workspaces(), self.wm.monitors());
            toplevels.push(TopRow {
                win_id: t.id.as_str().to_owned(),
                app_id,
                title: t.title.clone(),
                workspace: t.workspace.0,
                focused: t.focused,
                x: at.x,
                y: at.y,
                width: at.width,
                height: at.height,
                monitor_width: at.monitor_width,
                monitor_height: at.monitor_height,
                monitor: at.monitor,
            });
        }
        if focus != self.v_focus {
            for (i, key) in ["focusedAppId", "focusedAppName", "focusedTitle"]
                .into_iter()
                .enumerate()
            {
                if focus[i] != self.v_focus[i] {
                    patch.insert(key.into(), focus[i].clone().into());
                }
            }
            self.v_focus = focus;
        }
        if toplevels != self.v_toplevels {
            patch.insert("toplevels".into(), rows(&toplevels));
            self.v_toplevels = toplevels;
            *lock(&self.feed) = feed;
        }
        let overlap = model::dock_overlapped(&wins, self.wm.monitors(), self.wm.active_workspace());
        if overlap != self.v_overlap {
            self.v_overlap = overlap;
            patch.insert("dockOverlapped".into(), overlap.into());
        }
        if self.wm.active_output() != self.v_output {
            self.v_output = self.wm.active_output().to_owned();
            patch.insert("activeOutput".into(), self.v_output.clone().into());
        }
        if !patch.is_empty() {
            sink.patch("wm", Value::Object(patch));
        }
        self.sync_dock(sink, pinned);
    }

    fn sync_dock(&mut self, sink: &Sink, pinned: &[String]) {
        let mut running: Vec<AppWindows> = Vec::new();
        let wins: Vec<(String, bool)> = self
            .wm
            .toplevels()
            .iter()
            .map(|t| (t.app_id.clone(), t.urgent))
            .collect();
        for (class, urgent) in wins {
            let app_id = self.resolve(&class);
            match running.iter_mut().find(|r| r.app_id == app_id) {
                Some(r) => {
                    r.windows += 1;
                    r.urgent |= urgent;
                }
                None => running.push(AppWindows {
                    app_id,
                    windows: 1,
                    urgent,
                }),
            }
        }
        let launching: Vec<&str> = self.launching.iter().map(|(id, _)| id.as_str()).collect();
        let dock = model::build_dock(pinned, &running, &launching, |id| self.app_info(id));
        if dock != self.v_dock {
            sink.patch("apps", json!({ "dock": rows(&dock) }));
            self.v_dock = dock;
        }
    }

    fn sync_installed(&mut self, sink: &Sink) {
        let mut installed: Vec<InstalledRow> = self
            .launcher
            .index()
            .entries()
            .iter()
            .map(|e| InstalledRow {
                app_id: e.id.clone(),
                name: e.name.clone(),
                generic_name: e.generic_name.clone().unwrap_or_default(),
                icon: e.icon.clone().unwrap_or_else(|| DEFAULT_ICON.to_owned()),
                keywords: e.keywords.join(" "),
            })
            .collect();
        installed.sort_by_cached_key(|r| (r.name.to_lowercase(), r.app_id.clone()));
        if installed != self.v_installed {
            sink.patch("apps", json!({ "installed": rows(&installed) }));
            self.v_installed = installed;
        }
    }

    fn sync_recent(&mut self, sink: &Sink) {
        let recent: Vec<RecentRow> = self
            .launcher
            .recent(RECENT_APPS)
            .into_iter()
            .map(|r| RecentRow {
                app_id: r.app_id,
                name: r.name,
                icon: r.icon,
            })
            .collect();
        if recent != self.v_recent {
            sink.patch("launcher", json!({ "recent": rows(&recent) }));
            self.v_recent = recent;
        }
    }

    fn record_launch(&mut self, sink: &Sink, app_id: &str) {
        if let Err(e) = self.launcher.record_launch(app_id) {
            tracing::debug!(%e, "launch history not saved");
        }
        self.sync_recent(sink);
    }

    /// The app's windows, most recently focused first (never-focused ones
    /// last, in mapping order).
    fn windows_of(&mut self, app_id: &str) -> Vec<WindowId> {
        let wins: Vec<(WindowId, String)> = self
            .wm
            .toplevels()
            .iter()
            .map(|t| (t.id.clone(), t.app_id.clone()))
            .collect();
        let mut mine: Vec<WindowId> = Vec::new();
        for (id, class) in wins {
            if self.resolve(&class) == app_id {
                mine.push(id);
            }
        }
        let rank = |id: &WindowId| {
            self.focus_order
                .iter()
                .position(|w| w == id)
                .unwrap_or(usize::MAX)
        };
        mine.sort_by_key(rank);
        mine
    }
}

/// State and handles shared by the services, the event thread and the
/// background jobs.
#[derive(Debug)]
pub(crate) struct Inner {
    pub(crate) sink: Sink,
    ctx: Context,
    adapter: Option<Arc<dyn CompositorAdapter>>,
    apps: AppLauncher<Arc<dyn ScopeManager>>,
    st: Mutex<State>,
    stop: AtomicBool,
    /// Wakes the event thread out of its blocking wait (set while a stream
    /// is open).
    waker: Mutex<Option<Sender<WmEvent>>>,
}

/// The shared core. Dropping the last reference stops the event thread.
#[derive(Debug)]
pub(crate) struct Hub {
    pub(crate) inner: Arc<Inner>,
    stop_tx: Sender<()>,
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.inner.stop.store(true, Ordering::SeqCst);
        let _ = self.stop_tx.send(());
        if let Some(tx) = lock(&self.inner.waker).as_ref() {
            let _ = tx.send(WmEvent::Unknown {
                name: "lugh-stop".into(),
                data: String::new(),
            });
        }
    }
}

type Registry = Mutex<Vec<(Weak<RwLock<DesktopConfig>>, Weak<Hub>)>>;

/// Hubs by the core they belong to (a core is identified by its shared
/// config), so `wm::start`, `apps::start` and `launcher::start` of one
/// `ShellCore` get the same hub without the caller threading it through.
static HUBS: Registry = Mutex::new(Vec::new());

impl Hub {
    /// The hub of `ctx`'s core, created from the environment on first use.
    pub(crate) fn for_context(ctx: &Context) -> Arc<Self> {
        let mut hubs = lock(&HUBS);
        hubs.retain(|(cfg, hub)| cfg.strong_count() > 0 && hub.strong_count() > 0);
        let found = hubs.iter().find_map(|(cfg, hub)| {
            let cfg = cfg.upgrade()?;
            Arc::ptr_eq(&cfg, &ctx.config)
                .then(|| hub.upgrade())
                .flatten()
        });
        if let Some(hub) = found {
            return hub;
        }
        let hub = Self::start(ctx, DesktopParts::from_env());
        hubs.push((Arc::downgrade(&ctx.config), Arc::downgrade(&hub)));
        hub
    }

    /// A hub over explicit parts.
    pub(crate) fn start(ctx: &Context, parts: DesktopParts) -> Arc<Self> {
        let DesktopParts {
            adapter,
            launcher,
            scopes,
        } = parts;
        let inner = Arc::new(Inner {
            sink: ctx.sink.clone(),
            ctx: ctx.clone(),
            adapter: adapter.clone(),
            apps: AppLauncher::with_scopes(scopes),
            st: Mutex::new(State::new(launcher)),
            stop: AtomicBool::new(false),
            waker: Mutex::new(None),
        });
        {
            // First views; nobody listens yet, so the patches are dropped.
            let quiet = Sink::new(|_| {});
            let pinned = inner.pinned();
            let mut st = inner.state();
            st.sync_installed(&quiet);
            st.sync_recent(&quiet);
            st.sync_dock(&quiet, &pinned);
        }
        let (stop_tx, stop_rx) = mpsc::channel();
        if let Some(adapter) = adapter {
            let weak = Arc::downgrade(&inner);
            let spawned = std::thread::Builder::new()
                .name("lugh-wm".into())
                .spawn(move || run_loop(&weak, adapter.as_ref(), &stop_rx));
            if let Err(e) = spawned {
                tracing::error!(%e, "cannot start the window-manager thread");
            }
        }
        Arc::new(Self { inner, stop_tx })
    }
}

impl Inner {
    fn state(&self) -> MutexGuard<'_, State> {
        lock(&self.st)
    }

    fn pinned(&self) -> Vec<String> {
        match self.ctx.config.read() {
            Ok(c) => c.dock.pinned.clone(),
            Err(p) => p.into_inner().dock.pinned.clone(),
        }
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    // ---- snapshots of service state -------------------------------------

    pub(crate) fn wm_state(&self) -> Value {
        self.state().wm_state()
    }

    pub(crate) fn apps_state(&self) -> Value {
        self.state().apps_state()
    }

    pub(crate) fn launcher_state(&self) -> Value {
        self.state().launcher_state()
    }

    // ---- wm calls --------------------------------------------------------

    fn adapter(&self) -> Result<Arc<dyn CompositorAdapter>, CallError> {
        self.adapter
            .clone()
            .ok_or_else(|| CallError::Failed("no compositor in this session".into()))
    }

    /// Runs a compositor request off the caller's thread; failures are logged.
    fn compositor_job(
        self: &Arc<Self>,
        what: &'static str,
        job: impl FnOnce(&dyn CompositorAdapter) -> Result<(), WmError> + Send + 'static,
    ) -> Result<(), CallError> {
        let adapter = self.adapter()?;
        self.ctx.runtime.spawn_blocking(move || {
            if let Err(e) = job(adapter.as_ref()) {
                tracing::warn!(%e, what, "compositor request failed");
            }
        });
        Ok(())
    }

    pub(crate) fn switch_workspace(self: &Arc<Self>, ws: i64) -> Result<(), CallError> {
        if !(1..=model::MAX_WORKSPACES).contains(&ws) {
            return Err(CallError::BadArgs(format!("no workspace {ws}")));
        }
        self.compositor_job("switch workspace", move |a| {
            a.switch_workspace(crate::wm::WorkspaceId(ws))
        })
    }

    /// Focuses a window. One sitting on `special:minimized` is moved back to
    /// the active workspace first.
    pub(crate) fn activate_window(self: &Arc<Self>, win: &str) -> Result<(), CallError> {
        let id = WindowId::new(win);
        let restore_to = {
            let st = self.state();
            let t = st
                .wm
                .toplevel(&id)
                .ok_or_else(|| CallError::Failed(format!("no window {win}")))?;
            let minimized = st
                .wm
                .workspace(t.workspace)
                .is_some_and(|w| w.name == MINIMIZED_WORKSPACE);
            minimized.then(|| crate::wm::WorkspaceId(st.v_active))
        };
        self.compositor_job("activate window", move |a| {
            if let Some(ws) = restore_to {
                a.move_to_workspace(&id, ws)?;
            }
            a.activate(&id)
        })
    }

    /// Moves a window to a regular workspace without following it (the
    /// overview's drag and drop).
    pub(crate) fn move_window_to_workspace(
        self: &Arc<Self>,
        win: &str,
        ws: i64,
    ) -> Result<(), CallError> {
        if !(1..=model::MAX_WORKSPACES).contains(&ws) {
            return Err(CallError::BadArgs(format!("no workspace {ws}")));
        }
        let id = WindowId::new(win);
        if self.state().wm.toplevel(&id).is_none() {
            return Err(CallError::Failed(format!("no window {win}")));
        }
        self.compositor_job("move window to workspace", move |a| {
            a.move_to_workspace(&id, crate::wm::WorkspaceId(ws))
        })
    }

    pub(crate) fn close_window(self: &Arc<Self>, win: &str) -> Result<(), CallError> {
        let id = WindowId::new(win);
        self.compositor_job("close window", move |a| a.close(&id))
    }

    // ---- apps calls ------------------------------------------------------

    /// Focuses the app's most recently used window (cycling when the app
    /// already has the focus), or starts it. Returns whether it was started.
    pub(crate) fn activate_app(self: &Arc<Self>, app_id: &str) -> Result<bool, CallError> {
        let target = {
            let mut st = self.state();
            let windows = st.windows_of(app_id);
            model::pick_window(&windows, st.wm.focused()).cloned()
        };
        match target {
            Some(win) => self.activate_window(win.as_str()).map(|()| false),
            None => self.launch_app(app_id).map(|()| true),
        }
    }

    /// Starts a new instance in its own scope. The dock item is `launching`
    /// until a window of the app appears, the start fails, or 10 s pass.
    pub(crate) fn launch_app(self: &Arc<Self>, app_id: &str) -> Result<(), CallError> {
        let pinned = self.pinned();
        let (request, name, token) = {
            let mut st = self.state();
            let Some(entry) = st.launcher.index().get(app_id).cloned() else {
                drop(st);
                let message = format!("{app_id} isn't installed");
                self.launch_failed(app_id, &message);
                return Err(CallError::Failed(message));
            };
            let argv = match entry.exec.as_deref() {
                Some(exec) => exec_to_argv(
                    exec,
                    &[],
                    &[],
                    entry.icon.as_deref(),
                    &entry.name,
                    Some(&entry.path),
                ),
                None => Err(LaunchError::EmptyCommand),
            };
            let argv = match argv {
                Ok(argv) => argv,
                Err(e) => {
                    drop(st);
                    let message = model::launch_failure_message(&entry.name, &e);
                    self.launch_failed(app_id, &message);
                    return Err(CallError::Failed(e.to_string()));
                }
            };
            let request = LaunchRequest {
                app_id: entry.id.clone(),
                exec: argv,
                terminal: entry.terminal,
                working_dir: entry.working_dir.as_deref().map(PathBuf::from),
                env: Vec::new(),
                description: Some(entry.name.clone()),
            };
            st.next_token += 1;
            let token = st.next_token;
            st.launching.push((entry.id.clone(), token));
            st.sync_dock(&self.sink, &pinned);
            st.record_launch(&self.sink, &entry.id);
            (request, entry.name, token)
        };

        let me = Arc::clone(self);
        self.ctx.runtime.spawn_blocking(move || {
            if let Err(e) = me.apps.launch(&request) {
                tracing::warn!(%e, app = %request.app_id, "app did not start");
                me.end_launching(token);
                me.launch_failed(&request.app_id, &model::launch_failure_message(&name, &e));
            }
        });
        let weak = Arc::downgrade(self);
        self.ctx.runtime.spawn(async move {
            tokio::time::sleep(LAUNCH_TIMEOUT).await;
            if let Some(me) = weak.upgrade() {
                me.end_launching(token);
            }
        });
        Ok(())
    }

    fn end_launching(&self, token: u64) {
        let pinned = self.pinned();
        let mut st = self.state();
        let before = st.launching.len();
        st.launching.retain(|(_, t)| *t != token);
        if st.launching.len() != before {
            st.sync_dock(&self.sink, &pinned);
        }
    }

    fn launch_failed(&self, app_id: &str, message: &str) {
        self.sink
            .signal("apps", "launchFailed", vec![app_id.into(), message.into()]);
    }

    /// Closes every window of the app.
    pub(crate) fn quit_app(self: &Arc<Self>, app_id: &str) -> Result<(), CallError> {
        let windows = self.state().windows_of(app_id);
        if windows.is_empty() {
            return Ok(());
        }
        self.compositor_job("quit app", move |a| {
            let mut result = Ok(());
            for w in &windows {
                if let Err(e) = a.close(w) {
                    result = Err(e);
                }
            }
            result
        })
    }

    /// Pins or unpins an app and saves `desktop.toml`.
    pub(crate) fn set_pinned(&self, app_id: &str, pinned: bool) {
        let mut changed = false;
        let config = self.ctx.update_config(|c| {
            changed = if pinned {
                model::pin(&mut c.dock.pinned, app_id)
            } else {
                model::unpin(&mut c.dock.pinned, app_id)
            };
        });
        if changed {
            self.state().sync_dock(&self.sink, &config.dock.pinned);
        }
    }

    /// Re-reads the app directories if their mtimes changed.
    pub(crate) fn rescan(self: &Arc<Self>) {
        let me = Arc::clone(self);
        self.ctx.runtime.spawn_blocking(move || {
            let pinned = me.pinned();
            let mut st = me.state();
            if !st.launcher.rescan() {
                return;
            }
            st.resolved.clear();
            st.sync_installed(&me.sink);
            st.sync_wm(&me.sink, &pinned);
            st.sync_recent(&me.sink);
        });
    }

    // ---- launcher calls --------------------------------------------------

    /// Searches inside the call (well under a millisecond) and answers with
    /// one patch carrying the query it belongs to.
    pub(crate) fn search(&self, text: &str) {
        let mut st = self.state();
        let results = st.launcher.search(text, RESULT_LIMIT);
        let rows: Vec<Value> = results.iter().map(model::result_row).collect();
        st.query = text.to_owned();
        st.results = results;
        drop(st);
        self.sink.patch(
            "launcher",
            json!({ "query": text, "results": rows, "searching": false }),
        );
    }

    pub(crate) fn activate_result(
        self: &Arc<Self>,
        index: i64,
        secondary: bool,
    ) -> Result<(), CallError> {
        let result = usize::try_from(index)
            .ok()
            .and_then(|i| self.state().results.get(i).cloned())
            .ok_or_else(|| CallError::BadArgs(format!("no result {index}")))?;
        let target = result.target;
        match (result.kind, secondary) {
            (ResultKind::App, false) => {
                if !self.activate_app(&target)? {
                    // Focused an open window: still a use of the app.
                    self.state().record_launch(&self.sink, &target);
                }
                Ok(())
            }
            (ResultKind::App, true) => self.launch_app(&target),
            (ResultKind::Window, _) => self.activate_window(&target),
            (ResultKind::Calc, _) => {
                self.run_tool(
                    "wl-copy",
                    vec!["wl-copy".into(), "--".into(), target],
                    false,
                );
                Ok(())
            }
            (ResultKind::Setting, _) => {
                self.run_tool("lugh-settings", vec!["lugh-settings".into(), target], false);
                Ok(())
            }
            (ResultKind::File, false) => {
                self.run_tool("xdg-open", vec!["xdg-open".into(), target], false);
                Ok(())
            }
            (ResultKind::File, true) => {
                let folder = std::path::Path::new(&target)
                    .parent()
                    .map_or_else(|| "/".to_owned(), |p| p.to_string_lossy().into_owned());
                self.run_tool("xdg-open", vec!["xdg-open".into(), folder], false);
                Ok(())
            }
            (ResultKind::Command, _) => {
                // Keep the terminal open on the user's shell afterwards.
                let script = format!("{target}; exec \"${{SHELL:-sh}}\"");
                self.run_tool("sh", vec!["sh".into(), "-c".into(), script], true);
                Ok(())
            }
        }
    }

    /// Starts a helper program in its own scope, if it is installed.
    pub(crate) fn run_tool(
        self: &Arc<Self>,
        program: &'static str,
        argv: Vec<String>,
        terminal: bool,
    ) {
        let me = Arc::clone(self);
        self.ctx.runtime.spawn_blocking(move || {
            if find_program(program).is_none() {
                tracing::info!(program, "not installed; nothing to do");
                return;
            }
            let mut request = LaunchRequest::new(program, argv);
            request.terminal = terminal;
            if let Err(e) = me.apps.launch(&request) {
                tracing::warn!(%e, program, "helper did not start");
            }
        });
    }
}

// ---- event thread ---------------------------------------------------------

/// Sleeps up to `d`; `true` when the hub was dropped meanwhile.
fn stop_within(stop_rx: &Receiver<()>, d: Duration) -> bool {
    !matches!(stop_rx.recv_timeout(d), Err(RecvTimeoutError::Timeout))
}

fn apply_snapshot(inner: &Inner, snapshot: WmSnapshot) {
    let pinned = inner.pinned();
    let mut st = inner.state();
    let changes = st.wm.reset(snapshot);
    st.note(&changes);
    st.available = true;
    st.sync_wm(&inner.sink, &pinned);
}

fn set_unavailable(inner: &Inner) {
    let mut st = inner.state();
    st.available = false;
    if st.v_available {
        st.v_available = false;
        inner.sink.patch("wm", json!({ "available": false }));
    }
}

/// Whether the event may have changed a window's geometry (events never
/// carry it, so it is re-read from a snapshot a moment later).
fn moves_windows(ev: &WmEvent) -> bool {
    matches!(
        ev,
        WmEvent::OpenWindow { .. }
            | WmEvent::MoveWindow { .. }
            | WmEvent::MoveWindowV2 { .. }
            | WmEvent::ChangeFloatingMode { .. }
            | WmEvent::ActiveWindowV2 { .. }
            | WmEvent::Fullscreen { .. }
    )
}

/// The bridge loop: subscribe → snapshot → apply events, resynchronising
/// when asked, reconnecting with backoff. Ends when the hub is dropped.
fn run_loop(weak: &Weak<Inner>, adapter: &dyn CompositorAdapter, stop_rx: &Receiver<()>) {
    let mut backoff = BACKOFF_START;
    loop {
        let Some(inner) = weak.upgrade() else { return };
        if inner.stopped() {
            return;
        }
        let ready = adapter.subscribe().and_then(|stream| {
            *lock(&inner.waker) = stream.injector();
            let snapshot = adapter.snapshot()?;
            Ok((stream, snapshot))
        });
        match ready {
            Ok((stream, snapshot)) => {
                backoff = BACKOFF_START;
                apply_snapshot(&inner, snapshot);
                drop(inner);
                let ended = pump(weak, adapter, &stream);
                if let Some(inner) = weak.upgrade() {
                    *lock(&inner.waker) = None;
                    if !ended {
                        set_unavailable(&inner);
                    }
                }
                if ended {
                    return;
                }
            }
            Err(e) => {
                tracing::debug!(%e, ?backoff, "compositor not ready");
                *lock(&inner.waker) = None;
                set_unavailable(&inner);
                drop(inner);
            }
        }
        if stop_within(stop_rx, backoff) {
            return;
        }
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// Applies events until the hub is dropped (`true`) or the stream ends
/// (`false`).
fn pump(
    weak: &Weak<Inner>,
    adapter: &dyn CompositorAdapter,
    stream: &crate::wm::EventStream,
) -> bool {
    let mut geometry_at: Option<Instant> = None;
    let mut titles_at: Option<Instant> = None;
    let mut last_titles = Instant::now() - TITLE_INTERVAL;
    loop {
        // Block without a timeout unless something is pending.
        let deadline = match (geometry_at, titles_at) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let first = match deadline {
            None => match stream.next_timeout(Duration::from_secs(3600)) {
                Ok(ev) => ev,
                Err(()) => return false,
            },
            Some(at) => match stream.next_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(ev) => ev,
                Err(()) => return false,
            },
        };
        let Some(inner) = weak.upgrade() else {
            return true;
        };
        if inner.stopped() {
            return true;
        }

        let mut other = false; // something besides titles changed
        let mut titles = false;
        let mut resync = false;
        if let Some(first) = first {
            let mut st = inner.state();
            let mut next = Some(first);
            // Drain the burst: Hyprland sends several events per action.
            while let Some(ev) = next {
                if matches!(ev, WmEvent::Disconnected) {
                    st.available = false;
                    other = true;
                }
                if moves_windows(&ev) {
                    geometry_at = Some(Instant::now() + GEOMETRY_DEBOUNCE);
                }
                let changes = st.wm.apply(&ev);
                if !changes.is_empty() {
                    if matches!(ev, WmEvent::WindowTitleV2 { .. }) {
                        titles = true;
                    } else {
                        other = true;
                    }
                    st.note(&changes);
                }
                resync |= st.wm.take_resync();
                next = stream.try_next().ok().flatten();
            }
        }

        let now = Instant::now();
        if resync || geometry_at.is_some_and(|at| at <= now) {
            geometry_at = None;
            // Socket round trips: not under the lock.
            match adapter.snapshot() {
                Ok(snapshot) => {
                    apply_snapshot(&inner, snapshot);
                    other = false;
                    titles = false;
                    titles_at = None;
                    last_titles = now;
                }
                Err(e) => tracing::debug!(%e, "resnapshot failed"),
            }
        }
        if titles && !other {
            // Title storm (terminals, browsers): at most one patch per interval.
            let due = last_titles + TITLE_INTERVAL;
            if due > now {
                titles_at = Some(titles_at.map_or(due, |t| t.min(due)));
            } else {
                other = true;
            }
        }
        if titles_at.is_some_and(|at| at <= now) {
            other = true;
        }
        if other {
            titles_at = None;
            last_titles = now;
            let pinned = inner.pinned();
            inner.state().sync_wm(&inner.sink, &pinned);
        }
    }
}

/// Starts the three services over explicit parts (tests, custom front-ends).
/// The services share one hub; dropping all three stops its thread.
#[must_use]
pub fn start_desktop(ctx: &Context, parts: DesktopParts) -> Vec<Box<dyn super::super::Service>> {
    let hub = Hub::start(ctx, parts);
    vec![
        Box::new(super::WmService::new(Arc::clone(&hub))),
        Box::new(super::super::apps::AppsService::new(Arc::clone(&hub))),
        Box::new(super::super::launcher::LauncherService::new(hub)),
    ]
}
