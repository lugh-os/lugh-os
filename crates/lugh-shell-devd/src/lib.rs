//! `lugh-shell-devd`: one [`ShellCore`] behind a WebSocket, for development.
//!
//! The QML preview (`backend/WsBackend.qml`) connects to it and drives the real
//! services of the dev machine. Protocol (`docs/specs/shell-bridge.md`):
//!
//! - every text frame from a client is a request
//!   `{"id":7,"m":"network.connectTo","a":[…]}` and gets one reply frame
//!   `{"id":7,"r":…}` / `{"id":7,"e":"msg"}` ([`ShellCore::handle_json`]);
//! - a request with `m == "core.snapshot"` is additionally answered with
//!   `{"t":"snapshot","d":{…}}`, to that client only;
//! - every core event is broadcast to all clients
//!   (`{"t":"patch",…}` / `{"t":"signal",…}`).
//!
//! Replies, snapshots and events share one bounded queue per client, so a
//! client sees them in order. A client whose queue overflows is dropped: the
//! core never waits for a socket.

use std::collections::HashMap;
use std::future::Future;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use lugh_shell_core::services::{Event, ShellCore, Sink};
use serde_json::Value;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, mpsc};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{Message, Utf8Bytes};

/// Frames a client may have pending before it is dropped.
pub const DEFAULT_QUEUE: usize = 256;
/// Largest request frame accepted from a client.
const MAX_REQUEST_BYTES: usize = 1 << 20;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const CLOSE_TIMEOUT: Duration = Duration::from_millis(500);

/// What a connection task gets from [`Hub::register`].
#[derive(Debug)]
pub struct Registration {
    /// Client id, for [`Hub::send_to`] and [`Hub::unregister`].
    pub id: u64,
    /// Frames to write to this client, in order.
    pub queue: mpsc::Receiver<Utf8Bytes>,
    /// Notified when the hub drops the client (overflow or shutdown).
    pub kill: Arc<Notify>,
}

#[derive(Debug)]
struct Client {
    tx: mpsc::Sender<Utf8Bytes>,
    kill: Arc<Notify>,
}

#[derive(Debug, Default)]
struct HubInner {
    next_id: u64,
    /// Number of broadcasts so far (see [`handle_request`]).
    seq: u64,
    clients: HashMap<u64, Client>,
}

/// The connected clients and their outgoing queues. Nothing here blocks or
/// awaits, so [`Hub::broadcast`] is safe to call from the core's [`Sink`].
#[derive(Debug)]
pub struct Hub {
    capacity: usize,
    inner: Mutex<HubInner>,
}

impl Hub {
    /// A hub whose clients may each have `capacity` frames pending.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            inner: Mutex::new(HubInner::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, HubInner> {
        match self.inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// A [`Sink`] that broadcasts every core event; with `print`, each event is
    /// logged too.
    #[must_use]
    pub fn sink(self: &Arc<Self>, print: bool) -> Sink {
        let hub = Arc::clone(self);
        Sink::new(move |event: Event| {
            let text = event.to_json().to_string();
            if print {
                tracing::info!(target: "event", "{text}");
            }
            hub.broadcast(text);
        })
    }

    /// Adds a client.
    #[must_use]
    pub fn register(&self) -> Registration {
        let (tx, queue) = mpsc::channel(self.capacity);
        let kill = Arc::new(Notify::new());
        let mut inner = self.lock();
        inner.next_id += 1;
        let id = inner.next_id;
        inner.clients.insert(
            id,
            Client {
                tx,
                kill: Arc::clone(&kill),
            },
        );
        Registration { id, queue, kill }
    }

    /// Forgets a client (no-op when it is already gone).
    pub fn unregister(&self, id: u64) {
        self.lock().clients.remove(&id);
    }

    /// Number of connected clients.
    #[must_use]
    pub fn client_count(&self) -> usize {
        self.lock().clients.len()
    }

    fn drop_client(inner: &mut HubInner, id: u64, why: &str) {
        if let Some(c) = inner.clients.remove(&id) {
            tracing::warn!(client = id, "{why}; dropping the client");
            c.kill.notify_one();
        }
    }

