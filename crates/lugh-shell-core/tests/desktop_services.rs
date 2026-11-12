//! End-to-end test of the `wm`, `apps` and `launcher` services against a
//! fake Hyprland (request + event sockets in a temporary directory), a
//! temporary app directory and no systemd.

#![allow(clippy::unwrap_used)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use lugh_shell_core::config::DesktopConfig;
use lugh_shell_core::launch::NoScopes;
use lugh_shell_core::launcher::{AppIndex, History, Launcher, Locale};
use lugh_shell_core::services::wm::{DesktopParts, start_desktop};
use lugh_shell_core::services::{CallError, Context, Service, Sink};
use lugh_shell_core::wm::CompositorAdapter;
use lugh_shell_core::wm::hyprland::{EVENT_SOCKET, HyprlandAdapter, REQUEST_SOCKET};
use serde_json::{Value, json};

const WAIT: Duration = Duration::from_secs(5);

enum EventCmd {
    Line(String),
    /// Close the event connection and accept the next one.
    Drop,
}

/// A Hyprland whose `j/…` answers the test can change.
struct Fake {
    dir: tempfile::TempDir,
    replies: Arc<Mutex<HashMap<&'static str, String>>>,
    requests: Arc<Mutex<Vec<String>>>,
    events: Sender<EventCmd>,
}

fn client(addr: &str, class: &str, title: &str, ws: (i64, &str), rect: [i32; 4]) -> Value {
    json!({
        "address": addr, "mapped": true, "hidden": false,
        "at": [rect[0], rect[1]], "size": [rect[2], rect[3]],
        "workspace": { "id": ws.0, "name": ws.1 },
        "floating": true, "fullscreen": 0, "pid": 100,
        "class": class, "title": title, "initialClass": class, "initialTitle": title,
    })
}

fn workspace(id: i64, name: &str, windows: u32) -> Value {
    json!({ "id": id, "name": name, "monitor": "eDP-1", "windows": windows })
}

impl Fake {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let replies: Arc<Mutex<HashMap<&'static str, String>>> = Arc::default();
        let requests: Arc<Mutex<Vec<String>>> = Arc::default();

        let listener = UnixListener::bind(dir.path().join(REQUEST_SOCKET)).unwrap();
        let (answers, log) = (Arc::clone(&replies), Arc::clone(&requests));
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut buf = [0u8; 8192];
                let n = stream.read(&mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).into_owned();
                let reply = answers
                    .lock()
                    .unwrap()
                    .get(request.as_str())
                    .cloned()
                    .unwrap_or_else(|| "ok".into());
                if !request.starts_with("j/") {
                    log.lock().unwrap().push(request);
                }
                let _ = stream.write_all(reply.as_bytes());
            }
        });

        let ev_listener = UnixListener::bind(dir.path().join(EVENT_SOCKET)).unwrap();
        let (tx, rx) = mpsc::channel::<EventCmd>();
        std::thread::spawn(move || {
            let Ok((mut conn, _)) = ev_listener.accept() else {
                return;
            };
            for cmd in rx {
                match cmd {
                    EventCmd::Line(line) => {
                        let _ = conn.write_all(line.as_bytes());
                    }
                    EventCmd::Drop => {
                        drop(conn);
                        let Ok((next, _)) = ev_listener.accept() else {
                            return;
                        };
                        conn = next;
                    }
                }
            }
        });

        let fake = Self {
            dir,
            replies,
            requests,
            events: tx,
        };
        fake.set(
            "j/monitors",
            json!([{ "id": 0, "name": "eDP-1", "description": "", "width": 1920, "height": 1080,
                     "x": 0, "y": 0, "scale": 1.0, "transform": 0, "focused": true,
                     "activeWorkspace": { "id": 1, "name": "1" } }]),
        );
        fake.set("j/activeworkspace", json!({ "id": 1, "name": "1" }));
        fake
    }

    fn set(&self, request: &'static str, reply: Value) {
        self.replies
            .lock()
            .unwrap()
            .insert(request, reply.to_string());
    }

    fn send(&self, line: &str) {
        self.events.send(EventCmd::Line(line.to_owned())).unwrap();
    }

    fn take_requests(&self) -> Vec<String> {
        std::mem::take(&mut *self.requests.lock().unwrap())
    }

    /// Waits until `n` non-query requests arrived, then returns them.
    fn requests(&self, n: usize) -> Vec<String> {
        let deadline = Instant::now() + WAIT;
        while self.requests.lock().unwrap().len() < n && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        self.take_requests()
    }
}

