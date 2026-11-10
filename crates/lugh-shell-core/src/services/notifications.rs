//! `Services.notifications` — the freedesktop notification server (spec 1.2):
//! `org.freedesktop.Notifications` at `/org/freedesktop/Notifications` on the
//! session bus.
//!
//! State: `dnd`, `popups`, `history` (newest first; roles `nid`, `appName`,
//! `appIcon`, `summary`, `body`, `urgency`, `time`, `actions`, `image`).
//! Calls: `setDnd(on)`, `expire(nid)`, `dismiss(nid)`, `clearAll()`,
//! `invokeAction(nid, key)`, `notify(appName, summary, body, urgency, actions,
//! image, appIcon)`. Signal: `actionInvoked(nid, key)`.
//!
//! Layout: [`store`] is the pure state machine (its module docs hold the
//! lifetime rules: what expire / dismiss / close mean and which
//! `NotificationClosed` reason each gives); [`hints`] parses the `Notify`
//! arguments; this file is the thin zbus layer.
//!
//! Decisions:
//! - **Name ownership.** The name is requested without `REPLACE_EXISTING` and
//!   without `DO_NOT_QUEUE`: when another daemon owns it we never steal it, the
//!   bus queues us and hands the name over the moment the owner releases it
//!   (no polling, no `NameOwnerChanged` bookkeeping of our own). Until then the
//!   service works for local `notify` calls with an otherwise empty state.
//! - **`expire_timeout`** is not used: toast timing is the UI's job
//!   (`notifications.popup_timeout_ms`; critical ones stay until dismissed).
//! - **`ActionInvoked`** is broadcast, so the sender receives it whatever
//!   match rule it uses. A `resident` notification survives its action.
//! - **Per-app rules**: `notifications.per_app.<id>.banners = false` (matched
//!   on the `desktop-entry` hint, else the lowercased app name) sends the
//!   notification to the history without a toast.
//! - Raw `image-data` is ignored; markup is passed through (`body-markup`) and
//!   filtered by the UI. Text is capped (summary 200, body 2000 characters) and
//!   stripped of control characters.
//! - Idle cost: none. One task sleeps on a channel and on `NameAcquired`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::StreamExt;
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use zbus::object_server::SignalEmitter;

use super::{CallError, Context, Service, args};
use store::{Effects, Incoming, REASON_CLOSED, REASON_DISMISSED, Store};

mod hints;
mod store;

const NAME: &str = "notifications";
const BUS_NAME: &str = "org.freedesktop.Notifications";
const BUS_PATH: &str = "/org/freedesktop/Notifications";

/// A signal to put on the bus, in order.
#[derive(Debug)]
enum BusSignal {
    Closed(u32, u32),
    Action(u32, String),
}

