//! `Services.shell` — the shell's own D-Bus API: `space.lugh.Shell1` at
//! `/space/lugh/Shell1` on the session bus (docs/specs/shell.md §D-Bus). The
//! compositor's key binds call it through `busctl` (docs/dev/hyprland.md).
//!
//! | D-Bus member                     | Effect (QML signal `Services.<service>.<name>(args)`) |
//! |----------------------------------|--------------------------------------------------------|
//! | `ShowLauncher(s query)`          | `shell.showLauncher(query)`                            |
//! | `ShowStartMenu()`                | `shell.showLauncher("")`                               |
//! | `ToggleLauncher()`               | `shell.toggleLauncher()`                               |
//! | `ToggleControlCenter()`          | `shell.toggleControlCenter()`                          |
//! | `ToggleNotificationCenter()`     | `shell.toggleNotificationCenter()`                     |
//! | `ToggleLughMenu()`               | `shell.toggleLughMenu()`                               |
//! | `CloseAll()`                     | `shell.closeAll()`                                     |
//! | `ShowOverview()`                 | logged ("not in Phase 1"), no error                    |
//! | `ShowOSD(s kind, d value)`       | `osd.requested(kind, value)` after the mapping in [`osd`] |
//! | `Screenshot(s mode)`             | `area` \| `screen` \| `window`, see [`screenshot`]; the result is a notification |
//! | `Lock()`                         | `shell.lockRequested()` (the UI forwards it to `Services.session.lock()`) |
//! | `SetLowPower(b on)`              | state `lowPower`                                       |
//! | signal `Ready()`                 | emitted once, on the QML call `shell.ready`            |
//! | signal `ModeApplied(s mode)`     | emitted on the QML call `shell.modeApplied(mode)`      |
//!
//! State: `lowPower` (bool), `version` (string), `primary` (bool: `false`
//! when another process already owns `space.lugh.Shell1`; the host exits
//! then). QML calls: `ready()`, `setLowPower(on)`, `modeApplied(mode)`.
//!
//! `ready` also writes the CI marker line [`READY_MARKER`] to stderr, once.
//!
//! Screenshot results are posted with a D-Bus `Notify` call to whichever
//! daemon owns `org.freedesktop.Notifications` (normally our own service), so
//! they also show when the shell is not the notification server. The shell
//! remembers the last few screenshot notifications and opens the file when
//! their `default` action is invoked.
//!
//! Idle cost: none. One task sleeps on a channel and on `ActionInvoked`.

use std::collections::{HashMap, VecDeque};
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::Value as ZValue;

use super::{CallError, Context, Service, args};
use screenshot::{Mode, Outcome};

mod osd;
mod screenshot;

const NAME: &str = "shell";
const BUS_NAME: &str = "space.lugh.Shell1";
const BUS_PATH: &str = "/space/lugh/Shell1";
const NOTIFY_NAME: &str = "org.freedesktop.Notifications";
const NOTIFY_PATH: &str = "/org/freedesktop/Notifications";
/// Screenshot notifications whose `default` action still opens the file.
const SHOTS_KEPT: usize = 32;

/// The line the boot test waits for (docs/specs/build-and-release.md).
pub const READY_MARKER: &str = "LUGH-MARK: session-ready";

#[derive(Debug)]
enum BusSignal {
    Ready,
    ModeApplied(String),
}

#[derive(Debug, Clone, Copy)]
struct State {
    low_power: bool,
    primary: bool,
}

struct Inner {
    ctx: Context,
    state: Mutex<State>,
    ready_sent: AtomicBool,
    capturing: AtomicBool,
    /// `(notification id, file)` of recent screenshots, oldest first.
    shots: Mutex<VecDeque<(u32, PathBuf)>>,
    bus: mpsc::UnboundedSender<BusSignal>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("shell::Inner")
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

impl Inner {
    fn relay(&self, name: &'static str, args: Vec<Value>) {
        self.ctx.sink.signal(NAME, name, args);
    }

    fn set_low_power(&self, on: bool) {
        let mut s = lock(&self.state);
        if s.low_power != on {
            s.low_power = on;
            self.ctx.sink.patch(NAME, json!({ "lowPower": on }));
        }
    }

    fn set_primary(&self, primary: bool) {
        let mut s = lock(&self.state);
        if s.primary != primary {
            s.primary = primary;
            self.ctx.sink.patch(NAME, json!({ "primary": primary }));
        }
    }