/// Everything the services sent, with helpers to wait for a patch.
#[derive(Clone, Default)]
struct Seen(Arc<Mutex<Vec<Value>>>);

impl Seen {
    fn sink(&self) -> Sink {
        let log = Arc::clone(&self.0);
        Sink::new(move |e| log.lock().unwrap().push(e.to_json()))
    }

    fn all(&self) -> Vec<Value> {
        self.0.lock().unwrap().clone()
    }

    fn clear(&self) {
        self.0.lock().unwrap().clear();
    }

    /// Waits for an event matching `pred` and returns it.
    fn wait(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(e) = self.all().into_iter().find(|e| pred(e)) {
                return e;
            }
            assert!(
                Instant::now() < deadline,
                "no {what}; got {:#?}",
                self.all()
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Waits for a patch of `service` that carries `key`.
    fn patch(&self, service: &str, key: &str) -> Value {
        self.wait(&format!("{service} patch with {key}"), |e| {
            e["t"] == "patch" && e["s"] == service && !e["d"][key].is_null()
        })["d"]
            .clone()
    }
}

fn write_app(dir: &Path, id: &str, name: &str, exec: &str, extra: &str) {
    let text =
        format!("[Desktop Entry]\nType=Application\nName={name}\nExec={exec}\nIcon={id}\n{extra}");
    std::fs::write(dir.join(format!("{id}.desktop")), text).unwrap();
}

struct Rig {
    seen: Seen,
    services: Vec<Box<dyn Service>>,
    _apps: tempfile::TempDir,
    _runtime: tokio::runtime::Runtime,
}

impl Rig {
    fn start(adapter: Option<Arc<dyn CompositorAdapter>>) -> Self {
        let apps = tempfile::tempdir().unwrap();
        let dir = apps.path().join("applications");
        std::fs::create_dir_all(&dir).unwrap();
        write_app(
            &dir,
            "firefox",
            "Firefox",
            "firefox %u",
            "GenericName=Web Browser\nKeywords=internet;web;\n",
        );
        write_app(&dir, "org.codeberg.dnkl.foot", "Terminal", "foot", "");
        write_app(&dir, "vlc", "VLC", "vlc %U", "");
        write_app(&dir, "quick", "Quick", "/bin/true", "");
        write_app(
            &dir,
            "broken",
            "Broken",
            "/nonexistent/lugh-test-binary",
            "",
        );
        write_app(&dir, "hidden", "Hidden", "/bin/true", "NoDisplay=true\n");
        let index = AppIndex::new(vec![dir], Locale::untranslated(), vec!["Lugh".into()]);
        let launcher = Launcher::new(index, History::in_memory());

        let mut config = DesktopConfig::default();
        config.dock.pinned = ["firefox", "not-installed", "org.codeberg.dnkl.foot"]
            .map(String::from)
            .to_vec();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap();
        let seen = Seen::default();
        let ctx = Context {
            sink: seen.sink(),
            runtime: runtime.handle().clone(),
            config: Arc::new(RwLock::new(config)),
        };
        let services = start_desktop(
            &ctx,
            DesktopParts {
                adapter,
                launcher,
                scopes: Arc::new(NoScopes),
            },
        );
        Self {
            seen,
            services,
            _apps: apps,
            _runtime: runtime,
        }
    }

    fn svc(&self, name: &str) -> &dyn Service {
        self.services
            .iter()
            .find(|s| s.name() == name)
            .unwrap()
            .as_ref()
    }

    fn call(&self, target: &str, args: Value) -> Result<Value, CallError> {
        let (service, method) = target.split_once('.').unwrap();
        self.svc(service).call(method, args.as_array().unwrap())
    }
}

fn ids(rows: &Value, key: &str) -> Vec<String> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|r| r[key].as_str().unwrap().to_owned())
        .collect()
}