struct Inner {
    ctx: Context,
    store: Mutex<Store>,
    bus: mpsc::UnboundedSender<BusSignal>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("notifications::Inner")
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, Store> {
        match self.store.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Runs one store operation, then sends the patch (changed keys only) and
    /// queues the bus signals. The lock is held across the send so patches
    /// leave in the order the operations happened.
    fn apply<R>(&self, op: impl FnOnce(&mut Store, &mut Effects) -> R) -> R {
        let mut store = self.lock();
        let mut fx = Effects::default();
        let out = op(&mut store, &mut fx);
        let mut patch = Map::new();
        if fx.popups {
            patch.insert("popups".to_owned(), store.popups_json());
        }
        if fx.history {
            patch.insert("history".to_owned(), store.history_json());
        }
        self.ctx.sink.patch(NAME, Value::Object(patch));
        for (id, reason) in fx.closed {
            let _ = self.bus.send(BusSignal::Closed(id, reason));
        }
        out
    }

    fn banners_enabled(&self, app_key: &str) -> bool {
        let cfg = match self.ctx.config.read() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        cfg.notifications
            .per_app
            .get(app_key)
            .is_none_or(|a| a.banners)
    }

    fn post(&self, n: Incoming) -> u32 {
        self.apply(|s, fx| s.insert(n, now_ms(), fx))
    }

    /// The user picked an action: tell the app (bus) and the UI, then remove
    /// the notification (see `Store::action_invoked` for `resident`).
    fn invoke_action(&self, nid: u32, key: String) {
        self.apply(|s, fx| {
            // Bus order: ActionInvoked here, NotificationClosed when `apply`
            // flushes the effects.
            if s.action_invoked(nid, fx) {
                let _ = self.bus.send(BusSignal::Action(nid, key.clone()));
                self.ctx
                    .sink
                    .signal(NAME, "actionInvoked", vec![json!(nid), json!(key)]);
            }
        });
    }
}

/// The service handle (the only strong owner of the state: dropping it stops
/// the bus task).
#[derive(Debug)]
struct Notifications {
    inner: Arc<Inner>,
}

fn nid_arg(args: &[Value], i: usize) -> Result<u32, CallError> {
    u32::try_from(args::i64(args, i)?)
        .map_err(|_| CallError::BadArgs(format!("argument {i}: not a notification id")))
}

/// `actions` from QML: an array of `{key, label}` or the same as a JSON string.
fn local_actions(v: Option<&Value>) -> Vec<(String, String)> {
    let parsed;
    let list = match v {
        Some(Value::Array(a)) => a,
        Some(Value::String(s)) => {
            parsed = serde_json::from_str::<Value>(s).unwrap_or_default();
            match parsed.as_array() {
                Some(a) => a,
                None => return Vec::new(),
            }
        }
        _ => return Vec::new(),
    };
    list.iter()
        .filter_map(|a| {
            let key = a.get("key")?.as_str()?;
            let label = a.get("label").and_then(Value::as_str).unwrap_or_default();
            Some((key.to_owned(), label.to_owned()))
        })
        .collect()
}

impl Service for Notifications {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        let s = self.inner.lock();
        json!({ "dnd": s.dnd(), "popups": s.popups_json(), "history": s.history_json() })
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let inner = &self.inner;
        match method {
            "setDnd" => {
                let on = args::bool(a, 0)?;
                if inner.lock().set_dnd(on) {
                    inner.ctx.sink.patch(NAME, json!({ "dnd": on }));
                    // desktop.toml is written off the caller's thread.
                    let ctx = inner.ctx.clone();
                    inner.ctx.runtime.spawn_blocking(move || {
                        ctx.update_config(|c| c.notifications.do_not_disturb = on);
                    });
                }
            }
            "expire" => {
                let nid = nid_arg(a, 0)?;
                inner.apply(|s, fx| s.expire(nid, fx));
            }
            "dismiss" => {
                let nid = nid_arg(a, 0)?;
                inner.apply(|s, fx| s.remove(nid, REASON_DISMISSED, fx));
            }
            "clearAll" => inner.apply(|s, fx| s.clear_all(fx)),
            "invokeAction" => inner.invoke_action(nid_arg(a, 0)?, args::string(a, 1)?),
            "notify" => {
                let app_name = args::string(a, 0)?;
                let summary = args::string(a, 1)?;
                let urgency = a.get(3).and_then(Value::as_u64).map_or(1, |u| u.min(2));
                let image = args::string_or_empty(a, 5);
                let n = Incoming {
                    app_icon: hints::resolve_icon(&args::string_or_empty(a, 6), "", &app_name),
                    banners: inner.banners_enabled(&app_name.trim().to_lowercase()),
                    app_name,
                    summary,
                    body: args::string_or_empty(a, 2),
                    urgency: u8::try_from(urgency).unwrap_or(1),
                    actions: local_actions(a.get(4)),
                    image: hints::resolve_image(&image),
                    ..Incoming::default()
                };
                return Ok(json!(inner.post(n)));
            }
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// The D-Bus object. Holds the state weakly so the connection does not keep
/// a dropped service alive.
struct Server(Weak<Inner>);

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Server {
    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: &str,
        replaces_id: u32,
        app_icon: &str,
        summary: &str,
        body: &str,
        actions: Vec<&str>,
        hints: HashMap<&str, zbus::zvariant::Value<'_>>,
        _expire_timeout: i32,
    ) -> u32 {
        let Some(inner) = self.0.upgrade() else {
            return 0;
        };
        let h = hints::parse_hints(&hints);
        let app_key = if h.desktop_entry.is_empty() {
            app_name.trim().to_lowercase()
        } else {
            h.desktop_entry.clone()
        };
        inner.post(Incoming {
            app_name: app_name.to_owned(),
            replaces_id,
            app_icon: hints::resolve_icon(app_icon, &h.desktop_entry, app_name),
            summary: summary.to_owned(),
            body: body.to_owned(),
            actions: hints::parse_actions(&actions),
            urgency: h.urgency,
            image: hints::resolve_image(&h.image_path),
            transient: h.transient,
            resident: h.resident,
            banners: inner.banners_enabled(&app_key),
        })
    }

    fn close_notification(&self, id: u32) {
        if let Some(inner) = self.0.upgrade() {
            inner.apply(|s, fx| s.remove(id, REASON_CLOSED, fx));
        }
    }

    #[allow(clippy::unused_self)]
    fn get_capabilities(&self) -> Vec<&'static str> {
        vec![
            "body",
            "body-markup",
            "actions",
            "icon-static",
            "persistence",
        ]
    }

