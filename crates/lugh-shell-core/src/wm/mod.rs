//! Window-manager backend: the [`CompositorAdapter`] trait and its types.
//!
//! The shell never talks to a compositor directly. It holds a
//! `Box<dyn CompositorAdapter>` (docs/specs/shell.md §Window-manager backend
//! contract) and drives the QML models in `Services.qml` (`wm.workspaces`,
//! `wm.toplevels`, `wm.activeWorkspace`, `wm.focused*`) from it:
//!
//! 1. [`CompositorAdapter::subscribe`] first, so no event is lost,
//! 2. then [`CompositorAdapter::snapshot`] into a [`WmState`] ([`WmState::reset`]
//!    yields the initial model contents as [`WmChange`]s),
//! 3. then, for every [`WmEvent`] from the [`EventStream`],
//!    [`WmState::apply`] returns the minimal list of [`WmChange`]s to forward to
//!    the models. When [`WmState::take_resync`] says so (configuration reload,
//!    monitor hot-plug, reconnect, an event that referenced an unknown
//!    workspace), take a fresh snapshot and [`WmState::reset`] again: the diff
//!    is still minimal.
//!
//! The API is synchronous: requests are short Unix-socket round trips, and
//! events arrive on a channel fed by a reader thread. No async runtime needed.
//!
//! Phases 1–4 use [`hyprland::HyprlandAdapter`] (ADR-012). Phase 5 swaps in a
//! `lugh-shell-v1` client implementing the same trait.

pub mod hyprland;
mod state;

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError};
use std::time::Duration;

pub use state::{WmChange, WmState};

/// A window handle. For Hyprland this is the client address in its JSON
/// form, `0x` followed by lowercase hex (e.g. `0x55d4a8c3e0f0`).
///
/// This is the `winId` role of the QML `toplevels` model.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub struct WindowId(String);

impl WindowId {
    /// Wraps an id as given. Adapters validate ids before using them in
    /// requests, so any string is accepted here.
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    /// Normalises a Hyprland address: event lines carry it without the `0x`
    /// prefix (`55d4a8c3e0f0`), JSON with it. Returns `None` for an empty
    /// address or one that is not hexadecimal.
    pub fn from_hyprland(addr: &str) -> Option<Self> {
        let addr = addr.trim();
        let hex = addr
            .strip_prefix("0x")
            .or_else(|| addr.strip_prefix("0X"))
            .unwrap_or(addr);
        if hex.is_empty() || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        Some(Self(format!("0x{}", hex.to_ascii_lowercase())))
    }

    /// The id as a string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for WindowId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A workspace id. Hyprland numbers regular workspaces from 1; special
/// (scratchpad) workspaces have negative ids. This is the `wsId` role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize, Default)]
pub struct WorkspaceId(pub i64);

impl WorkspaceId {
    /// Whether this is a special (scratchpad) workspace, which the shell does
    /// not show as a workspace dot.
    pub fn is_special(self) -> bool {
        self.0 < 0
    }
}

impl fmt::Display for WorkspaceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A top-level window (`toplevels` model row).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Toplevel {
    /// Window handle (`winId`).
    pub id: WindowId,
    /// Application id: the Wayland `app_id` / X11 class (`appId`). Matches
    /// the desktop-entry id for well-behaved apps.
    pub app_id: String,
    /// Window title (`title`).
    pub title: String,
    /// Workspace the window is on (`workspace`).
    pub workspace: WorkspaceId,
    /// Floating rather than tiled.
    pub floating: bool,
    /// Fullscreen or maximised-fullscreen.
    pub fullscreen: bool,
    /// Client process id, when known. Windows reported by an `openwindow`
    /// event have `None` until the next snapshot.
    pub pid: Option<u32>,
    /// Has keyboard focus (`focused`).
    pub focused: bool,
    /// Asked for attention and has not been focused since.
    pub urgent: bool,
}

/// A workspace (`workspaces` model row).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Workspace {
    /// Workspace id (`wsId`).
    pub id: WorkspaceId,
    /// Display name (`name`); Hyprland defaults it to the id.
    pub name: String,
    /// Output (monitor connector name, e.g. `eDP-1`) it lives on; empty when
    /// unknown.
    pub monitor: String,
    /// Number of windows on it.
    pub windows: u32,
    /// Whether it has any window (`occupied`).
    pub occupied: bool,
}

