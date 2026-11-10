//! End-to-end test of the Hyprland adapter against a fake Hyprland that
//! serves `.socket.sock` and `.socket2.sock` from a temporary directory.

#![allow(clippy::unwrap_used)]

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lugh_shell_core::wm::hyprland::{EVENT_SOCKET, HyprlandAdapter, REQUEST_SOCKET};
use lugh_shell_core::wm::{
    CompositorAdapter, EventStream, WindowId, WmChange, WmError, WmEvent, WmState, WorkspaceId,
};

const CLIENTS: &str = include_str!("../src/wm/hyprland/fixtures/clients-0.50.json");
const WORKSPACES: &str = include_str!("../src/wm/hyprland/fixtures/workspaces-0.50.json");
const MONITORS: &str = include_str!("../src/wm/hyprland/fixtures/monitors-0.50.json");
const ACTIVE_WINDOW: &str = include_str!("../src/wm/hyprland/fixtures/activewindow-0.50.json");
const ACTIVE_WORKSPACE: &str =
    include_str!("../src/wm/hyprland/fixtures/activeworkspace-0.50.json");
const EVENT_LOG: &str = include_str!("../src/wm/hyprland/fixtures/events-0.50.log");

const WAIT: Duration = Duration::from_secs(3);

enum EventCmd {
    Line(String),
    /// Close the event connection and accept the next one.
    Drop,
    /// Report whether the client closed its end.
    ExpectClosed(Sender<bool>),
}

struct FakeHyprland {
    dir: tempfile::TempDir,
    requests: Arc<Mutex<Vec<String>>>,
    events: Sender<EventCmd>,
}

fn reply_to(request: &str) -> String {
    let one = |cmd: &str| -> String {
        if cmd.contains("0xdead") || cmd.starts_with("dispatch bogus") {
            "No such window found".into()
        } else {
            "ok".into()
        }
    };
    match request {
        "j/clients" => CLIENTS.into(),
        "j/workspaces" => WORKSPACES.into(),
        "j/monitors" => MONITORS.into(),
        "j/activewindow" => ACTIVE_WINDOW.into(),
        "j/activeworkspace" => ACTIVE_WORKSPACE.into(),
        r if r.starts_with("[[BATCH]]") => r["[[BATCH]]".len()..]
            .split(';')
            .map(one)
            .collect::<Vec<_>>()
            .join("\n\n"),
        r => one(r),
    }
}

impl FakeHyprland {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let req_listener = UnixListener::bind(dir.path().join(REQUEST_SOCKET)).unwrap();
        let log = Arc::clone(&requests);
        std::thread::spawn(move || {
            for stream in req_listener.incoming() {
                let Ok(mut stream) = stream else { return };
                // Like Hyprland: one read of the request, one reply, close.
                let mut buf = [0u8; 8192];
                let n = stream.read(&mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).into_owned();
                let reply = reply_to(&request);
                log.lock().unwrap().push(request);
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
                    EventCmd::ExpectClosed(reply) => {
                        conn.set_read_timeout(Some(WAIT)).unwrap();
                        let mut b = [0u8; 1];
                        let _ = reply.send(matches!(conn.read(&mut b), Ok(0)));
                    }
                }
            }
        });

        Self {
            dir,
            requests,
            events: tx,
        }
    }

    fn adapter(&self) -> HyprlandAdapter {
        HyprlandAdapter::with_socket_dir(self.dir.path())
    }

    fn send(&self, text: &str) {
        self.events.send(EventCmd::Line(text.to_owned())).unwrap();
    }

    fn take_requests(&self) -> Vec<String> {
        std::mem::take(&mut *self.requests.lock().unwrap())
    }
}

/// Collects `n` events, failing the test if they do not arrive in time.
fn collect(stream: &EventStream, n: usize) -> Vec<WmEvent> {
    (0..n)
        .map(|i| {
            stream
                .next_timeout(WAIT)
                .unwrap()
                .unwrap_or_else(|| panic!("event {i} of {n} did not arrive"))
        })
        .collect()
}