    /// First frame on screen: marker line and `Ready`, once per process.
    fn ready(&self) {
        if self.ready_sent.swap(true, Ordering::SeqCst) {
            return;
        }
        tracing::info!("shell ready: first frame drawn");
        // Written directly: the marker must not depend on the log level.
        let mut err = std::io::stderr().lock();
        let _ = writeln!(err, "{READY_MARKER}");
        let _ = err.flush();
        let _ = self.bus.send(BusSignal::Ready);
    }
}

/// The service handle (the only strong owner of the state).
#[derive(Debug)]
struct Shell {
    inner: Arc<Inner>,
}

impl Service for Shell {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        let s = *lock(&self.inner.state);
        json!({
            "lowPower": s.low_power,
            "version": env!("CARGO_PKG_VERSION"),
            "primary": s.primary,
        })
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        match method {
            "ready" => self.inner.ready(),
            "setLowPower" => self.inner.set_low_power(args::bool(a, 0)?),
            "modeApplied" => {
                let _ = self
                    .inner
                    .bus
                    .send(BusSignal::ModeApplied(args::string(a, 0)?));
            }
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// Posts a notification through the bus. Returns its id.
async fn notify(
    conn: &zbus::Connection,
    icon: &str,
    summary: &str,
    body: &str,
    actions: &[&str],
    image: Option<&str>,
) -> Option<u32> {
    let mut hints: HashMap<&str, ZValue<'_>> = HashMap::new();
    if let Some(path) = image {
        hints.insert("image-path", ZValue::from(path));
    }
    let reply = conn
        .call_method(
            Some(NOTIFY_NAME),
            NOTIFY_PATH,
            Some(NOTIFY_NAME),
            "Notify",
            &(
                "Screenshot",
                0u32,
                icon,
                summary,
                body,
                actions,
                hints,
                -1i32,
            ),
        )
        .await;
    match reply.and_then(|m| m.body().deserialize::<u32>()) {
        Ok(id) => Some(id),
        Err(e) => {
            tracing::warn!(%e, summary, "screenshot notification not delivered");
            None
        }
    }
}

async fn take_screenshot(inner: Arc<Inner>, conn: zbus::Connection, mode: Mode) {
    let outcome = screenshot::capture(mode).await;
    inner.capturing.store(false, Ordering::SeqCst);
    match outcome {
        Outcome::Saved { path, copied } => {
            let file = path.to_string_lossy().into_owned();
            let body = if copied {
                "Saved to Pictures/Screenshots and copied to the clipboard."
            } else {
                "Saved to Pictures/Screenshots."
            };
            let id = notify(
                &conn,
                "camera-photo",
                "Screenshot saved",
                body,
                &["default", "Open"],
                Some(&file),
            )
            .await;
            if let Some(id) = id {
                let mut shots = lock(&inner.shots);
                if shots.len() >= SHOTS_KEPT {
                    shots.pop_front();
                }
                shots.push_back((id, path));
            }
        }
        Outcome::Missing(tool) => {
            let body = if tool == "slurp" {
                "Selecting an area needs slurp. Install the slurp package and try again."
            } else {
                "Screenshots need grim. Install the grim package and try again."
            };
            notify(
                &conn,
                "dialog-information",
                "Screenshots are not available",
                body,
                &[],
                None,
            )
            .await;
        }
        Outcome::Cancelled => {}
        Outcome::Failed(why) => {
            tracing::warn!(%why, "screenshot failed");
            notify(
                &conn,
                "dialog-warning",
                "Screenshot failed",
                "The screen could not be captured.",
                &[],
                None,
            )
            .await;
        }
    }
}

/// The D-Bus object. Holds the state weakly so the connection does not keep
/// a dropped service alive.
struct Api(Weak<Inner>);

impl Api {
    fn relay(&self, name: &'static str, args: Vec<Value>) {
        if let Some(inner) = self.0.upgrade() {
            inner.relay(name, args);
        }
    }
}

#[zbus::interface(name = "space.lugh.Shell1")]
impl Api {
    fn show_launcher(&self, query: &str) {
        self.relay("showLauncher", vec![json!(query)]);
    }

    fn show_start_menu(&self) {
        self.relay("showLauncher", vec![json!("")]);
    }

    fn toggle_launcher(&self) {
        self.relay("toggleLauncher", vec![]);
    }

    fn toggle_control_center(&self) {
        self.relay("toggleControlCenter", vec![]);
    }

    fn toggle_notification_center(&self) {
        self.relay("toggleNotificationCenter", vec![]);
    }

    fn toggle_lugh_menu(&self) {
        self.relay("toggleLughMenu", vec![]);
    }

    fn close_all(&self) {
        self.relay("closeAll", vec![]);
    }

    #[allow(clippy::unused_self)]
    fn show_overview(&self) {
        tracing::info!("ShowOverview: not in Phase 1");
    }

    #[zbus(name = "ShowOSD")]
    fn show_osd(&self, kind: &str, value: f64) {
        match osd::map(kind, value) {
            Some((kind, value)) => {
                if let Some(inner) = self.0.upgrade() {
                    inner
                        .ctx
                        .sink
                        .signal("osd", "requested", vec![json!(kind), json!(value)]);
                }
            }
            None => tracing::debug!(kind, "ShowOSD: unknown kind ignored"),
        }
    }

    fn screenshot(&self, mode: &str, #[zbus(connection)] conn: &zbus::Connection) {
        let Some(inner) = self.0.upgrade() else {
            return;
        };
        let Some(mode) = Mode::parse(mode) else {
            tracing::debug!(mode, "Screenshot: unknown mode ignored");
            return;
        };
        // One capture at a time (a held Print key must not stack selections).
        if inner.capturing.swap(true, Ordering::SeqCst) {
            return;
        }
        let runtime = inner.ctx.runtime.clone();
        runtime.spawn(take_screenshot(inner, conn.clone(), mode));
    }

    fn lock(&self) {
        self.relay("lockRequested", vec![]);
    }

    fn set_low_power(&self, on: bool) {
        if let Some(inner) = self.0.upgrade() {
            inner.set_low_power(on);
        }
    }

    #[zbus(signal)]
    async fn ready(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn mode_applied(emitter: &SignalEmitter<'_>, mode: &str) -> zbus::Result<()>;
}

/// Opens the screenshot whose notification had its `default` action invoked.
fn open_shot(inner: &Inner, msg: &zbus::Message) {
    let body = msg.body();
    let Ok((id, key)) = body.deserialize::<(u32, &str)>() else {
        return;
    };
    if key != "default" {
        return;
    }
    let path = lock(&inner.shots)
        .iter()
        .find(|(shot, _)| *shot == id)
        .map(|(_, p)| p.clone());
    if let Some(path) = path {
        let spawned = tokio::process::Command::new("xdg-open")
            .arg(&path)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        match spawned {
            // Reap it without holding anything.
            Ok(mut child) => {
                inner.ctx.runtime.spawn(async move {
                    let _ = child.wait().await;
                });
            }
            Err(e) => tracing::warn!(%e, "could not open the screenshot"),
        }
    }
}

/// Registers the object, takes the name (never from another owner), then
/// forwards [`BusSignal`]s until the service is dropped.
async fn serve(
    conn: Option<zbus::Connection>,
    weak: Weak<Inner>,
    mut rx: mpsc::UnboundedReceiver<BusSignal>,
) {
    let conn = match conn {
        Some(c) => Ok(c),
        None => zbus::Connection::session().await,
    };
    let setup = async {
        let conn = conn?;
        conn.object_server()
            .at(BUS_PATH, Api(Weak::clone(&weak)))
            .await?;
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface(NOTIFY_NAME)?
            .member("ActionInvoked")?
            .path(NOTIFY_PATH)?
            .build();
        let actions = zbus::MessageStream::for_match_rule(rule, &conn, Some(8)).await?;
        let reply = conn
            .request_name_with_flags(BUS_NAME, zbus::fdo::RequestNameFlags::DoNotQueue.into())
            .await;
        let primary = match reply {
            Ok(_) => true,
            Err(zbus::Error::NameTaken) => false,
            Err(e) => return Err(e),
        };
        let emitter = SignalEmitter::new(&conn, BUS_PATH)?.into_owned();
        zbus::Result::Ok((emitter, actions, primary))
    };
    let (emitter, mut actions, primary) = match setup.await {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(%e, "no session bus for {BUS_NAME}; key binds cannot reach the shell");
            while rx.recv().await.is_some() {}
            return;
        }
    };
    if !primary {
        tracing::warn!("{BUS_NAME} is already owned: another shell is running");
        if let Some(inner) = weak.upgrade() {
            inner.set_primary(false);
        }
    }
    loop {
        tokio::select! {
            signal = rx.recv() => {
                let sent = match signal {
                    Some(_) if !primary => Ok(()),
                    Some(BusSignal::Ready) => Api::ready(&emitter).await,
                    Some(BusSignal::ModeApplied(mode)) => Api::mode_applied(&emitter, &mode).await,
                    None => return,
                };
                if let Err(e) = sent {
                    tracing::debug!(%e, "shell signal not sent");
                }
            }
            Some(msg) = actions.next() => {
                if let (Ok(msg), Some(inner)) = (msg, weak.upgrade()) {
                    open_shot(&inner, &msg);
                }
            }
        }
    }
}

fn start_with(ctx: &Context, conn: Option<zbus::Connection>) -> Box<dyn Service> {
    let (bus, rx) = mpsc::unbounded_channel();
    let inner = Arc::new(Inner {
        ctx: ctx.clone(),
        state: Mutex::new(State {
            low_power: false,
            primary: true,
        }),
        ready_sent: AtomicBool::new(false),
        capturing: AtomicBool::new(false),
        shots: Mutex::new(VecDeque::new()),
        bus,
    });
    ctx.runtime.spawn(serve(conn, Arc::downgrade(&inner), rx));
    Box::new(Shell { inner })
}

/// Starts the service on the session bus (see `services` module docs for the
/// rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    start_with(ctx, None)
}

/// Starts the service on a given bus connection (tests, private buses).
#[must_use]
pub fn start_on(ctx: &Context, conn: zbus::Connection) -> Box<dyn Service> {
    start_with(ctx, Some(conn))
}