/// An output.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Monitor {
    /// Compositor-specific numeric id.
    pub id: i64,
    /// Connector name (`eDP-1`, `DP-2`).
    pub name: String,
    /// Human-readable description (make, model, serial).
    pub description: String,
    /// Mode width in pixels.
    pub width: u32,
    /// Mode height in pixels.
    pub height: u32,
    /// Position in the global layout.
    pub x: i32,
    /// Position in the global layout.
    pub y: i32,
    /// Output scale.
    pub scale: f64,
    /// Workspace currently shown on it.
    pub active_workspace: WorkspaceId,
    /// Has the keyboard/cursor focus.
    pub focused: bool,
}

/// The full window-manager state at one point in time.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize)]
pub struct WmSnapshot {
    /// Workspaces, sorted by id.
    pub workspaces: Vec<Workspace>,
    /// Mapped windows, in the compositor's order.
    pub toplevels: Vec<Toplevel>,
    /// Outputs.
    pub monitors: Vec<Monitor>,
    /// Workspace on the focused monitor (`activeWorkspace`).
    pub active_workspace: Option<WorkspaceId>,
    /// Focused window, if any.
    pub focused: Option<WindowId>,
}

/// A compositor event. The variants mirror Hyprland's `.socket2.sock` events
/// (<https://wiki.hypr.land/IPC/>); `v2` variants carry ids where the legacy
/// ones carry names. Hyprland sends both forms, and [`WmState::apply`] is
/// idempotent, so applying both is harmless.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WmEvent {
    /// `workspace>>NAME`: the focused monitor switched workspace.
    Workspace {
        /// Workspace name.
        name: String,
    },
    /// `workspacev2>>ID,NAME`.
    WorkspaceV2 {
        /// Workspace id.
        id: WorkspaceId,
        /// Workspace name.
        name: String,
    },
    /// `focusedmon>>MONNAME,WORKSPACENAME`: focus moved to another monitor.
    FocusedMon {
        /// Monitor connector name.
        monitor: String,
        /// Name of the workspace shown on it.
        workspace: String,
    },
    /// `focusedmonv2>>MONNAME,WORKSPACEID`.
    FocusedMonV2 {
        /// Monitor connector name.
        monitor: String,
        /// Id of the workspace shown on it.
        workspace: WorkspaceId,
    },
    /// `activewindow>>CLASS,TITLE` (both empty when nothing is focused).
    ActiveWindow {
        /// Window class.
        class: String,
        /// Window title.
        title: String,
    },
    /// `activewindowv2>>ADDRESS` (`None` when nothing is focused).
    ActiveWindowV2 {
        /// Focused window.
        id: Option<WindowId>,
    },
    /// `openwindow>>ADDRESS,WORKSPACENAME,CLASS,TITLE`.
    OpenWindow {
        /// New window.
        id: WindowId,
        /// Name of its workspace.
        workspace: String,
        /// Window class.
        class: String,
        /// Window title.
        title: String,
    },
    /// `closewindow>>ADDRESS`.
    CloseWindow {
        /// Closed window.
        id: WindowId,
    },
    /// `movewindow>>ADDRESS,WORKSPACENAME`.
    MoveWindow {
        /// Moved window.
        id: WindowId,
        /// Name of the target workspace.
        workspace: String,
    },
    /// `movewindowv2>>ADDRESS,WORKSPACEID,WORKSPACENAME`.
    MoveWindowV2 {
        /// Moved window.
        id: WindowId,
        /// Target workspace id.
        workspace: WorkspaceId,
        /// Target workspace name.
        name: String,
    },
    /// `windowtitle>>ADDRESS`: the title changed (legacy, carries no title).
    WindowTitle {
        /// Window whose title changed.
        id: WindowId,
    },
    /// `windowtitlev2>>ADDRESS,TITLE`.
    WindowTitleV2 {
        /// Window whose title changed.
        id: WindowId,
        /// New title.
        title: String,
    },
    /// `fullscreen>>0|1`: the focused window left or entered fullscreen.
    Fullscreen {
        /// New state.
        on: bool,
    },
    /// `changefloatingmode>>ADDRESS,0|1`.
    ChangeFloatingMode {
        /// Window.
        id: WindowId,
        /// Floating now.
        floating: bool,
    },
    /// `createworkspace>>NAME`.
    CreateWorkspace {
        /// Workspace name.
        name: String,
    },
    /// `createworkspacev2>>ID,NAME`.
    CreateWorkspaceV2 {
        /// Workspace id.
        id: WorkspaceId,
        /// Workspace name.
        name: String,
    },
    /// `destroyworkspace>>NAME`.
    DestroyWorkspace {
        /// Workspace name.
        name: String,
    },
    /// `destroyworkspacev2>>ID,NAME`.
    DestroyWorkspaceV2 {
        /// Workspace id.
        id: WorkspaceId,
        /// Workspace name.
        name: String,
    },
    /// `renameworkspace>>ID,NEWNAME`.
    RenameWorkspace {
        /// Workspace id.
        id: WorkspaceId,
        /// New name.
        name: String,
    },
    /// `moveworkspacev2>>ID,NAME,MONNAME`: a workspace moved to another output.
    MoveWorkspaceV2 {
        /// Workspace id.
        id: WorkspaceId,
        /// Workspace name.
        name: String,
        /// Target monitor.
        monitor: String,
    },
    /// `monitoradded>>NAME` (or `monitoraddedv2>>ID,NAME,DESCRIPTION`).
    MonitorAdded {
        /// Connector name.
        name: String,
    },
    /// `monitorremoved>>NAME` (or `monitorremovedv2>>ID,NAME,DESCRIPTION`).
    MonitorRemoved {
        /// Connector name.
        name: String,
    },
    /// `urgent>>ADDRESS`: the window asks for attention.
    Urgent {
        /// Window.
        id: WindowId,
    },
    /// `configreloaded>>`: the compositor reloaded its configuration.
    ConfigReloaded,
    /// Synthetic: the event connection dropped and was re-established; events
    /// may have been missed, so resynchronise.
    Reconnected,
    /// Any other or malformed event, kept for logging.
    Unknown {
        /// Event name (before `>>`).
        name: String,
        /// Raw payload (after `>>`).
        data: String,
    },
}