    #[allow(clippy::unused_self)]
    fn get_server_information(&self) -> (&'static str, &'static str, &'static str, &'static str) {
        ("lugh-shell", "Lugh", env!("CARGO_PKG_VERSION"), "1.2")
    }

    #[zbus(signal)]
    async fn notification_closed(
        emitter: &SignalEmitter<'_>,
        id: u32,
        reason: u32,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn action_invoked(
        emitter: &SignalEmitter<'_>,
        id: u32,
        action_key: &str,
    ) -> zbus::Result<()>;
}

/// Registers the object, queues for the name, then forwards [`BusSignal`]s
/// until the service is dropped.
async fn serve(
    conn: Option<zbus::Connection>,
    server: Server,
    mut rx: mpsc::UnboundedReceiver<BusSignal>,
) {
    let conn = match conn {
        Some(c) => Ok(c),
        None => zbus::Connection::session().await,
    };
    let setup = async {
        let conn = conn?;
        conn.object_server().at(BUS_PATH, server).await?;
        let dbus = zbus::fdo::DBusProxy::new(&conn).await?;
        let acquired = dbus.receive_name_acquired().await?;
        // No flags at all: never replace an owner; queue behind it instead.
        // (Not `Default::default()`: zbus's default set is replace-existing.)
        let no_flags = std::iter::empty::<zbus::fdo::RequestNameFlags>().collect();
        let reply = conn.request_name_with_flags(BUS_NAME, no_flags).await?;
        if reply == zbus::fdo::RequestNameReply::InQueue {
            tracing::info!(
                "another notification daemon owns {BUS_NAME}; waiting for it to release the name"
            );
        }
        let emitter = SignalEmitter::new(&conn, BUS_PATH)?.into_owned();
        zbus::Result::Ok((emitter, acquired))
    };
    let (emitter, mut acquired) = match setup.await {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(%e, "no session bus for {BUS_NAME}; only local notifications work");
            while rx.recv().await.is_some() {}
            return;
        }
    };
    loop {
        tokio::select! {
            signal = rx.recv() => {
                let sent = match signal {
                    Some(BusSignal::Closed(id, reason)) => {
                        Server::notification_closed(&emitter, id, reason).await
                    }
                    Some(BusSignal::Action(id, key)) => {
                        Server::action_invoked(&emitter, id, &key).await
                    }
                    None => return,
                };
                if let Err(e) = sent {
                    tracing::debug!(%e, "notification signal not sent");
                }
            }
            Some(signal) = acquired.next() => {
                if signal.args().is_ok_and(|a| a.name().as_str() == BUS_NAME) {
                    tracing::info!("now serving {BUS_NAME}");
                }
            }
        }
    }
}

fn start_with(ctx: &Context, conn: Option<zbus::Connection>) -> Box<dyn Service> {
    let (bus, rx) = mpsc::unbounded_channel();
    let inner = Arc::new(Inner {
        ctx: ctx.clone(),
        store: Mutex::new(Store::new(ctx.config().notifications.do_not_disturb)),
        bus,
    });
    ctx.runtime
        .spawn(serve(conn, Server(Arc::downgrade(&inner)), rx));
    Box::new(Notifications { inner })
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::{Event, Sink};
    use std::sync::RwLock;

    fn local_service() -> (
        Notifications,
        Arc<Mutex<Vec<Event>>>,
        tokio::runtime::Runtime,
    ) {
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap_or_else(|e| panic!("runtime: {e}"));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s2 = Arc::clone(&seen);
        let ctx = Context {
            sink: Sink::new(move |e| {
                if let Ok(mut v) = s2.lock() {
                    v.push(e);
                }
            }),
            runtime: rt.handle().clone(),
            config: Arc::new(RwLock::new(crate::config::DesktopConfig::default())),
        };
        // No bus task: the receiver is dropped, sends are ignored.
        let (bus, _rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            ctx,
            store: Mutex::new(Store::new(false)),
            bus,
        });
        (Notifications { inner }, seen, rt)
    }

