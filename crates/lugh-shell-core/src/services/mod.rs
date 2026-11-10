//! Live system services behind the QML `Services` singleton.
//!
//! Protocol and naming: `docs/specs/shell-bridge.md`. In short:
//!
//! - Every service has a **name** equal to its QML object
//!   (`Services.network` ⇒ `"network"`) and a **state**: one JSON object whose
//!   keys are exactly the QML property names (arrays become `ListModel`s, their
//!   element keys are the model roles).
//! - A service pushes changes as [`Event::Patch`] (a partial state object: only
//!   the keys that changed; an array key always carries the whole array) and
//!   one-shot notifications as [`Event::Signal`] (QML signal name + args).
//! - QML calls `"<service>.<method>"` with a JSON array of arguments
//!   ([`ShellCore::call`]). Calls **never block**: a service starts the work on
//!   the runtime and reports the outcome through patches.
//!
//! The same [`ShellCore`] is driven by two front-ends: the cxx-qt host in
//! `ui/shell/` (in-process, production) and `lugh-shell-devd` (WebSocket, lets
//! the QML preview use a real machine's services during development).
//!
//! Rules for service modules:
//! - `start(ctx)` must not fail and must not block: when the system service is
//!   missing (no BlueZ, no battery, no Hyprland) the service still exists, says
//!   so in its state (`available: false`, …) and keeps retrying or watching for
//!   the bus name in the background.
//! - No polling loops for things that have change signals. Coalesce bursts
//!   (e.g. Wi-Fi scan results) into one patch.
//! - Keep state small and typed like the QML mock: a role that is an `int` in
//!   `Services.qml` must be a JSON integer, etc.

use std::fmt;
use std::sync::{Arc, RwLock};

use serde_json::{Map, Value};

use crate::config::DesktopConfig;

pub mod appearance;
pub mod apps;
pub mod audio;
pub mod bluetooth;
pub mod display;
pub mod keyboard;
pub mod launcher;
pub mod media;
pub mod network;
pub mod notifications;
pub mod power;
pub mod session;
pub mod shell;
pub mod trash;
pub mod wm;

/// Something a service tells the UI.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Partial state: only changed keys. Arrays are always sent whole.
    Patch {
        /// Service name, e.g. `"network"`.
        service: &'static str,
        /// JSON object with the changed properties.
        data: Map<String, Value>,
    },
    /// One-shot QML signal, e.g. `session.unlocked()`.
    Signal {
        /// Service name.
        service: &'static str,
        /// QML signal name.
        name: &'static str,
        /// Signal arguments.
        args: Vec<Value>,
    },
}

impl Event {
    /// Wire form: `{"t":"patch","s":"network","d":{…}}` or
    /// `{"t":"signal","s":"session","n":"unlocked","a":[…]}`.
    #[must_use]
    pub fn to_json(&self) -> Value {
        match self {
            Self::Patch { service, data } => {
                serde_json::json!({ "t": "patch", "s": service, "d": data })
            }
            Self::Signal {
                service,
                name,
                args,
            } => {
                serde_json::json!({ "t": "signal", "s": service, "n": name, "a": args })
            }
        }
    }
}

/// Where services send [`Event`]s. Cheap to clone; callable from any thread.
#[derive(Clone)]
pub struct Sink(Arc<dyn Fn(Event) + Send + Sync>);

impl Sink {
    /// Wraps a callback. The callback must be quick and must not call back
    /// into [`ShellCore`] synchronously (front-ends queue to their own loop).
    pub fn new(f: impl Fn(Event) + Send + Sync + 'static) -> Self {
        Self(Arc::new(f))
    }

    /// Sends any event.
    pub fn send(&self, event: Event) {
        (self.0)(event);
    }

    /// Sends a partial state. `data` must be a JSON object; anything else is
    /// ignored (and logged), so `json!({...})` is the intended argument.
    pub fn patch(&self, service: &'static str, data: Value) {
        match data {
            Value::Object(map) if !map.is_empty() => self.send(Event::Patch { service, data: map }),
            Value::Object(_) => {}
            other => tracing::warn!(service, ?other, "patch is not a JSON object; dropped"),
        }
    }

    /// Emits a QML signal.
    pub fn signal(&self, service: &'static str, name: &'static str, args: Vec<Value>) {
        self.send(Event::Signal {
            service,
            name,
            args,
        });
    }
}

impl fmt::Debug for Sink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Sink")
    }
}

/// What every service gets at start.
#[derive(Debug, Clone)]
pub struct Context {
    /// Event sink towards the UI.
    pub sink: Sink,
    /// Shared tokio runtime for D-Bus (zbus), timers and subprocesses.
    pub runtime: tokio::runtime::Handle,
    /// The loaded `desktop.toml`; the `appearance` service owns writes.
    pub config: Arc<RwLock<DesktopConfig>>,
}