/// Errors from a [`CompositorAdapter`].
#[derive(Debug, thiserror::Error)]
pub enum WmError {
    /// The compositor is not running or its IPC endpoint cannot be found.
    #[error("compositor not available: {0}")]
    Unavailable(String),

    /// Socket I/O failed.
    #[error("{context}: {source}")]
    Io {
        /// What was being done.
        context: String,
        /// Underlying error.
        #[source]
        source: std::io::Error,
    },

    /// The compositor answered with something that is not the expected JSON.
    #[error("unexpected reply to {request}: {source}")]
    Json {
        /// The request.
        request: String,
        /// Parse error.
        #[source]
        source: serde_json::Error,
    },

    /// The compositor refused a request.
    #[error("compositor rejected {request:?}: {reply}")]
    Rejected {
        /// The request.
        request: String,
        /// Its reply.
        reply: String,
    },

    /// An argument cannot be sent to the compositor (e.g. a malformed window id).
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
}

/// A window-manager backend.
///
/// Every method is a short blocking round trip; call them from a worker
/// thread or accept a few hundred microseconds on the GUI thread. Methods
/// take `&self`, and implementations are `Send + Sync`.
pub trait CompositorAdapter: Send + Sync + fmt::Debug {
    /// Reads the complete current state.
    fn snapshot(&self) -> Result<WmSnapshot, WmError>;

    /// Starts receiving events. Each call opens an independent stream.
    /// Subscribe before taking the first snapshot so no change is lost.
    fn subscribe(&self) -> Result<EventStream, WmError>;

    /// Focuses a window, switching to its workspace if needed.
    fn activate(&self, id: &WindowId) -> Result<(), WmError>;