    /// Queues `text` for every client. Clients that cannot take it are dropped.
    pub fn broadcast(&self, text: impl Into<Utf8Bytes>) {
        let text = text.into();
        let mut inner = self.lock();
        inner.seq += 1;
        let full: Vec<u64> = inner
            .clients
            .iter()
            .filter(|(_, c)| c.tx.try_send(text.clone()).is_err())
            .map(|(id, _)| *id)
            .collect();
        for id in full {
            Self::drop_client(&mut inner, id, "client is too slow (queue full)");
        }
    }

    /// Queues `frames` for one client, which is dropped when it cannot take
    /// them. With `if_seq`, nothing is queued and `false` is returned when a
    /// broadcast happened since that [`Hub::seq`] value.
    pub fn send_to(&self, id: u64, frames: Vec<String>, if_seq: Option<u64>) -> bool {
        let mut inner = self.lock();
        if if_seq.is_some_and(|s| s != inner.seq) {
            return false;
        }
        let Some(client) = inner.clients.get(&id) else {
            return true;
        };
        let overflow = frames
            .into_iter()
            .any(|f| client.tx.try_send(f.into()).is_err());
        if overflow {
            Self::drop_client(&mut inner, id, "client is too slow (queue full)");
        }
        true
    }

    /// Broadcast counter.
    #[must_use]
    pub fn seq(&self) -> u64 {
        self.lock().seq
    }

    /// Drops every client (shutdown).
    pub fn close_all(&self) {
        let mut inner = self.lock();
        for (_, c) in inner.clients.drain() {
            c.kill.notify_one();
        }
    }
}

/// Handles one request frame of client `id`: queues the reply and, for
/// `core.snapshot`, the snapshot event.
///
/// A snapshot must not be queued behind a patch that is newer than it (the
/// client would end on stale state), so it is retaken when a broadcast slipped
/// in between taking and queuing it.
pub fn handle_request(core: &ShellCore, hub: &Hub, id: u64, request: &str) {
    let wants_snapshot = serde_json::from_str::<Value>(request)
        .ok()
        .is_some_and(|v| v.get("m").and_then(Value::as_str) == Some("core.snapshot"));
    if !wants_snapshot {
        hub.send_to(id, vec![core.handle_json(request)], None);
        return;
    }
    const TRIES: u32 = 4;
    for attempt in 1..=TRIES {
        let seq = hub.seq();
        let reply = core.handle_json(request);
        let snapshot = serde_json::json!({ "t": "snapshot", "d": core.snapshot() }).to_string();
        let guard = (attempt < TRIES).then_some(seq);
        if hub.send_to(id, vec![reply, snapshot], guard) {
            return;
        }
    }
}

/// Whether a WebSocket handshake with this `Origin` header is accepted: only
/// non-browser clients (no header) and local files (`file://…`, `null`). A web
/// page open in the user's browser must not be able to drive their desktop.
#[must_use]
pub fn origin_allowed(origin: Option<&str>) -> bool {
    match origin.map(str::trim) {
        None => true,
        Some(o) => o.eq_ignore_ascii_case("null") || o.to_ascii_lowercase().starts_with("file://"),
    }
}

/// Resolves `--listen`. Non-loopback addresses are refused unless `allow_any`.
///
/// # Errors
/// A message for the user.
pub fn resolve_listen(listen: &str, allow_any: bool) -> Result<SocketAddr, String> {
    let addrs: Vec<SocketAddr> = listen
        .to_socket_addrs()
        .map_err(|e| format!("cannot resolve `{listen}`: {e}"))?
        .collect();
    let first = *addrs
        .first()
        .ok_or_else(|| format!("`{listen}` resolves to no address"))?;
    if !allow_any && addrs.iter().any(|a| !a.ip().is_loopback()) {
        return Err(format!(
            "`{listen}` is not a loopback address: anyone who can reach it could control this \
             desktop. Pass --i-know to listen there anyway."
        ));
    }
    Ok(first)
}

