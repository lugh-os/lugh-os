//! `Services.wm`: workspaces, windows, focus and dock overlap, from the
//! compositor (Hyprland in Phases 1–4).
//!
//! State: `available` (bool), `workspaces` [`wsId` int, `name`, `occupied`],
//! `activeWorkspace` (int), `focusedAppId`, `focusedAppName`, `focusedTitle`,
//! `toplevels` [`winId`, `appId`, `title`, `workspace` int, `focused`,
//! `x`, `y`, `width`, `height` (logical px relative to the origin of the
//! window's monitor), `monitorWidth`, `monitorHeight` (logical px); all 0
//! when unknown; `monitor` (that monitor's output name, "" when unknown)],
//! `dockOverlapped` (bool), `activeOutput` (the focused output's name, e.g.
//! `eDP-1`: Hyprland's connector names are the `wl_output` names Qt uses as
//! screen names; "" when unknown).
//! Methods: `switchWorkspace(wsId)`, `activate(winId)`, `close(winId)`,
//! `moveToWorkspace(winId, wsId)` (without following the window).
//!
//! `workspaces` always holds 1..=4 (more when the compositor reports higher
//! ids). The backend does not know the shell's workspace grid size
//! (`ShellSettings.workspaceRows × workspaceCols`): the QML overview fills in
//! the empty grid workspaces itself.
//!
//! Window geometry comes from compositor snapshots, refreshed shortly after
//! events that may move windows; it can lag a live drag by a moment.
//!
//! `appId` in `toplevels` and `focusedAppId` is the desktop-entry id the
//! window was matched to (so it joins with `apps.installed` / `apps.dock`),
//! or the window class when no installed app matches.
//!
//! The work happens in [`desktop`], shared with `apps` and `launcher`.

#[path = "desktop/mod.rs"]
pub(crate) mod desktop;

use std::sync::Arc;

use serde_json::Value;

pub use desktop::{DesktopParts, start_desktop};

use super::{CallError, Context, Service, args};
use desktop::Hub;

/// The `wm` service.
#[derive(Debug)]
pub struct WmService {
    hub: Arc<Hub>,
}

impl WmService {
    pub(crate) fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl Service for WmService {
    fn name(&self) -> &'static str {
        "wm"
    }

    fn state(&self) -> Value {
        self.hub.inner.wm_state()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let inner = &self.hub.inner;
        match method {
            "switchWorkspace" => inner.switch_workspace(args::i64(a, 0)?)?,
            "activate" => inner.activate_window(&args::string(a, 0)?)?,
            "close" => inner.close_window(&args::string(a, 0)?)?,
            "moveToWorkspace" => {
                inner.move_window_to_workspace(&args::string(a, 0)?, args::i64(a, 1)?)?;
            }
            other => return Err(CallError::UnknownMethod(format!("wm.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    Box::new(WmService::new(Hub::for_context(ctx)))
}