    /// Asks a window to close (like its close button).
    fn close(&self, id: &WindowId) -> Result<(), WmError>;

    /// Shows a workspace on the focused monitor, creating it if needed.
    fn switch_workspace(&self, ws: WorkspaceId) -> Result<(), WmError>;

    /// Moves a window to a workspace without following it.
    fn move_to_workspace(&self, id: &WindowId, ws: WorkspaceId) -> Result<(), WmError>;

    /// Toggles one window between floating and tiled.
    fn toggle_floating(&self, id: &WindowId) -> Result<(), WmError>;

    /// Toggles a workspace between tiling and floating (Super+T, Lugh mode is
    /// floating by default): if any window on it floats, every window is
    /// tiled; otherwise every window floats. Returns `true` when the
    /// workspace is now tiled.
    fn toggle_workspace_tiling(&self, ws: WorkspaceId) -> Result<bool, WmError>;

    /// Reloads the compositor configuration (after `apply_mode` rewrote it).
    fn reload(&self) -> Result<(), WmError>;
}

/// A stream of [`WmEvent`]s, fed by a background reader thread.
///
/// It is an [`Iterator`] that blocks for the next event and ends when the
/// adapter gives up (it reconnects on its own first). Dropping the stream
/// stops the reader thread within its poll interval.
#[derive(Debug)]
pub struct EventStream {
    rx: Receiver<WmEvent>,
    stop: Arc<AtomicBool>,
}

impl EventStream {
    /// Builds a stream from a channel; `stop` is raised when the stream is
    /// dropped so the producer can exit. For adapter implementations.
    pub fn new(rx: Receiver<WmEvent>, stop: Arc<AtomicBool>) -> Self {
        Self { rx, stop }
    }

    /// Returns the next event if one is queued, without blocking. `Ok(None)`
    /// means nothing is queued; `Err(())` that the stream has ended.
    #[allow(clippy::result_unit_err)]
    pub fn try_next(&self) -> Result<Option<WmEvent>, ()> {
        match self.rx.try_recv() {
            Ok(ev) => Ok(Some(ev)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(()),
        }
    }

    /// Waits up to `timeout` for the next event. `Ok(None)` on timeout;
    /// `Err(())` when the stream has ended.
    #[allow(clippy::result_unit_err)]
    pub fn next_timeout(&self, timeout: Duration) -> Result<Option<WmEvent>, ()> {
        match self.rx.recv_timeout(timeout) {
            Ok(ev) => Ok(Some(ev)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(()),
        }
    }
}

impl Iterator for EventStream {
    type Item = WmEvent;

    fn next(&mut self) -> Option<WmEvent> {
        self.rx.recv().ok()
    }
}

impl Drop for EventStream {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_id_normalisation() {
        assert_eq!(
            WindowId::from_hyprland("55D4a8c3e0f0").map(|w| w.0),
            Some("0x55d4a8c3e0f0".to_owned())
        );
        assert_eq!(
            WindowId::from_hyprland("0x55d4a8c3e0f0").map(|w| w.0),
            Some("0x55d4a8c3e0f0".to_owned())
        );
        assert_eq!(WindowId::from_hyprland(""), None);
        assert_eq!(WindowId::from_hyprland("0x"), None);
        assert_eq!(WindowId::from_hyprland("zz;reload"), None);
        assert_eq!(WindowId::from_hyprland(","), None);
    }

    #[test]
    fn special_workspaces() {
        assert!(WorkspaceId(-98).is_special());
        assert!(!WorkspaceId(1).is_special());
    }

    #[test]
    fn stream_ends_and_signals_stop() {
        let (tx, rx) = std::sync::mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let stream = EventStream::new(rx, Arc::clone(&stop));
        tx.send(WmEvent::ConfigReloaded).ok();
        assert_eq!(stream.try_next(), Ok(Some(WmEvent::ConfigReloaded)));
        assert_eq!(stream.try_next(), Ok(None));
        drop(tx);
        assert_eq!(stream.next_timeout(Duration::from_millis(10)), Err(()));
        drop(stream);
        assert!(stop.load(Ordering::Relaxed));
    }
}