fn id(s: &str) -> WindowId {
    WindowId::new(s)
}

#[test]
fn snapshot_events_and_dispatch_end_to_end() {
    let fake = FakeHyprland::start();
    let wm = fake.adapter();

    // Subscribe first, then snapshot.
    let stream = wm.subscribe().unwrap();
    let snapshot = wm.snapshot().unwrap();
    assert_eq!(
        fake.take_requests(),
        [
            "j/clients",
            "j/workspaces",
            "j/monitors",
            "j/activewindow",
            "j/activeworkspace"
        ]
    );
    assert_eq!(snapshot.toplevels.len(), 3);
    assert_eq!(snapshot.monitors.len(), 2);
    assert_eq!(snapshot.active_workspace, Some(WorkspaceId(1)));
    assert_eq!(snapshot.focused, Some(id("0x5a3e1d2c4a00")));

    let mut state = WmState::new();
    let initial = state.reset(snapshot);
    assert_eq!(
        initial
            .iter()
            .filter(|c| matches!(c, WmChange::WorkspaceAdded(_)))
            .count(),
        3
    );
    assert_eq!(
        initial
            .iter()
            .filter(|c| matches!(c, WmChange::ToplevelAdded(_)))
            .count(),
        3
    );
    assert_eq!(
        state.focused_toplevel().map(|t| t.app_id.as_str()),
        Some("firefox")
    );

    // A burst of events in one write, a line split across writes, and garbage.
    fake.send(concat!(
        "openwindow>>5a3e1d2c4e40,5,vlc,Big Buck Bunny, 1080p >> VLC\n",
        "openlayer>>lugh-osd\n",
        "\u{1}\u{2}garbage without separator\n",
        "activewindow>>vlc,Big Buck Bunny, 1080p >> VLC\n",
        "activewindowv2>>5a3e1d2c4e40\n",
        "focusedmon>>HDMI-A-1,music, loud\n",
    ));
    fake.send("windowtitlev2>>5a3e1d2c4e40,Paused, ");
    std::thread::sleep(Duration::from_millis(50));
    fake.send("Big Buck Bunny\n");
    let events = collect(&stream, 7);
    assert_eq!(
        events[0],
        WmEvent::OpenWindow {
            id: id("0x5a3e1d2c4e40"),
            workspace: "5".into(),
            class: "vlc".into(),
            title: "Big Buck Bunny, 1080p >> VLC".into(),
        }
    );
    assert!(matches!(events[2], WmEvent::Unknown { .. }));
    assert_eq!(
        events[6],
        WmEvent::WindowTitleV2 {
            id: id("0x5a3e1d2c4e40"),
            title: "Paused, Big Buck Bunny".into()
        }
    );

    let changes: Vec<WmChange> = events.iter().flat_map(|e| state.apply(e)).collect();
    assert!(!state.take_resync(), "{changes:?}");
    assert!(changes.contains(&WmChange::FocusChanged(Some(id("0x5a3e1d2c4e40")))));
    assert!(changes.contains(&WmChange::ActiveWorkspaceChanged(Some(WorkspaceId(5)))));
    let ws5 = state.workspace(WorkspaceId(5)).unwrap();
    assert!(ws5.occupied && ws5.windows == 1);
    let vlc = state.focused_toplevel().unwrap();
    assert_eq!(
        (vlc.app_id.as_str(), vlc.title.as_str()),
        ("vlc", "Paused, Big Buck Bunny")
    );
    assert!(state.monitors()[1].focused);

    // Requests.
    wm.activate(&id("0x5a3e1d2c4b10")).unwrap();
    wm.close(&id("0x5a3e1d2c4b10")).unwrap();
    wm.switch_workspace(WorkspaceId(3)).unwrap();
    wm.move_to_workspace(&id("0x5a3e1d2c4a00"), WorkspaceId(3))
        .unwrap();
    wm.toggle_floating(&id("0x5a3e1d2c4a00")).unwrap();
    // Workspace 1 has a floating window, so the toggle tiles everything.
    assert!(wm.toggle_workspace_tiling(WorkspaceId(1)).unwrap());
    // Workspace 2 has only floating windows: tiles too.
    assert!(wm.toggle_workspace_tiling(WorkspaceId(2)).unwrap());
    // An empty workspace: nothing to send.
    assert!(!wm.toggle_workspace_tiling(WorkspaceId(9)).unwrap());
    wm.reload().unwrap();
    assert_eq!(
        fake.take_requests(),
        [
            r#"dispatch hl.dsp.focus({ window = "address:0x5a3e1d2c4b10" })"#,
            r#"dispatch hl.dsp.window.alter_zorder({ mode = "top", window = "address:0x5a3e1d2c4b10" })"#,
            r#"dispatch hl.dsp.window.close({ window = "address:0x5a3e1d2c4b10" })"#,
            "dispatch hl.dsp.focus({ workspace = 3 })",
            r#"dispatch hl.dsp.window.move({ workspace = 3, follow = false, window = "address:0x5a3e1d2c4a00" })"#,
            r#"dispatch hl.dsp.window.float({ action = "toggle", window = "address:0x5a3e1d2c4a00" })"#,
            "j/clients",
            r#"[[BATCH]]dispatch hl.dsp.window.float({ action = "unset", window = "address:0x5a3e1d2c4a00" });dispatch hl.dsp.window.float({ action = "unset", window = "address:0x5a3e1d2c4b10" })"#,
            "j/clients",
            r#"dispatch hl.dsp.window.float({ action = "unset", window = "address:0x5a3e1d2c4c20" })"#,
            "j/clients",
            "reload",
        ]
    );

    // Errors: a refused request, and arguments that never reach the socket.
    assert!(matches!(
        wm.activate(&id("0xdead")),
        Err(WmError::Rejected { reply, .. }) if reply == "No such window found"
    ));
    assert!(matches!(
        wm.close(&id("0x1;dispatch exec rm")),
        Err(WmError::InvalidArgument(_))
    ));
    assert!(matches!(
        wm.switch_workspace(WorkspaceId(-98)),
        Err(WmError::InvalidArgument(_))
    ));
    assert_eq!(
        fake.take_requests(),
        [r#"dispatch hl.dsp.focus({ window = "address:0xdead" })"#]
    );

    // The event socket drops: the reader reconnects and says so.
    fake.events.send(EventCmd::Drop).unwrap();
    let ev = stream.next_timeout(WAIT).unwrap();
    assert_eq!(ev, Some(WmEvent::Disconnected));
    let ev = stream.next_timeout(WAIT).unwrap();
    assert_eq!(ev, Some(WmEvent::Reconnected));
    assert!(state.apply(&WmEvent::Reconnected).is_empty());
    assert!(state.take_resync());
    // Resync from a fresh snapshot: the fake still reports its original
    // state, so the diff removes what the events added and nothing else.
    let diff = state.reset(wm.snapshot().unwrap());
    assert!(diff.contains(&WmChange::ToplevelRemoved(id("0x5a3e1d2c4e40"))));
    assert!(diff.contains(&WmChange::FocusChanged(Some(id("0x5a3e1d2c4a00")))));
    assert!(!diff.iter().any(|c| matches!(c, WmChange::ToplevelAdded(_))));

    fake.send("closewindow>>5a3e1d2c4a00\n");
    assert_eq!(
        collect(&stream, 1),
        [WmEvent::CloseWindow {
            id: id("0x5a3e1d2c4a00")
        }]
    );

    // Dropping the stream closes the connection.
    drop(stream);
    let (tx, rx): (Sender<bool>, Receiver<bool>) = mpsc::channel();
    fake.events.send(EventCmd::ExpectClosed(tx)).unwrap();
    assert!(
        rx.recv_timeout(WAIT * 2).unwrap(),
        "reader thread kept the socket open"
    );
}

/// A compositor on the legacy hyprlang config answers `Invalid dispatcher`
/// to a Lua expression: the adapter switches to legacy strings and stays
/// there.
#[test]
fn falls_back_to_legacy_dispatch_syntax() {
    let dir = tempfile::tempdir().unwrap();
    let listener = UnixListener::bind(dir.path().join(REQUEST_SOCKET)).unwrap();
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { return };
            let mut buf = [0u8; 4096];
            let n = s.read(&mut buf).unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]).into_owned();
            let reply = if request.contains("hl.dsp.") {
                "Invalid dispatcher"
            } else {
                "ok"
            };
            log.lock().unwrap().push(request);
            let _ = s.write_all(reply.as_bytes());
        }
    });
    let wm = HyprlandAdapter::with_socket_dir(dir.path());
    wm.switch_workspace(WorkspaceId(2)).unwrap();
    wm.close(&id("0xabc")).unwrap();
    wm.clone()
        .move_to_workspace(&id("0xabc"), WorkspaceId(4))
        .unwrap();
    assert_eq!(
        *seen.lock().unwrap(),
        [
            "dispatch hl.dsp.focus({ workspace = 2 })",
            "dispatch workspace 2",
            "dispatch closewindow address:0xabc",
            "dispatch movetoworkspacesilent 4,address:0xabc",
        ]
    );
}

