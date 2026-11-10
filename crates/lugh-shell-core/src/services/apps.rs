//! `Services.apps`: installed apps, the dock, launching in systemd scopes.
//!
//! State: `installed` [`appId`, `name`, `genericName`, `icon`, `keywords`]
//! (visible apps, sorted by name), `dock` [`appId`, `name`, `icon`, `pinned`,
//! `running`, `windows` int, `launching`, `attention`] (pinned apps in
//! `desktop.toml` order, then running ones, then ones still starting).
//! Methods: `activate(appId)`, `launch(appId)`, `quit(appId)`, `pin(appId)`,
//! `unpin(appId)`, `rescan()`.
//! Signal: `launchFailed(appId, message)`.

use std::sync::Arc;

use serde_json::Value;

use super::wm::desktop::Hub;
use super::{CallError, Context, Service, args};

/// The `apps` service.
#[derive(Debug)]
pub struct AppsService {
    hub: Arc<Hub>,
}

impl AppsService {
    pub(crate) fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl Service for AppsService {
    fn name(&self) -> &'static str {
        "apps"
    }

    fn state(&self) -> Value {
        self.hub.inner.apps_state()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let inner = &self.hub.inner;
        match method {
            "activate" => {
                inner.activate_app(&args::string(a, 0)?)?;
            }
            "launch" => inner.launch_app(&args::string(a, 0)?)?,
            "quit" => inner.quit_app(&args::string(a, 0)?)?,
            "pin" => inner.set_pinned(&args::string(a, 0)?, true),
            "unpin" => inner.set_pinned(&args::string(a, 0)?, false),
            "rescan" => inner.rescan(),
            other => return Err(CallError::UnknownMethod(format!("apps.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    Box::new(AppsService::new(Hub::for_context(ctx)))
}
