//! `Services.launcher`: search over apps, aliases, calculator, settings and
//! open windows; the recent apps; acting on a result.
//!
//! State: `query`, `searching` (always `false`: every provider answers
//! inside the call), `results` [`kind`, `group`, `title`, `subtitle`, `icon`,
//! `target`], `recent` [`appId`, `name`, `icon`].
//! Methods: `search(text)` (answers with one patch `{query, results,
//! searching}`), `activate(index)`, `activateSecondary(index)`.

use std::sync::Arc;

use serde_json::Value;

use super::wm::desktop::Hub;
use super::{CallError, Context, Service, args};

/// The `launcher` service.
#[derive(Debug)]
pub struct LauncherService {
    hub: Arc<Hub>,
}

impl LauncherService {
    pub(crate) fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl Service for LauncherService {
    fn name(&self) -> &'static str {
        "launcher"
    }

    fn state(&self) -> Value {
        self.hub.inner.launcher_state()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let inner = &self.hub.inner;
        match method {
            "search" => inner.search(&args::string_or_empty(a, 0)),
            "activate" => inner.activate_result(args::i64(a, 0)?, false)?,
            "activateSecondary" => inner.activate_result(args::i64(a, 0)?, true)?,
            other => return Err(CallError::UnknownMethod(format!("launcher.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    Box::new(LauncherService::new(Hub::for_context(ctx)))
}
