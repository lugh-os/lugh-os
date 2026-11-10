//! End to end: the server on an ephemeral port, real WebSocket clients.
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use lugh_shell_core::services::{CallError, Service, ShellCore, StubService};
use lugh_shell_devd::{Hub, serve};
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

type Client = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[derive(Debug)]
struct Echo;
impl Service for Echo {
    fn name(&self) -> &'static str {
        "echo"
    }
    fn state(&self) -> Value {
        json!({ "ready": true })
    }
    fn call(&self, method: &str, args: &[Value]) -> Result<Value, CallError> {
        match method {
            "say" => Ok(args.first().cloned().unwrap_or(Value::Null)),
            other => Err(CallError::UnknownMethod(other.to_owned())),
        }
    }
}

struct Server {
    url: String,
    hub: Arc<Hub>,
    stop: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

async fn start(queue: usize) -> Server {
    let core = Arc::new(ShellCore::with_services(vec![
        Box::new(Echo),
        Box::new(StubService("network")),
    ]));
    let hub = Arc::new(Hub::new(queue));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let (stop, stopped) = oneshot::channel::<()>();
    let task = tokio::spawn(serve(listener, core, Arc::clone(&hub), async {
        let _ = stopped.await;
    }));
    Server {
        url,
        hub,
        stop,
        task,
    }
}

async fn recv(ws: &mut Client) -> Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("a frame within 5 s")
            .expect("an open connection")
            .unwrap();
        if let Message::Text(t) = frame {
            return serde_json::from_str(t.as_str()).unwrap();
        }
    }
}

async fn wait_clients(hub: &Hub, n: usize) {
    for _ in 0..500 {
        if hub.client_count() == n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("expected {n} clients, have {}", hub.client_count());
}

#[tokio::test]
async fn calls_snapshot_and_broadcast() {
    let server = start(64).await;
    let (mut a, _) = connect_async(&server.url).await.unwrap();
    let (mut b, _) = connect_async(&server.url).await.unwrap();
    wait_clients(&server.hub, 2).await;

    a.send(Message::text(r#"{"id":1,"m":"echo.say","a":["hi"]}"#))
        .await
        .unwrap();
    assert_eq!(recv(&mut a).await, json!({ "id": 1, "r": "hi" }));

    a.send(Message::text(r#"{"id":2,"m":"nope.x"}"#))
        .await
        .unwrap();
    let reply = recv(&mut a).await;
    assert_eq!(reply["id"], 2);
    assert!(reply["e"].is_string());

    a.send(Message::text(r#"{"m":"core.snapshot","a":[]}"#))
        .await
        .unwrap();
    assert_eq!(recv(&mut a).await["r"]["echo"]["ready"], true);
    assert_eq!(
        recv(&mut a).await,
        json!({ "t": "snapshot", "d": { "echo": { "ready": true }, "network": {} } })
    );

    // Events reach both clients; b saw none of a's replies.
    let sink = server.hub.sink(false);
    sink.patch("audio", json!({ "volume": 0.25 }));
    sink.signal("session", "unlocked", vec![]);
    for ws in [&mut a, &mut b] {
        assert_eq!(
            recv(ws).await,
            json!({ "t": "patch", "s": "audio", "d": { "volume": 0.25 } })
        );
        assert_eq!(
            recv(ws).await,
            json!({ "t": "signal", "s": "session", "n": "unlocked", "a": [] })
        );
    }

    // A client that leaves is forgotten.
    b.close(None).await.unwrap();
    wait_clients(&server.hub, 1).await;

    // Shutdown closes the remaining client and ends the server.
    server.stop.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(5), server.task)
        .await
        .expect("the server stops")
        .unwrap();
    let end = tokio::time::timeout(Duration::from_secs(5), a.next())
        .await
        .expect("the connection ends");
    assert!(matches!(end, None | Some(Ok(Message::Close(_)) | Err(_))));
    assert_eq!(server.hub.client_count(), 0);
}

#[tokio::test]
async fn web_origins_are_refused() {
    let server = start(64).await;
    for origin in ["http://localhost:3000", "https://evil.example"] {
        let mut request = server.url.as_str().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Origin", origin.parse().unwrap());
        match connect_async(request).await {
            Err(Error::Http(response)) => assert_eq!(response.status().as_u16(), 403),
            other => panic!("{origin} must be refused, got {other:?}"),
        }
    }
    let mut open: Vec<Client> = Vec::new();
    for origin in ["null", "file://"] {
        let mut request = server.url.as_str().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Origin", origin.parse().unwrap());
        let (mut ws, _) = connect_async(request).await.unwrap();
        ws.send(Message::text(r#"{"id":1,"m":"echo.say","a":[1]}"#))
            .await
            .unwrap();
        assert_eq!(recv(&mut ws).await, json!({ "id": 1, "r": 1 }));
        open.push(ws);
    }
    assert_eq!(
        server.hub.client_count(),
        open.len(),
        "refused clients never register"
    );
}

#[tokio::test]
async fn slow_client_is_disconnected_without_stalling_the_rest() {
    let server = start(4).await;
    let (mut slow, _) = connect_async(&server.url).await.unwrap();
    wait_clients(&server.hub, 1).await;
    // The test runtime is single-threaded: the server cannot drain the queue
    // between these broadcasts, exactly like a client that stopped reading.
    for i in 0..10 {
        server.hub.broadcast(format!(r#"{{"t":"patch","i":{i}}}"#));
    }
    assert_eq!(server.hub.client_count(), 0, "dropped at once");

    // Its socket is closed after at most the frames that were queued.
    let mut frames = 0;
    loop {
        let next = tokio::time::timeout(Duration::from_secs(5), slow.next())
            .await
            .expect("the connection ends");
        match next {
            Some(Ok(Message::Text(_))) => frames += 1,
            None | Some(Ok(Message::Close(_)) | Err(_)) => break,
            Some(Ok(_)) => {}
        }
    }
    assert!(frames <= 4, "got {frames} frames");

    // The server still works for a new client.
    let (mut ok, _) = connect_async(&server.url).await.unwrap();
    ok.send(Message::text(
        r#"{"id":9,"m":"echo.say","a":["still here"]}"#,
    ))
    .await
    .unwrap();
    assert_eq!(recv(&mut ok).await, json!({ "id": 9, "r": "still here" }));
}

#[tokio::test]
async fn garbage_does_not_kill_the_connection() {
    let server = start(64).await;
    let (mut ws, _) = connect_async(&server.url).await.unwrap();
    ws.send(Message::text("{")).await.unwrap();
    assert!(recv(&mut ws).await["e"].is_string());
    ws.send(Message::binary(vec![1, 2, 3])).await.unwrap();
    ws.send(Message::text(r#"{"id":1,"m":"echo.say","a":[true]}"#))
        .await
        .unwrap();
    assert_eq!(recv(&mut ws).await, json!({ "id": 1, "r": true }));
}
