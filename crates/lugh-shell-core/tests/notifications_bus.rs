//! `notifications` and `shell` on a private session bus: a real
//! `dbus-daemon`, the two services on their own connections and a zbus client
//! playing the apps and the compositor's key binds.
//!
//! Skipped (passes with a note) when `dbus-daemon` is not installed.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use futures_util::StreamExt;
use lugh_shell_core::config::DesktopConfig;
use lugh_shell_core::services::{Context, Event, Sink, notifications, shell};
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};
use zbus::zvariant::Value as ZValue;

const N_NAME: &str = "org.freedesktop.Notifications";
const N_PATH: &str = "/org/freedesktop/Notifications";
const S_NAME: &str = "space.lugh.Shell1";
const S_PATH: &str = "/space/lugh/Shell1";
const WAIT: Duration = Duration::from_secs(5);

struct Bus {
    child: Child,
    address: String,
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn private_bus() -> Option<Bus> {
    let mut child = Command::new("dbus-daemon")
        .args(["--session", "--print-address", "--nofork"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut address = String::new();
    let read = child
        .stdout
        .take()
        .map(|out| BufReader::new(out).read_line(&mut address));
    let address = address.trim().to_owned();
    let bus = Bus { child, address };
    (matches!(read, Some(Ok(n)) if n > 0) && !bus.address.is_empty()).then_some(bus)
}

async fn connect(address: &str) -> zbus::Connection {
    zbus::connection::Builder::address(address)
        .expect("bus address")
        .build()
        .await
        .expect("connect to the private bus")
}

fn context() -> (Context, UnboundedReceiver<Value>) {
    let (tx, rx) = unbounded_channel();
    let ctx = Context {
        sink: Sink::new(move |e: Event| {
            let _ = tx.send(e.to_json());
        }),
        runtime: tokio::runtime::Handle::current(),
        config: Arc::new(RwLock::new(DesktopConfig::default())),
    };
    (ctx, rx)
}

async fn next(rx: &mut UnboundedReceiver<Value>) -> Value {
    tokio::time::timeout(WAIT, rx.recv())
        .await
        .expect("an event within 5 s")
        .expect("sink open")
}

async fn wait_for_name(client: &zbus::Connection, name: &'static str) {
    let dbus = zbus::fdo::DBusProxy::new(client).await.expect("dbus proxy");
    let bus_name = zbus::names::BusName::try_from(name).expect("bus name");
    for _ in 0..250 {
        if dbus.name_has_owner(bus_name.clone()).await.unwrap_or(false) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{name} never appeared on the bus");
}

async fn signals(client: &zbus::Connection, interface: &'static str) -> zbus::MessageStream {
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface(interface)
        .expect("interface")
        .build();
    zbus::MessageStream::for_match_rule(rule, client, Some(16))
        .await
        .expect("match rule")
}

async fn next_signal(stream: &mut zbus::MessageStream) -> zbus::Message {
    tokio::time::timeout(WAIT, stream.next())
        .await
        .expect("a bus signal within 5 s")
        .expect("stream open")
        .expect("valid message")
}

#[allow(clippy::too_many_arguments)]
async fn notify(
    client: &zbus::Connection,
    app: &str,
    replaces: u32,
    icon: &str,
    summary: &str,
    body: &str,
    actions: &[&str],
    hints: HashMap<&str, ZValue<'_>>,
) -> u32 {
    client
        .call_method(
            Some(N_NAME),
            N_PATH,
            Some(N_NAME),
            "Notify",
            &(app, replaces, icon, summary, body, actions, hints, -1i32),
        )
        .await
        .expect("Notify")
        .body()
        .deserialize::<u32>()
        .expect("notification id")
}

async fn shell_call<B>(client: &zbus::Connection, method: &str, body: &B)
where
    B: serde::Serialize + zbus::zvariant::DynamicType,
{
    client
        .call_method(Some(S_NAME), S_PATH, Some(S_NAME), method, body)
        .await
        .unwrap_or_else(|e| panic!("{method}: {e}"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn notifications_and_shell_on_a_private_bus() {
    let Some(bus) = private_bus() else {
        eprintln!("skipped: dbus-daemon is not installed");
        return;
    };
    let client = connect(&bus.address).await;

    // ---- notifications ---------------------------------------------------
    let (ctx, mut events) = context();
    let notes = notifications::start_on(&ctx, connect(&bus.address).await);
    wait_for_name(&client, N_NAME).await;
    let mut n_signals = signals(&client, N_NAME).await;

    let info = client
        .call_method(
            Some(N_NAME),
            N_PATH,
            Some(N_NAME),
            "GetServerInformation",
            &(),
        )
        .await
        .expect("GetServerInformation");
    let (name, vendor, _version, spec): (String, String, String, String) =
        info.body().deserialize().expect("server information");
    assert_eq!(
        (name.as_str(), vendor.as_str(), spec.as_str()),
        ("lugh-shell", "Lugh", "1.2")
    );
    let caps = client
        .call_method(Some(N_NAME), N_PATH, Some(N_NAME), "GetCapabilities", &())
        .await
        .expect("GetCapabilities");
    let caps: Vec<String> = caps.body().deserialize().expect("capabilities");
    assert_eq!(
        caps,
        [
            "body",
            "body-markup",
            "actions",
            "icon-static",
            "persistence"
        ]
    );

    // Notify: toast + history row, typed like the QML mock.
    let mut hints = HashMap::new();
    hints.insert("urgency", ZValue::U8(2));
    hints.insert("desktop-entry", ZValue::from("org.mozilla.firefox"));
    hints.insert("image-path", ZValue::from("/tmp/shot.png"));
    let id = notify(
        &client,
        "Firefox",
        0,
        "",
        "Download\u{7} complete",
        "From <b>Lugh</b>",
        &["default", "Open", "folder", "Show in folder"],
        hints,
    )
    .await;
    assert_eq!(id, 1);
    let patch = next(&mut events).await;
    assert_eq!(
        (&patch["t"], &patch["s"]),
        (&json!("patch"), &json!("notifications"))
    );
    let row = &patch["d"]["popups"][0];
    assert_eq!(row["nid"], 1);
    assert_eq!(row["appName"], "Firefox");
    assert_eq!(row["appIcon"], "org.mozilla.firefox");
    assert_eq!(row["summary"], "Download complete");
    assert_eq!(row["body"], "From <b>Lugh</b>");
    assert_eq!(row["urgency"], 2);
    assert_eq!(row["image"], "file:///tmp/shot.png");
    assert_eq!(
        row["actions"],
        "[{\"key\":\"default\",\"label\":\"Open\"},{\"key\":\"folder\",\"label\":\"Show in folder\"}]"
    );
    assert!(row["time"].as_u64().is_some_and(|t| t > 1_600_000_000_000));
    assert_eq!(patch["d"]["history"][0], *row);

    // A second one, then replace the first in place.
    let second = notify(&client, "Chat", 0, "chat", "Hi", "", &[], HashMap::new()).await;
    assert_eq!(second, 2);
    next(&mut events).await;
    let same = notify(
        &client,
        "Firefox",
        id,
        "firefox",
        "Done",
        "",
        &[],
        HashMap::new(),
    )
    .await;
    assert_eq!(same, id);
    let patch = next(&mut events).await;
    let history = patch["d"]["history"].as_array().expect("history");
    assert_eq!(history.len(), 2);
    assert_eq!(
        (&history[0]["nid"], &history[1]["nid"]),
        (&json!(2), &json!(1))
    );
    assert_eq!(history[1]["summary"], "Done");
    assert_eq!(history[1]["urgency"], 1);
    assert_eq!(patch["d"]["popups"][1]["summary"], "Done");

    // Transient: toast only.
    let mut hints = HashMap::new();
    hints.insert("transient", ZValue::Bool(true));
    let transient = notify(&client, "Player", 0, "", "Next track", "", &[], hints).await;
    let patch = next(&mut events).await;
    assert_eq!(patch["d"]["popups"][0]["nid"], transient);
    assert!(patch["d"].get("history").is_none());
    // Its toast expires: closed with reason 1.
    notes.call("expire", &[json!(transient)]).expect("expire");
    next(&mut events).await;
    let closed = next_signal(&mut n_signals).await;
    assert_eq!(
        closed
            .header()
            .member()
            .map(|m| m.as_str().to_owned())
            .as_deref(),
        Some("NotificationClosed")
    );
    assert_eq!(
        closed.body().deserialize::<(u32, u32)>().expect("closed"),
        (transient, 1)
    );

    // The user picks an action: ActionInvoked, then NotificationClosed(2).
    notes
        .call("invokeAction", &[json!(second), json!("default")])
        .expect("invokeAction");
    let signal = next(&mut events).await;
    assert_eq!(
        signal,
        json!({ "t": "signal", "s": "notifications", "n": "actionInvoked", "a": [2, "default"] })
    );
    let patch = next(&mut events).await;
    assert_eq!(patch["d"]["history"].as_array().map(Vec::len), Some(1));
    let invoked = next_signal(&mut n_signals).await;
    assert_eq!(
        invoked
            .body()
            .deserialize::<(u32, String)>()
            .expect("action"),
        (second, "default".to_owned())
    );
    let closed = next_signal(&mut n_signals).await;
    assert_eq!(
        closed.body().deserialize::<(u32, u32)>().expect("closed"),
        (second, 2)
    );

    // CloseNotification: gone everywhere, reason 3.
    client
        .call_method(
            Some(N_NAME),
            N_PATH,
            Some(N_NAME),
            "CloseNotification",
            &(id,),
        )
        .await
        .expect("CloseNotification");
    let patch = next(&mut events).await;
    assert_eq!(patch["d"], json!({ "popups": [], "history": [] }));
    let closed = next_signal(&mut n_signals).await;
    assert_eq!(
        closed.body().deserialize::<(u32, u32)>().expect("closed"),
        (id, 3)
    );
    assert_eq!(notes.state()["history"], json!([]));

    // ---- shell -----------------------------------------------------------
    let (ctx, mut events) = context();
    let sh = shell::start_on(&ctx, connect(&bus.address).await);
    wait_for_name(&client, S_NAME).await;
    assert_eq!(sh.state()["primary"], true);
    assert_eq!(sh.state()["lowPower"], false);
    assert!(sh.state()["version"].is_string());
    let mut s_signals = signals(&client, S_NAME).await;

    let sig = |n: &str, a: Value| json!({ "t": "signal", "s": "shell", "n": n, "a": a });
    shell_call(&client, "ShowLauncher", &("Tasks",)).await;
    assert_eq!(
        next(&mut events).await,
        sig("showLauncher", json!(["Tasks"]))
    );
    shell_call(&client, "ShowStartMenu", &()).await;
    assert_eq!(next(&mut events).await, sig("showLauncher", json!([""])));
    for (method, name) in [
        ("ToggleLauncher", "toggleLauncher"),
        ("ToggleControlCenter", "toggleControlCenter"),
        ("ToggleNotificationCenter", "toggleNotificationCenter"),
        ("ToggleLughMenu", "toggleLughMenu"),
        ("CloseAll", "closeAll"),
        ("Lock", "lockRequested"),
    ] {
        shell_call(&client, method, &()).await;
        assert_eq!(next(&mut events).await, sig(name, json!([])), "{method}");
    }
    shell_call(&client, "ShowOverview", &()).await; // accepted, no event

    for (kind, value, want) in [
        ("volume", 0.4, json!(["volume", 0.4])),
        ("volume-muted", 0.4, json!(["volume", 0.0])),
        ("microphone", 1.0, json!(["mic", 1.0])),
        ("kbd-brightness", 0.5, json!(["brightness", 0.5])),
        ("caps-lock", 1.0, json!(["caps", 1.0])),
    ] {
        shell_call(&client, "ShowOSD", &(kind, value)).await;
        assert_eq!(
            next(&mut events).await,
            json!({ "t": "signal", "s": "osd", "n": "requested", "a": want }),
            "{kind}"
        );
    }
    shell_call(&client, "ShowOSD", &("disco", 1.0)).await; // unknown kind: dropped

    shell_call(&client, "SetLowPower", &(true,)).await;
    assert_eq!(
        next(&mut events).await,
        json!({ "t": "patch", "s": "shell", "d": { "lowPower": true } })
    );
    sh.call("setLowPower", &[json!(true)]).expect("setLowPower"); // unchanged: no patch
    sh.call("setLowPower", &[json!(false)])
        .expect("setLowPower");
    assert_eq!(next(&mut events).await["d"], json!({ "lowPower": false }));

    sh.call("ready", &[]).expect("ready");
    sh.call("ready", &[]).expect("ready"); // once only
    sh.call("modeApplied", &[json!("classic")])
        .expect("modeApplied");
    let ready = next_signal(&mut s_signals).await;
    assert_eq!(
        ready
            .header()
            .member()
            .map(|m| m.as_str().to_owned())
            .as_deref(),
        Some("Ready")
    );
    let mode = next_signal(&mut s_signals).await;
    assert_eq!(
        mode.body().deserialize::<String>().expect("mode"),
        "classic"
    );

    // A second shell on the same bus is not primary and does not take over.
    let (ctx2, mut events2) = context();
    let second_shell = shell::start_on(&ctx2, connect(&bus.address).await);
    assert_eq!(
        next(&mut events2).await,
        json!({ "t": "patch", "s": "shell", "d": { "primary": false } })
    );
    assert_eq!(second_shell.state()["primary"], false);
    assert_eq!(sh.state()["primary"], true);

    // A second notification server queues instead of stealing the name, and
    // takes over when the first one goes away.
    let (ctx3, mut events3) = context();
    let standby_conn = connect(&bus.address).await;
    let standby_name = standby_conn.unique_name().map(ToString::to_string);
    let standby = notifications::start_on(&ctx3, standby_conn);
    let dbus = zbus::fdo::DBusProxy::new(&client)
        .await
        .expect("dbus proxy");
    let owner_of = || async {
        dbus.get_name_owner(zbus::names::BusName::try_from(N_NAME).expect("name"))
            .await
            .ok()
            .map(|o| o.to_string())
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_ne!(owner_of().await, standby_name, "the name was not stolen");
    drop(notes); // the first server ends: its connection closes
    let mut taken = false;
    for _ in 0..250 {
        if owner_of().await == standby_name {
            taken = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(taken, "the standby server took the released name");
    let id = notify(
        &client,
        "Late",
        0,
        "",
        "Hello again",
        "",
        &[],
        HashMap::new(),
    )
    .await;
    assert_eq!(next(&mut events3).await["d"]["popups"][0]["nid"], id);
    assert_eq!(standby.state()["history"][0]["summary"], "Hello again");
}