impl Context {
    /// The one way to change `desktop.toml` from a service: applies `f` to the
    /// shared config under the write lock, then saves it atomically. Returns a
    /// copy of the new config. Save failures are logged, not fatal (the change
    /// still applies to this session).
    pub fn update_config(&self, f: impl FnOnce(&mut DesktopConfig)) -> DesktopConfig {
        let mut guard = match self.config.write() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        f(&mut guard);
        match DesktopConfig::default_path() {
            Ok(path) => {
                if let Err(e) = guard.save_atomic(&path) {
                    tracing::warn!(%e, "could not save desktop.toml");
                }
            }
            Err(e) => tracing::warn!(%e, "no config directory; desktop.toml not saved"),
        }
        guard.clone()
    }

    /// A copy of the current config.
    #[must_use]
    pub fn config(&self) -> DesktopConfig {
        match self.config.read() {
            Ok(g) => g.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }
}

/// Why a call was refused. The message is for logs, not for users: user-facing
/// errors travel as state (`lastError`, `authError`, …).
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CallError {
    /// `"<service>.<method>"` names no service.
    #[error("unknown service `{0}`")]
    UnknownService(String),
    /// The service has no such method.
    #[error("unknown method `{0}`")]
    UnknownMethod(String),
    /// Wrong number or type of arguments.
    #[error("bad arguments: {0}")]
    BadArgs(String),
    /// The call was understood but cannot be done right now.
    #[error("{0}")]
    Failed(String),
}

/// One system service (see the module docs for the rules).
pub trait Service: Send + Sync + fmt::Debug {
    /// QML object name: `"network"`, `"audio"`, …
    fn name(&self) -> &'static str;
    /// Full current state (JSON object, QML property names).
    fn state(&self) -> Value;
    /// Handles `Services.<name>.<method>(args…)`. Must return quickly.
    fn call(&self, method: &str, args: &[Value]) -> Result<Value, CallError>;
}

/// Placeholder used until a service module is implemented, and by tests.
#[derive(Debug)]
pub struct StubService(pub &'static str);

impl Service for StubService {
    fn name(&self) -> &'static str {
        self.0
    }
    fn state(&self) -> Value {
        Value::Object(Map::new())
    }
    fn call(&self, method: &str, _args: &[Value]) -> Result<Value, CallError> {
        Err(CallError::UnknownMethod(format!("{}.{method}", self.0)))
    }
}

/// Argument helpers for `Service::call` implementations.
pub mod args {
    use super::{CallError, Value};

    fn missing(i: usize, want: &str) -> CallError {
        CallError::BadArgs(format!("argument {i}: expected {want}"))
    }
    /// String at position `i`.
    pub fn string(args: &[Value], i: usize) -> Result<String, CallError> {
        args.get(i)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| missing(i, "a string"))
    }
    /// Optional string at position `i` (absent or `null` ⇒ `""`).
    #[must_use]
    pub fn string_or_empty(args: &[Value], i: usize) -> String {
        args.get(i)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    }
    /// Bool at position `i`.
    pub fn bool(args: &[Value], i: usize) -> Result<bool, CallError> {
        args.get(i)
            .and_then(Value::as_bool)
            .ok_or_else(|| missing(i, "a bool"))
    }
    /// Number at position `i`.
    pub fn f64(args: &[Value], i: usize) -> Result<f64, CallError> {
        args.get(i)
            .and_then(Value::as_f64)
            .ok_or_else(|| missing(i, "a number"))
    }
    /// Integer at position `i` (accepts `3` and `3.0`).
    pub fn i64(args: &[Value], i: usize) -> Result<i64, CallError> {
        let v = args.get(i).ok_or_else(|| missing(i, "an integer"))?;
        #[allow(clippy::cast_possible_truncation)]
        v.as_i64()
            .or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))
            .ok_or_else(|| missing(i, "an integer"))
    }
}

/// All services of one shell process.
#[derive(Debug)]
pub struct ShellCore {
    services: Vec<Box<dyn Service>>,
    _runtime: Option<tokio::runtime::Runtime>,
}