#[allow(clippy::result_large_err)] // the signature is tungstenite's
fn check_origin(request: &Request, response: Response) -> Result<Response, ErrorResponse> {
    let origin = request.headers().get("origin").map(|v| v.to_str().ok());
    let allowed = match origin {
        None => true,
        Some(None) => false,
        Some(Some(o)) => origin_allowed(Some(o)),
    };
    if allowed {
        return Ok(response);
    }
    tracing::warn!(?origin, "refused a connection from a web origin");
    let mut refusal = ErrorResponse::new(Some("origin not allowed".to_owned()));
    *refusal.status_mut() = StatusCode::FORBIDDEN;
    Err(refusal)
}

/// Removes the client from the hub when its connection task ends.
struct Unregister<'a>(&'a Hub, u64);

impl Drop for Unregister<'_> {
    fn drop(&mut self) {
        self.0.unregister(self.1);
    }
}

async fn connection(stream: TcpStream, peer: SocketAddr, core: Arc<ShellCore>, hub: Arc<Hub>) {
    let _ = stream.set_nodelay(true);
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_REQUEST_BYTES))
        .max_frame_size(Some(MAX_REQUEST_BYTES));
    let handshake =
        tokio_tungstenite::accept_hdr_async_with_config(stream, check_origin, Some(config));
    let ws = match tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake).await {
        Ok(Ok(ws)) => ws,
        Ok(Err(e)) => {
            tracing::debug!(%peer, %e, "handshake failed");
            return;
        }
        Err(_) => {
            tracing::debug!(%peer, "handshake timed out");
            return;
        }
    };
    let Registration {
        id,
        mut queue,
        kill,
    } = hub.register();
    let _unregister = Unregister(&hub, id);
    tracing::info!(%peer, client = id, "client connected");
    let (mut tx, mut rx) = ws.split();
    loop {
        tokio::select! {
            () = kill.notified() => {
                let _ = tokio::time::timeout(CLOSE_TIMEOUT, tx.close()).await;
                break;
            }
            Some(text) = queue.recv() => {
                // A stalled socket must not keep the task from seeing `kill`.
                let sent = tokio::select! {
                    r = tx.send(Message::Text(text)) => r.is_ok(),
                    () = kill.notified() => false,
                };
                if !sent {
                    break;
                }
            }
            frame = rx.next() => match frame {
                Some(Ok(Message::Text(text))) => handle_request(&core, &hub, id, text.as_str()),
                Some(Ok(Message::Close(_)) | Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }
    tracing::info!(%peer, client = id, "client disconnected");
}

/// Accepts clients on `listener` until `shutdown` completes, then closes every
/// connection and returns.
pub async fn serve(
    listener: TcpListener,
    core: Arc<ShellCore>,
    hub: Arc<Hub>,
    shutdown: impl Future<Output = ()>,
) {
    let mut tasks = JoinSet::new();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            () = &mut shutdown => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    tasks.spawn(connection(stream, peer, Arc::clone(&core), Arc::clone(&hub)));
                }
                Err(e) => {
                    tracing::warn!(%e, "accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            },
            Some(_) = tasks.join_next() => {}
        }
    }
    drop(listener);
    hub.close_all();
    let drained = tokio::time::timeout(Duration::from_secs(1), async {
        while tasks.join_next().await.is_some() {}
    });
    if drained.await.is_err() {
        tasks.shutdown().await;
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]
    use lugh_shell_core::services::{CallError, Service, StubService};

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
                "say" => Ok(args.first().cloned().unwrap_or(Value::Null)),
                other => Err(CallError::UnknownMethod(other.to_owned())),
            }
        }
    }

    fn core() -> ShellCore {
        ShellCore::with_services(vec![Box::new(Echo), Box::new(StubService("network"))])
    }

    fn next(reg: &mut Registration) -> Value {
        serde_json::from_str(reg.queue.try_recv().unwrap().as_str()).unwrap()
    }

    #[test]
    fn request_gets_one_reply() {
        let (core, hub) = (core(), Hub::new(8));
        let mut a = hub.register();
        let mut b = hub.register();
        handle_request(&core, &hub, a.id, r#"{"id":1,"m":"echo.say","a":["hi"]}"#);
        assert_eq!(next(&mut a), serde_json::json!({ "id": 1, "r": "hi" }));
        assert!(a.queue.try_recv().is_err());
        assert!(b.queue.try_recv().is_err(), "replies go to the caller only");

        handle_request(&core, &hub, a.id, r#"{"id":2,"m":"network.scan"}"#);
        assert!(next(&mut a)["e"].is_string());
        handle_request(&core, &hub, a.id, "not json");
        assert!(next(&mut a)["e"].is_string());
    }

    #[test]
    fn snapshot_request_gets_reply_then_snapshot_event() {
        let (core, hub) = (core(), Hub::new(8));
        let mut a = hub.register();
        handle_request(&core, &hub, a.id, r#"{"id":3,"m":"core.snapshot","a":[]}"#);
        let reply = next(&mut a);
        assert_eq!(reply["id"], 3);
        assert_eq!(reply["r"]["echo"]["ready"], true);
        let snap = next(&mut a);
        assert_eq!(snap["t"], "snapshot");
        assert_eq!(
            snap["d"],
            serde_json::json!({ "echo": { "ready": true }, "network": {} })
        );
        assert!(a.queue.try_recv().is_err());
    }

    #[test]
    fn events_reach_every_client_in_order() {
        let hub = Arc::new(Hub::new(8));
        let sink = hub.sink(false);
        let mut a = hub.register();
        let mut b = hub.register();
        sink.patch("audio", serde_json::json!({ "volume": 0.5 }));
        sink.signal("session", "unlocked", vec![]);
        for reg in [&mut a, &mut b] {
            assert_eq!(
                next(reg),
                serde_json::json!({ "t": "patch", "s": "audio", "d": { "volume": 0.5 } })
            );
            assert_eq!(next(reg)["n"], "unlocked");
        }
        assert_eq!(hub.seq(), 2);
    }

    #[test]
    fn slow_client_is_dropped_and_others_keep_going() {
        let hub = Hub::new(2);
        let slow = hub.register();
        let mut ok = hub.register();
        for i in 0..5 {
            hub.broadcast(format!("{i}"));
            let _ = ok.queue.try_recv().unwrap();
        }
        assert_eq!(hub.client_count(), 1);
        // The kill permit is stored, so the connection task sees it.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        rt.block_on(async {
            tokio::time::timeout(Duration::from_secs(1), slow.kill.notified())
                .await
                .unwrap();
        });
        // Replies overflow the same way.
        let core = core();
        let lazy = hub.register();
        for _ in 0..3 {
            handle_request(&core, &hub, lazy.id, r#"{"m":"echo.say","a":[1]}"#);
        }
        assert_eq!(hub.client_count(), 1);
        hub.unregister(ok.id);
        assert_eq!(hub.client_count(), 0);
    }

    #[test]
    fn stale_snapshot_is_not_queued() {
        let hub = Hub::new(8);
        let mut a = hub.register();
        let seq = hub.seq();
        hub.broadcast("{\"t\":\"patch\"}");
        assert!(!hub.send_to(a.id, vec!["snap".to_owned()], Some(seq)));
        assert!(hub.send_to(a.id, vec!["snap".to_owned()], Some(hub.seq())));
        assert_eq!(a.queue.try_recv().unwrap().as_str(), "{\"t\":\"patch\"}");
        assert_eq!(a.queue.try_recv().unwrap().as_str(), "snap");
    }

    #[test]
    fn origins() {
        assert!(origin_allowed(None));
        assert!(origin_allowed(Some("null")));
        assert!(origin_allowed(Some("file://")));
        assert!(origin_allowed(Some("file:///home/x/a.html")));
        assert!(!origin_allowed(Some("http://localhost:3000")));
        assert!(!origin_allowed(Some("https://evil.example")));
        assert!(!origin_allowed(Some("")));
    }

    #[test]
    fn listen_addresses() {
        assert!(resolve_listen("127.0.0.1:7777", false).is_ok());
        assert!(resolve_listen("[::1]:7777", false).is_ok());
        assert!(resolve_listen("0.0.0.0:7777", false).is_err());
        assert!(resolve_listen("192.0.2.1:7777", false).is_err());
        assert!(resolve_listen("192.0.2.1:7777", true).is_ok());
        assert!(resolve_listen("nonsense", false).is_err());
    }
}