#[test]
fn unavailable_compositor() {
    let dir = tempfile::tempdir().unwrap();
    let wm = HyprlandAdapter::with_socket_dir(dir.path());
    assert!(matches!(wm.snapshot(), Err(WmError::Io { .. })));
    assert!(matches!(wm.subscribe(), Err(WmError::Io { .. })));
}

#[test]
fn malformed_json_is_an_error_not_a_panic() {
    let dir = tempfile::tempdir().unwrap();
    let listener = UnixListener::bind(dir.path().join(REQUEST_SOCKET)).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { return };
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let _ = s.write_all(b"[{\"address\": 5,");
        }
    });
    let wm = HyprlandAdapter::with_socket_dir(dir.path());
    assert!(matches!(wm.snapshot(), Err(WmError::Json { .. })));
}

#[test]
fn recorded_session_replays_without_surprises() {
    // Replays a captured event log. It was recorded from a session that
    // started with only Firefox on workspace 1, so trim the fixture to that.
    let fake = FakeHyprland::start();
    let mut snapshot = fake.adapter().snapshot().unwrap();
    snapshot.toplevels.retain(|t| t.id == id("0x5a3e1d2c4a00"));
    snapshot.workspaces.retain(|w| w.id == WorkspaceId(1));
    let mut state = WmState::from_snapshot(snapshot);
    let mut resync_at = Vec::new();
    for line in EVENT_LOG.lines() {
        let ev = lugh_shell_core::wm::hyprland::parse_event(line);
        state.apply(&ev);
        if state.take_resync() {
            resync_at.push(line.split(">>").next().unwrap_or_default().to_owned());
        }
    }
    // Only hot-plug and reload ask for a resync.
    assert_eq!(
        resync_at,
        ["monitoradded", "monitoraddedv2", "configreloaded"]
    );
    assert!(state.toplevel(&id("0x5a3e1d2c4b10")).is_none());
    assert_eq!(state.workspace(WorkspaceId(1)).unwrap().name, "web");
    assert!(state.workspace(WorkspaceId(-98)).is_some());
    assert!(state.focused().is_none());
    assert!(state.toplevel(&id("0x5a3e1d2c4a00")).unwrap().urgent);
    assert!(state.workspace(WorkspaceId(2)).is_none());
}

#[test]
fn request_socket_without_reply_times_out() {
    let dir = tempfile::tempdir().unwrap();
    let listener = UnixListener::bind(dir.path().join(REQUEST_SOCKET)).unwrap();
    let hold: Arc<Mutex<Vec<UnixStream>>> = Arc::default();
    let keep = Arc::clone(&hold);
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            keep.lock().unwrap().push(s);
        }
    });
    let wm = HyprlandAdapter::with_socket_dir(dir.path()).with_timeout(Duration::from_millis(100));
    assert!(matches!(wm.reload(), Err(WmError::Io { .. })));
}