impl ShellCore {
    /// Starts every service on a small private runtime. `sink` receives all
    /// events, from arbitrary threads.
    ///
    /// # Errors
    /// Only when the tokio runtime cannot be created.
    pub fn start(sink: Sink) -> std::io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("lugh-shell-core")
            .enable_all()
            .build()?;
        let config = DesktopConfig::load_default_location().unwrap_or_else(|e| {
            tracing::warn!(%e, "desktop.toml unreadable; using defaults");
            DesktopConfig::default()
        });
        let config = Arc::new(RwLock::new(config));
        let ctx = Context {
            sink,
            runtime: runtime.handle().clone(),
            config,
        };
        let mut core = Self::with_services(Self::start_all(&ctx));
        core._runtime = Some(runtime);
        Ok(core)
    }

    fn start_all(ctx: &Context) -> Vec<Box<dyn Service>> {
        vec![
            appearance::start(ctx),
            session::start(ctx),
            wm::start(ctx),
            apps::start(ctx),
            launcher::start(ctx),
            notifications::start(ctx),
            network::start(ctx),
            bluetooth::start(ctx),
            audio::start(ctx),
            display::start(ctx),
            power::start(ctx),
            media::start(ctx),
            keyboard::start(ctx),
            trash::start(ctx),
            shell::start(ctx),
        ]
    }

    /// A core over the given services (tests, custom front-ends).
    #[must_use]
    pub fn with_services(services: Vec<Box<dyn Service>>) -> Self {
        Self {
            services,
            _runtime: None,
        }
    }

    /// `{ "<service>": { …state… }, … }` for every service.
    #[must_use]
    pub fn snapshot(&self) -> Value {
        let mut all = Map::new();
        for s in &self.services {
            all.insert(s.name().to_owned(), s.state());
        }
        Value::Object(all)
    }

    /// Dispatches `"<service>.<method>"`.
    ///
    /// # Errors
    /// [`CallError`] when the target is unknown or the service refuses.
    pub fn call(&self, target: &str, args: &[Value]) -> Result<Value, CallError> {
        if target == "core.snapshot" {
            return Ok(self.snapshot());
        }
        let (service, method) = target
            .split_once('.')
            .ok_or_else(|| CallError::UnknownMethod(target.to_owned()))?;
        let s = self
            .services
            .iter()
            .find(|s| s.name() == service)
            .ok_or_else(|| CallError::UnknownService(service.to_owned()))?;
        s.call(method, args)
    }

    /// JSON front door shared by both front-ends.
    /// Request `{"id":7,"m":"network.connectTo","a":["ssid","pw"]}` →
    /// reply `{"id":7,"r":<result>}` or `{"id":7,"e":"message"}`.
    /// `id` is optional and echoed as given.
    #[must_use]
    pub fn handle_json(&self, request: &str) -> String {
        let (id, result) = match serde_json::from_str::<Value>(request) {
            Ok(req) => {
                let id = req.get("id").cloned().unwrap_or(Value::Null);
                let method = req.get("m").and_then(Value::as_str).unwrap_or_default();
                let empty = Vec::new();
                let args = req.get("a").and_then(Value::as_array).unwrap_or(&empty);
                (id, self.call(method, args).map_err(|e| e.to_string()))
            }
            Err(e) => (Value::Null, Err(format!("bad request: {e}"))),
        };
        match result {
            Ok(r) => serde_json::json!({ "id": id, "r": r }).to_string(),
            Err(e) => {
                tracing::debug!(%e, "call failed");
                serde_json::json!({ "id": id, "e": e }).to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct Echo;
    impl Service for Echo {
        fn name(&self) -> &'static str {
            "echo"
        }
        fn state(&self) -> Value {
            serde_json::json!({ "ready": true })
        }
        fn call(&self, method: &str, args: &[Value]) -> Result<Value, CallError> {
            match method {
                "say" => Ok(Value::String(args::string(args, 0)?)),
                other => Err(CallError::UnknownMethod(other.to_owned())),
            }
        }
    }

    #[test]
    fn dispatch_snapshot_and_json() {
        let core = ShellCore::with_services(vec![Box::new(Echo), Box::new(StubService("network"))]);
        assert_eq!(core.snapshot()["echo"]["ready"], true);
        assert_eq!(
            core.call("echo.say", &[Value::from("hi")]),
            Ok(Value::from("hi"))
        );
        assert!(matches!(
            core.call("nope.x", &[]),
            Err(CallError::UnknownService(_))
        ));
        assert!(matches!(
            core.call("echo.say", &[]),
            Err(CallError::BadArgs(_))
        ));
        let reply: Value =
            serde_json::from_str(&core.handle_json(r#"{"id":7,"m":"echo.say","a":["yo"]}"#))
                .unwrap_or_default();
        assert_eq!(reply, serde_json::json!({ "id": 7, "r": "yo" }));
        let reply: Value = serde_json::from_str(&core.handle_json("{")).unwrap_or_default();
        assert!(reply["e"].is_string());
    }

    #[test]
    fn sink_patch_and_wire_form() {
        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let s2 = Arc::clone(&seen);
        let sink = Sink::new(move |e| {
            if let Ok(mut v) = s2.lock() {
                v.push(e.to_json());
            }
        });
        sink.patch("audio", serde_json::json!({ "volume": 0.5 }));
        sink.patch("audio", serde_json::json!({}));
        sink.signal("session", "unlocked", vec![]);
        let seen = seen.lock().map(|v| v.clone()).unwrap_or_default();
        assert_eq!(seen.len(), 2);
        assert_eq!(
            seen[0],
            serde_json::json!({ "t": "patch", "s": "audio", "d": { "volume": 0.5 } })
        );
        assert_eq!(seen[1]["n"], "unlocked");
    }
}