    fn drain(seen: &Arc<Mutex<Vec<Event>>>) -> Vec<Value> {
        seen.lock()
            .map(|mut v| v.drain(..).map(|e| e.to_json()).collect())
            .unwrap_or_default()
    }

    #[test]
    fn local_notify_patches_only_changed_keys() {
        let (svc, seen, _rt) = local_service();
        let id = svc.call(
            "notify",
            &[
                json!("Lugh Store"),
                json!("Updates ready"),
                json!("12 updates"),
                json!(0),
                json!([{ "key": "install", "label": "Install now" }]),
                json!("/tmp/a b.png"),
            ],
        );
        assert_eq!(id, Ok(json!(1)));
        let ev = drain(&seen);
        assert_eq!(ev.len(), 1);
        let row = &ev[0]["d"]["popups"][0];
        assert_eq!(row["appIcon"], "lugh store");
        assert_eq!(row["urgency"], 0);
        assert_eq!(row["image"], "file:///tmp/a%20b.png");
        assert_eq!(
            row["actions"],
            "[{\"key\":\"install\",\"label\":\"Install now\"}]"
        );
        assert_eq!(ev[0]["d"]["history"][0]["nid"], 1);
        assert!(ev[0]["d"].get("dnd").is_none());

        // Actions as a JSON string, icon override, default urgency.
        let _ = svc.call(
            "notify",
            &[
                json!("Files"),
                json!("Copied"),
                Value::Null,
                Value::Null,
                json!("[{\"key\":\"default\",\"label\":\"Open\"}]"),
                json!(""),
                json!("folder"),
            ],
        );
        let ev = drain(&seen);
        let row = &ev[0]["d"]["popups"][0];
        assert_eq!(
            (&row["appIcon"], &row["urgency"]),
            (&json!("folder"), &json!(1))
        );
        assert_eq!(row["actions"], "[{\"key\":\"default\",\"label\":\"Open\"}]");

        assert_eq!(svc.call("expire", &[json!(1)]), Ok(Value::Null));
        let ev = drain(&seen);
        assert_eq!(ev.len(), 1);
        assert!(ev[0]["d"].get("history").is_none(), "only popups changed");
        assert_eq!(ev[0]["d"]["popups"].as_array().map(Vec::len), Some(1));

        assert_eq!(svc.call("expire", &[json!(1)]), Ok(Value::Null));
        assert!(drain(&seen).is_empty(), "no change, no patch");

        assert_eq!(svc.state()["history"].as_array().map(Vec::len), Some(2));
        assert_eq!(svc.state()["dnd"], false);
    }

    #[test]
    fn invoke_action_signals_then_dismisses() {
        let (svc, seen, _rt) = local_service();
        let _ = svc.call("notify", &[json!("App"), json!("Hi")]);
        drain(&seen);
        assert_eq!(
            svc.call("invokeAction", &[json!(1.0), json!("default")]),
            Ok(Value::Null)
        );
        let ev = drain(&seen);
        assert_eq!(ev.len(), 2);
        assert_eq!(
            ev[0],
            json!({ "t": "signal", "s": "notifications", "n": "actionInvoked", "a": [1, "default"] })
        );
        assert_eq!(ev[1]["d"], json!({ "popups": [], "history": [] }));
        // Gone: a second invoke does nothing.
        let _ = svc.call("invokeAction", &[json!(1), json!("default")]);
        assert!(drain(&seen).is_empty());

        let _ = svc.call("notify", &[json!("App"), json!("Hi")]);
        let _ = svc.call("clearAll", &[]);
        assert_eq!(svc.state()["history"], json!([]));
        assert!(matches!(
            svc.call("dismiss", &[json!(-1)]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("nope", &[]),
            Err(CallError::UnknownMethod(_))
        ));
    }
}