fn row<'a>(rows: &'a Value, key: &str, id: &str) -> &'a Value {
    rows.as_array()
        .unwrap()
        .iter()
        .find(|r| r[key] == id)
        .unwrap_or_else(|| panic!("no row {id} in {rows}"))
}

#[test]
fn wm_apps_and_launcher_end_to_end() {
    let fake = Fake::start();
    let firefox = client(
        "0xa1",
        "firefox",
        "Lugh — Mozilla Firefox",
        (1, "1"),
        [100, 60, 900, 700],
    );
    let foot = client(
        "0xb2",
        "foot",
        "amara@lugh: ~",
        (1, "1"),
        [300, 200, 700, 400],
    );
    fake.set("j/clients", json!([firefox, foot]));
    fake.set(
        "j/workspaces",
        json!([workspace(1, "1", 2), workspace(2, "2", 0)]),
    );
    fake.set("j/activewindow", firefox.clone());

    let adapter = HyprlandAdapter::with_socket_dir(fake.dir.path());
    let rig = Rig::start(Some(Arc::new(adapter)));

    // ---- first state ------------------------------------------------------
    let first = rig.seen.patch("wm", "available");
    assert_eq!(first["available"], true);
    assert_eq!(
        first["workspaces"],
        json!([
            { "wsId": 1, "name": "1", "occupied": true },
            { "wsId": 2, "name": "2", "occupied": false },
            { "wsId": 3, "name": "3", "occupied": false },
            { "wsId": 4, "name": "4", "occupied": false },
        ])
    );
    assert_eq!(first["focusedAppId"], "firefox");
    assert_eq!(first["focusedAppName"], "Firefox");
    assert_eq!(first["focusedTitle"], "Lugh — Mozilla Firefox");
    assert_eq!(
        first["toplevels"],
        json!([
            { "winId": "0xa1", "appId": "firefox", "title": "Lugh — Mozilla Firefox",
              "workspace": 1, "focused": true,
              "x": 100, "y": 60, "width": 900, "height": 700,
              "monitorWidth": 1920, "monitorHeight": 1080, "monitor": "eDP-1" },
            // The class `foot` is matched to its reverse-DNS desktop id.
            { "winId": "0xb2", "appId": "org.codeberg.dnkl.foot", "title": "amara@lugh: ~",
              "workspace": 1, "focused": false,
              "x": 300, "y": 200, "width": 700, "height": 400,
              "monitorWidth": 1920, "monitorHeight": 1080, "monitor": "eDP-1" },
        ])
    );
    assert_eq!(first["activeOutput"], "eDP-1");
    // activeWorkspace 1 and dockOverlapped false equal the defaults: not sent.
    assert!(first.get("activeWorkspace").is_none() && first.get("dockOverlapped").is_none());

    let dock = rig.seen.patch("apps", "dock")["dock"].clone();
    assert_eq!(
        dock,
        json!([
            { "appId": "firefox", "name": "Firefox", "icon": "firefox", "pinned": true,
              "running": true, "windows": 1, "launching": false, "attention": false },
            { "appId": "org.codeberg.dnkl.foot", "name": "Terminal",
              "icon": "org.codeberg.dnkl.foot", "pinned": true, "running": true, "windows": 1,
              "launching": false, "attention": false },
        ])
    );

    let state = rig.svc("wm").state();
    assert_eq!(state["activeWorkspace"], 1);
    assert_eq!(state["dockOverlapped"], false);
    assert_eq!(state["toplevels"], first["toplevels"]);
    let apps = rig.svc("apps").state();
    assert_eq!(apps["dock"], dock);
    // Visible apps only, sorted by name.
    assert_eq!(
        ids(&apps["installed"], "name"),
        ["Broken", "Firefox", "Quick", "Terminal", "VLC"]
    );
    assert_eq!(
        row(&apps["installed"], "appId", "firefox"),
        &json!({ "appId": "firefox", "name": "Firefox", "genericName": "Web Browser",
                 "icon": "firefox", "keywords": "internet web" })
    );
    let launcher = rig.svc("launcher").state();
    assert_eq!(
        launcher,
        json!({ "query": "", "searching": false, "results": [], "recent": [] })
    );

    // ---- a window opens, reaching into the dock's strip -------------------
    rig.seen.clear();
    let vlc = client(
        "0xc3",
        "vlc",
        "Big Buck Bunny",
        (1, "1"),
        [200, 500, 800, 560],
    );
    fake.set("j/clients", json!([firefox, foot, vlc]));
    fake.set(
        "j/workspaces",
        json!([workspace(1, "1", 3), workspace(2, "2", 0)]),
    );
    fake.set("j/activewindow", vlc.clone());
    fake.send("openwindow>>c3,1,vlc,Big Buck Bunny\nactivewindow>>vlc,Big Buck Bunny\nactivewindowv2>>c3\n");
    let dock = rig.seen.patch("apps", "dock")["dock"].clone();
    assert_eq!(
        ids(&dock, "appId"),
        ["firefox", "org.codeberg.dnkl.foot", "vlc"]
    );
    assert_eq!(row(&dock, "appId", "vlc")["pinned"], false);
    let focus = rig.seen.patch("wm", "focusedAppId");
    assert_eq!(focus["focusedAppName"], "VLC");
    assert_eq!(focus["toplevels"].as_array().unwrap().len(), 3);
    assert!(focus.get("workspaces").is_none(), "unchanged array resent");
    // Geometry arrives with the debounced resnapshot: no polling involved.
    // The new window's geometry roles come with it.
    let overlap = rig.seen.patch("wm", "dockOverlapped");
    assert_eq!(overlap["dockOverlapped"], true);
    let vlc_row = row(&overlap["toplevels"], "winId", "0xc3");
    assert_eq!(
        [
            &vlc_row["x"],
            &vlc_row["y"],
            &vlc_row["width"],
            &vlc_row["height"]
        ],
        [200, 500, 800, 560]
    );

    // ---- title storm: coalesced ------------------------------------------
    rig.seen.clear();
    for i in 0..60 {
        fake.send(&format!("windowtitlev2>>b2,building {i}/59\n"));
        std::thread::sleep(Duration::from_millis(3));
    }
    rig.seen.wait("final title", |e| {
        e["s"] == "wm" && row_title(&e["d"]["toplevels"], "0xb2") == Some("building 59/59".into())
    });
    let title_patches = rig
        .seen
        .all()
        .iter()
        .filter(|e| e["s"] == "wm" && !e["d"]["toplevels"].is_null())
        .count();
    assert!(
        (1..=6).contains(&title_patches),
        "60 title events in ~200 ms gave {title_patches} patches"
    );
    assert!(
        rig.seen.all().iter().all(|e| e["s"] == "wm"),
        "titles must not touch the dock"
    );

    // ---- urgency → dock attention ----------------------------------------
    rig.seen.clear();
    fake.send("urgent>>b2\n");
    let dock = rig.seen.patch("apps", "dock")["dock"].clone();
    assert_eq!(
        row(&dock, "appId", "org.codeberg.dnkl.foot")["attention"],
        true
    );

    // ---- calls ------------------------------------------------------------
    fake.take_requests();
    assert_eq!(rig.call("wm.switchWorkspace", json!([3])), Ok(Value::Null));
    assert_eq!(
        fake.requests(1),
        ["dispatch hl.dsp.focus({ workspace = 3 })"]
    );
    assert!(matches!(
        rig.call("wm.switchWorkspace", json!([-98])),
        Err(CallError::BadArgs(_))
    ));
    assert_eq!(rig.call("wm.activate", json!(["0xb2"])), Ok(Value::Null));
    assert_eq!(
        fake.requests(2),
        [
            r#"dispatch hl.dsp.focus({ window = "address:0xb2" })"#,
            r#"dispatch hl.dsp.window.alter_zorder({ mode = "top", window = "address:0xb2" })"#,
        ]
    );
    assert!(matches!(
        rig.call("wm.activate", json!(["0xdead"])),
        Err(CallError::Failed(_))
    ));
    assert_eq!(
        rig.call("wm.moveToWorkspace", json!(["0xb2", 2])),
        Ok(Value::Null)
    );
    assert_eq!(
        fake.requests(1),
        [
            r#"dispatch hl.dsp.window.move({ workspace = 2, follow = false, window = "address:0xb2" })"#
        ]
    );
    assert!(matches!(
        rig.call("wm.moveToWorkspace", json!(["0xb2", 0])),
        Err(CallError::BadArgs(_))
    ));
    assert!(matches!(
        rig.call("wm.moveToWorkspace", json!(["0xdead", 2])),
        Err(CallError::Failed(_))
    ));
    // The app is running and not focused: focus its window, no launch.
    assert_eq!(
        rig.call("apps.activate", json!(["firefox"])),
        Ok(Value::Null)
    );
    assert_eq!(
        fake.requests(2)[0],
        r#"dispatch hl.dsp.focus({ window = "address:0xa1" })"#
    );
    assert_eq!(rig.call("apps.quit", json!(["vlc"])), Ok(Value::Null));
    assert_eq!(
        fake.requests(1),
        [r#"dispatch hl.dsp.window.close({ window = "address:0xc3" })"#]
    );
    assert!(matches!(
        rig.call("wm.nope", json!([])),
        Err(CallError::UnknownMethod(_))
    ));

    // ---- minimized windows stay listed and are restored on activate -------
    rig.seen.clear();
    let foot_min = client(
        "0xb2",
        "foot",
        "building 59/59",
        (-99, "special:minimized"),
        [300, 200, 700, 400],
    );
    fake.set("j/clients", json!([firefox, foot_min, vlc]));
    fake.set(
        "j/workspaces",
        json!([
            workspace(1, "1", 2),
            workspace(2, "2", 0),
            workspace(-99, "special:minimized", 1)
        ]),
    );
    fake.send("createworkspacev2>>-99,special:minimized\nmovewindowv2>>b2,-99,special:minimized\n");
    let moved = rig.seen.wait("minimized window", |e| {
        e["s"] == "wm" && row_ws(&e["d"]["toplevels"], "0xb2") == Some(-99)
    });
    assert!(
        moved["d"].get("workspaces").is_none(),
        "special workspaces are not dots: {moved}"
    );
    std::thread::sleep(Duration::from_millis(300)); // let the resnapshot pass
    fake.take_requests();
    assert_eq!(rig.call("wm.activate", json!(["0xb2"])), Ok(Value::Null));
    assert_eq!(
        fake.requests(3),
        [
            r#"dispatch hl.dsp.window.move({ workspace = 1, follow = false, window = "address:0xb2" })"#,
            r#"dispatch hl.dsp.focus({ window = "address:0xb2" })"#,
            r#"dispatch hl.dsp.window.alter_zorder({ mode = "top", window = "address:0xb2" })"#,
        ]
    );

    // ---- launching --------------------------------------------------------
    rig.seen.clear();
    assert_eq!(rig.call("apps.launch", json!(["quick"])), Ok(Value::Null));
    let dock = rig.seen.patch("apps", "dock")["dock"].clone();
    assert_eq!(
        row(&dock, "appId", "quick"),
        &json!({ "appId": "quick", "name": "Quick", "icon": "quick", "pinned": false,
                 "running": false, "windows": 0, "launching": true, "attention": false })
    );
    // Starting an app counts as a use: it shows up in `recent`.
    let recent = rig.seen.patch("launcher", "recent")["recent"].clone();
    assert_eq!(
        recent,
        json!([{ "appId": "quick", "name": "Quick", "icon": "quick" }])
    );
    // Its window appears: no longer launching, now running.
    rig.seen.clear();
    let quick = client("0xd4", "quick", "Quick", (1, "1"), [10, 10, 100, 100]);
    fake.set("j/clients", json!([firefox, foot_min, vlc, quick]));
    fake.send("openwindow>>d4,1,quick,Quick\n");
    let dock = rig.seen.patch("apps", "dock")["dock"].clone();
    let q = row(&dock, "appId", "quick");
    assert_eq!(
        (&q["launching"], &q["running"]),
        (&json!(false), &json!(true))
    );

    // A command that does not exist: a plain-language signal, and the
    // launching state is taken back.
    rig.seen.clear();
    assert_eq!(rig.call("apps.launch", json!(["broken"])), Ok(Value::Null));
    let signal = rig.seen.wait("launchFailed", |e| e["t"] == "signal");
    assert_eq!(
        signal,
        json!({ "t": "signal", "s": "apps", "n": "launchFailed",
                "a": ["broken", "Broken couldn't start: command not found"] })
    );
    rig.seen.wait("launching cleared", |e| {
        e["s"] == "apps"
            && e["d"]["dock"]
                .as_array()
                .is_some_and(|d| d.iter().all(|r| r["appId"] != "broken"))
    });
    assert!(matches!(
        rig.call("apps.launch", json!(["nope"])),
        Err(CallError::Failed(_))
    ));

    // ---- launcher ---------------------------------------------------------
    rig.seen.clear();
    assert_eq!(
        rig.call("launcher.search", json!(["fire"])),
        Ok(Value::Null)
    );
    // Synchronous: the patch is there when the call returns.
    let events = rig.seen.all();
    assert_eq!(events.len(), 1);
    let d = &events[0]["d"];
    assert_eq!(
        (&d["query"], &d["searching"]),
        (&json!("fire"), &json!(false))
    );
    assert_eq!(
        d["results"][0],
        json!({ "kind": "app", "group": "Apps", "title": "Firefox", "subtitle": "Web Browser",
                "icon": "firefox", "target": "firefox" })
    );
    // Open windows are searchable by title.
    rig.seen.clear();
    rig.call("launcher.search", json!(["bunny"])).unwrap();
    let d = rig.seen.all()[0]["d"].clone();
    assert_eq!(
        d["results"],
        json!([{ "kind": "window", "group": "Open windows", "title": "Big Buck Bunny",
                 "subtitle": "Switch to window", "icon": "vlc", "target": "0xc3" }])
    );
    // Activating that row focuses the window.
    fake.take_requests();
    assert_eq!(rig.call("launcher.activate", json!([0])), Ok(Value::Null));
    assert_eq!(
        fake.requests(2)[0],
        r#"dispatch hl.dsp.focus({ window = "address:0xc3" })"#
    );
    assert!(matches!(
        rig.call("launcher.activate", json!([7])),
        Err(CallError::BadArgs(_))
    ));
    rig.seen.clear();
    rig.call("launcher.search", json!([""])).unwrap();
    assert_eq!(
        rig.seen.all()[0]["d"],
        json!({ "query": "", "results": [], "searching": false })
    );

    // ---- a second, scaled output takes the focus --------------------------
    // HDMI-A-1: 3840×2160 at scale 2 (1920×1080 logical) right of eDP-1,
    // showing workspace 2 with one window. The focus event names an output
    // the shell has not seen yet: it resnapshots.
    rig.seen.clear();
    fake.set(
        "j/monitors",
        json!([
            { "id": 0, "name": "eDP-1", "description": "", "width": 1920, "height": 1080,
              "x": 0, "y": 0, "scale": 1.0, "transform": 0, "focused": false,
              "activeWorkspace": { "id": 1, "name": "1" } },
            { "id": 1, "name": "HDMI-A-1", "description": "", "width": 3840, "height": 2160,
              "x": 1920, "y": 0, "scale": 2.0, "transform": 0, "focused": true,
              "activeWorkspace": { "id": 2, "name": "2" } },
        ]),
    );
    let big = client("0xe5", "vlc", "Trailer", (2, "2"), [2020, 140, 1200, 800]);
    fake.set("j/clients", json!([firefox, foot_min, vlc, quick, big]));
    fake.set(
        "j/workspaces",
        json!([
            workspace(1, "1", 3),
            { "id": 2, "name": "2", "monitor": "HDMI-A-1", "windows": 1 },
            workspace(-99, "special:minimized", 1)
        ]),
    );
    fake.set("j/activeworkspace", json!({ "id": 2, "name": "2" }));
    fake.send("focusedmon>>HDMI-A-1,2\n");
    let d = rig.seen.patch("wm", "activeOutput");
    assert_eq!(d["activeOutput"], "HDMI-A-1");
    let d = rig.seen.wait("window on HDMI-A-1", |e| {
        e["s"] == "wm"
            && e["d"]["toplevels"]
                .as_array()
                .is_some_and(|r| r.iter().any(|w| w["winId"] == "0xe5"))
    });
    let on_hdmi = row(&d["d"]["toplevels"], "winId", "0xe5");
    assert_eq!(
        [
            &on_hdmi["x"],
            &on_hdmi["y"],
            &on_hdmi["width"],
            &on_hdmi["height"],
            &on_hdmi["monitorWidth"],
            &on_hdmi["monitorHeight"],
            &on_hdmi["monitor"],
        ],
        [
            &json!(100),
            &json!(140),
            &json!(1200),
            &json!(800),
            &json!(1920),
            &json!(1080),
            &json!("HDMI-A-1")
        ]
    );
    assert_eq!(rig.svc("wm").state()["activeOutput"], "HDMI-A-1");
    // Back to the known laptop panel: straight from the event.
    rig.seen.clear();
    fake.send("focusedmon>>eDP-1,1\n");
    assert_eq!(
        rig.seen.patch("wm", "activeOutput")["activeOutput"],
        "eDP-1"
    );

    // ---- the event socket drops: unavailable, then back -------------------
    rig.seen.clear();
    fake.events.send(EventCmd::Drop).unwrap();
    rig.seen.wait("available:false", |e| {
        e["s"] == "wm" && e["d"]["available"] == false
    });
    rig.seen.wait("available:true", |e| {
        e["s"] == "wm" && e["d"]["available"] == true
    });
    // Still alive afterwards.
    rig.seen.clear();
    fake.send("windowtitlev2>>a1,Back online\n");
    let d = rig.seen.patch("wm", "toplevels");
    assert_eq!(
        row_title(&d["toplevels"], "0xa1"),
        Some("Back online".into())
    );
}

fn row_title(rows: &Value, win: &str) -> Option<String> {
    rows.as_array()?.iter().find(|r| r["winId"] == win)?["title"]
        .as_str()
        .map(str::to_owned)
}

fn row_ws(rows: &Value, win: &str) -> Option<i64> {
    rows.as_array()?.iter().find(|r| r["winId"] == win)?["workspace"].as_i64()
}

#[test]
fn without_a_compositor_everything_still_answers() {
    let rig = Rig::start(None);
    assert_eq!(
        rig.svc("wm").state(),
        json!({ "available": false, "workspaces": [], "activeWorkspace": 1,
                "focusedAppId": "", "focusedAppName": "", "focusedTitle": "",
                "toplevels": [], "dockOverlapped": false, "activeOutput": "" })
    );
    // Pinned and installed apps only; nothing runs.
    let apps = rig.svc("apps").state();
    assert_eq!(
        ids(&apps["dock"], "appId"),
        ["firefox", "org.codeberg.dnkl.foot"]
    );
    assert!(
        apps["dock"]
            .as_array()
            .unwrap()
            .iter()
            .all(|d| d["running"] == false && d["windows"] == 0)
    );
    assert!(matches!(
        rig.call("wm.switchWorkspace", json!([2])),
        Err(CallError::Failed(_))
    ));
    assert_eq!(rig.call("apps.quit", json!(["firefox"])), Ok(Value::Null));
    assert_eq!(rig.call("apps.rescan", json!([])), Ok(Value::Null));
    rig.call("launcher.search", json!(["term"])).unwrap();
    let d = rig.seen.patch("launcher", "results");
    assert_eq!(d["results"][0]["target"], "org.codeberg.dnkl.foot");
    std::thread::sleep(Duration::from_millis(100));
    assert!(
        rig.seen.all().iter().all(|e| e["s"] != "wm"),
        "no wm events without a compositor"
    );
}

#[test]
fn rescan_picks_up_a_new_app() {
    let rig = Rig::start(None);
    let dir = rig._apps.path().join("applications");
    // Directory mtimes have one-second granularity on some filesystems.
    std::thread::sleep(Duration::from_millis(1100));
    write_app(&dir, "aaa-new", "Aardvark", "/bin/true", "");
    assert_eq!(rig.call("apps.rescan", json!([])), Ok(Value::Null));
    let installed = rig.seen.patch("apps", "installed")["installed"].clone();
    assert_eq!(installed[0]["appId"], "aaa-new");
    // Nothing changed since: a second rescan is silent.
    rig.seen.clear();
    assert_eq!(rig.call("apps.rescan", json!([])), Ok(Value::Null));
    std::thread::sleep(Duration::from_millis(200));
    assert!(rig.seen.all().is_empty());
}
