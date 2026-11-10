//! Logins against a fake greetd on a temporary Unix socket: the raw
//! conversation ([`Login`]) and the whole backend ([`Backend`]).

#![allow(clippy::unwrap_used)] // test helpers sit outside #[test] functions

use std::fs;
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use lugh_greetd::backend::{Backend, Event, Options, Paths};
use lugh_greetd::fake::{FakeConfig, FakeGreetd, Seen};
use lugh_greetd::ipc::{Client, IpcError, Login, Notice, Request, Step, Timeouts};
use lugh_greetd::state::State;
use zeroize::Zeroizing;

const WAIT: Duration = Duration::from_secs(10);

fn config() -> FakeConfig {
    let mut config = FakeConfig::with_user("amara", "s3cret");
    config.users.insert("otp".into(), "pw".into());
    config.multi_prompt_users = vec!["otp".into()];
    config.otp = "123456".into();
    config
}

fn connect(socket: &Path) -> Login<std::os::unix::net::UnixStream> {
    Login::new(Client::connect(socket, Timeouts::default()).unwrap())
}

fn answer(text: &str) -> Zeroizing<String> {
    Zeroizing::new(text.to_owned())
}

fn password_prompt() -> Step {
    Step::Prompt {
        secret: true,
        text: "Password:".into(),
    }
}

#[test]
fn right_password_then_start() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("greetd.sock");
    let greetd = FakeGreetd::spawn(&socket, config()).unwrap();
    let mut login = connect(&socket);
    let mut none = |_: Notice| {};

    assert_eq!(
        login.create_session("amara", &mut none).unwrap(),
        password_prompt()
    );
    assert_eq!(
        login.respond(answer("s3cret"), &mut none).unwrap(),
        Step::Authenticated
    );
    login
        .start_session(vec!["lugh-session".into()], vec!["A=b".into()])
        .unwrap();
    drop(login);

    let seen: Vec<Seen> = std::iter::from_fn(|| greetd.next(WAIT))
        .take_while(|s| *s != Seen::Disconnected)
        .collect();
    assert!(seen.contains(&Seen::Started {
        user: "amara".into(),
        cmd: vec!["lugh-session".into()],
        env: vec!["A=b".into()],
    }));
    assert!(
        !format!("{seen:?}").contains("s3cret"),
        "the log leaks the password"
    );
}

#[test]
fn wrong_password_is_cancelled_and_retry_works() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("greetd.sock");
    let greetd = FakeGreetd::spawn(&socket, config()).unwrap();
    let mut login = connect(&socket);
    let mut none = |_: Notice| {};

    assert_eq!(
        login.create_session("amara", &mut none).unwrap(),
        password_prompt()
    );
    let step = login.respond(answer("nope"), &mut none).unwrap();
    assert!(matches!(step, Step::Failed { auth: true, .. }), "{step:?}");
    assert!(!login.is_open());
    // auth_error is followed by cancel_session...
    let requests: Vec<Seen> = greetd.drain();
    assert_eq!(
        requests.last(),
        Some(&Seen::Request(Request::CancelSession))
    );
    // ...so the next attempt is accepted. An unknown user fails the same way.
    assert_eq!(
        login.create_session("ghost", &mut none).unwrap(),
        password_prompt()
    );
    let step = login.respond(answer("s3cret"), &mut none).unwrap();
    assert!(matches!(step, Step::Failed { auth: true, .. }), "{step:?}");
    assert_eq!(
        login.create_session("amara", &mut none).unwrap(),
        password_prompt()
    );
    assert_eq!(
        login.respond(answer("s3cret"), &mut none).unwrap(),
        Step::Authenticated
    );
}

#[test]
fn multi_prompt_pam_conversation() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("greetd.sock");
    let _greetd = FakeGreetd::spawn(&socket, config()).unwrap();
    let mut login = connect(&socket);
    let mut notices = Vec::new();

    let step = login
        .create_session("otp", &mut |n| notices.push(n))
        .unwrap();
    assert_eq!(step, password_prompt());
    assert_eq!(
        notices,
        [Notice {
            error: false,
            text: "Your password expires in 3 days.".into()
        }]
    );
    let step = login.respond(answer("pw"), &mut |_| {}).unwrap();
    assert_eq!(
        step,
        Step::Prompt {
            secret: false,
            text: "One-time code:".into()
        }
    );
    assert_eq!(
        login.respond(answer("123456"), &mut |_| {}).unwrap(),
        Step::Authenticated
    );

    // A wrong code fails the whole attempt.
    let mut login = connect(&socket);
    login.cancel().unwrap();
    let mut second = connect(&socket);
    let err = second.create_session("otp", &mut |_| {}).unwrap();
    assert!(
        matches!(err, Step::Failed { auth: false, .. }),
        "session still held: {err:?}"
    );
    drop(login);
}

#[test]
fn start_session_failure_cancels() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("greetd.sock");
    let mut cfg = config();
    cfg.fail_start = true;
    let greetd = FakeGreetd::spawn(&socket, cfg).unwrap();
    let mut login = connect(&socket);
    let mut none = |_: Notice| {};

    login.create_session("amara", &mut none).unwrap();
    assert_eq!(
        login.respond(answer("s3cret"), &mut none).unwrap(),
        Step::Authenticated
    );
    let err = login
        .start_session(vec!["lugh-session".into()], vec![])
        .unwrap_err();
    assert!(matches!(err, IpcError::Refused(_)), "{err}");
    assert!(!err.is_fatal());
    assert!(!login.is_open());
    assert_eq!(
        greetd.drain().last(),
        Some(&Seen::Request(Request::CancelSession))
    );
    // The connection is still usable.
    assert_eq!(
        login.create_session("amara", &mut none).unwrap(),
        password_prompt()
    );
}

#[test]
fn silent_server_times_out() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("greetd.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let timeouts = Timeouts {
        read: Duration::from_millis(100),
        write: Duration::from_millis(100),
    };
    let mut login = Login::new(Client::connect(&socket, timeouts).unwrap());
    let err = login.create_session("amara", &mut |_| {}).unwrap_err();
    assert!(matches!(err, IpcError::Timeout), "{err}");
    assert!(err.is_fatal());
    let missing = Client::connect(&dir.path().join("nope.sock"), timeouts).unwrap_err();
    assert!(matches!(missing, IpcError::Io(_)), "{missing}");
}

// ---- the whole backend -------------------------------------------------------

struct Fixture {
    _dir: tempfile::TempDir,
    greetd: FakeGreetd,
    backend: Backend,
    events: Receiver<Event>,
    paths: Paths,
}

fn fixture(cfg: FakeConfig) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::write(
        root.join("passwd"),
        "root:x:0:0:root:/root:/bin/bash\n\
         amara:x:1000:1000:Amara Nkusi,,,:/home/amara:/bin/bash\n\
         otp:x:1001:1001:Otp User:/home/otp:/bin/bash\n",
    )
    .unwrap();
    fs::create_dir(root.join("sessions")).unwrap();
    fs::write(
        root.join("sessions/lugh.desktop"),
        "[Desktop Entry]\nName=Lugh\nExec=lugh-session --flag\nDesktopNames=Lugh\n",
    )
    .unwrap();
    let paths = Paths {
        passwd: root.join("passwd"),
        login_defs: root.join("login.defs"),
        icons_dir: root.join("icons"),
        sessions_dir: root.join("sessions"),
        state_dir: root.join("state"),
        config_file: root.join("greeter.toml"),
        keyboard_file: root.join("keyboard"),
    };
    let socket = root.join("greetd.sock");
    let greetd = FakeGreetd::spawn(&socket, cfg).unwrap();
    let (tx, events) = mpsc::channel();
    let backend = Backend::start(
        Options {
            socket: Some(socket),
            paths: paths.clone(),
            xkb_layout: Some("us,fr".into()),
            ..Options::default()
        },
        move |event| {
            let _ = tx.send(event);
        },
    );
    Fixture {
        _dir: dir,
        greetd,
        backend,
        events,
        paths,
    }
}

impl Fixture {
    /// Next event that is not a state/power update.
    fn signal(&self) -> Event {
        loop {
            match self.events.recv_timeout(WAIT).unwrap() {
                Event::State { .. } | Event::Power { .. } => {}
                other => return other,
            }
        }
    }
    fn call(&self, method: &str, arg: &str) {
        assert!(self.backend.call(method, arg.to_owned()));
    }
}

fn prompt_event() -> Event {
    Event::PromptRequested {
        secret: true,
        text: "Password:".into(),
    }
}

#[test]
fn backend_full_login_saves_state() {
    let f = fixture(config());
    let initial = f.backend.initial();
    assert_eq!(initial.users.len(), 2);
    assert_eq!(initial.users[0].real_name, "Amara Nkusi");
    assert_eq!(initial.sessions[0].exec, "lugh-session --flag");
    assert_eq!(initial.last_session, "lugh");
    assert_eq!(initial.layouts, ["us", "fr"]);
    let json: serde_json::Value = serde_json::from_str(&f.backend.initial_json()).unwrap();
    assert_eq!(json["users"][0]["userName"], "amara");
    assert_eq!(json["hideUsers"], false);

    assert!(matches!(
        f.events.recv_timeout(WAIT).unwrap(),
        Event::Power { .. }
    ));
    f.call("createSession", "amara");
    assert_eq!(
        f.events.recv_timeout(WAIT).unwrap(),
        Event::State {
            authenticating: true,
            session_user: "amara".into(),
            last_user: None
        }
    );
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "s3cret");
    assert_eq!(
        f.events.recv_timeout(WAIT).unwrap(),
        Event::State {
            authenticating: false,
            session_user: "amara".into(),
            last_user: Some("amara".into())
        }
    );
    assert_eq!(f.signal(), Event::AuthSucceeded);
    f.call("startSession", "lugh-session --flag");
    assert_eq!(f.signal(), Event::SessionStarted);

    assert!(f.greetd.drain().contains(&Seen::Started {
        user: "amara".into(),
        cmd: vec!["lugh-session".into(), "--flag".into()],
        env: vec![
            "XDG_SESSION_TYPE=wayland".into(),
            "XDG_SESSION_DESKTOP=lugh".into(),
            "XDG_CURRENT_DESKTOP=Lugh".into()
        ],
    }));
    assert_eq!(
        State::load(&f.paths.state_dir.join("state.json")),
        State {
            last_user: "amara".into(),
            last_session: "lugh".into()
        }
    );
    assert!(!f.backend.call("nope", String::new()));
}

#[test]
fn backend_wrong_password_then_right() {
    let f = fixture(config());
    f.call("createSession", "amara");
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "wrong");
    assert_eq!(
        f.signal(),
        Event::AuthFailed {
            message: "Wrong password. Try again.".into()
        }
    );
    // A typed name that is not listed gets the generic message.
    f.call("createSession", "ghost");
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "s3cret");
    assert_eq!(
        f.signal(),
        Event::AuthFailed {
            message: "Wrong username or password. Try again.".into()
        }
    );
    // respond without a session is an error, not a crash.
    f.call("respond", "s3cret");
    assert!(matches!(f.signal(), Event::ErrorOccurred { .. }));
    f.call("createSession", "amara");
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "s3cret");
    assert_eq!(f.signal(), Event::AuthSucceeded);
}

#[test]
fn backend_multi_prompt_and_switching_user() {
    let f = fixture(config());
    f.call("createSession", "amara");
    assert_eq!(f.signal(), prompt_event());
    // Picking another user cancels the open session first.
    f.call("createSession", "otp");
    assert_eq!(
        f.signal(),
        Event::InfoMessage {
            text: "Your password expires in 3 days.".into()
        }
    );
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "pw");
    assert_eq!(
        f.signal(),
        Event::PromptRequested {
            secret: false,
            text: "One-time code:".into()
        }
    );
    f.call("respond", "123456");
    assert_eq!(f.signal(), Event::AuthSucceeded);
    f.call("cancelSession", "");
    f.call("startSession", "lugh-session");
    assert!(matches!(f.signal(), Event::ErrorOccurred { .. }));
}

#[test]
fn backend_start_failure_reports_and_recovers() {
    let mut cfg = config();
    cfg.fail_start = true;
    let f = fixture(cfg);
    f.call("createSession", "amara");
    assert_eq!(f.signal(), prompt_event());
    f.call("respond", "s3cret");
    assert_eq!(f.signal(), Event::AuthSucceeded);
    f.call("startSession", "lugh-session --flag");
    assert_eq!(
        f.signal(),
        Event::ErrorOccurred {
            message: "Couldn't start the session. Try again.".into()
        }
    );
    assert!(!f.paths.state_dir.join("state.json").exists());
    f.call("createSession", "amara");
    assert_eq!(f.signal(), prompt_event());
}

#[test]
fn backend_without_greetd_reports_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let (tx, events) = mpsc::channel();
    let backend = Backend::start(
        Options {
            socket: Some(dir.path().join("missing.sock")),
            ..Options::default()
        },
        move |event| {
            let _ = tx.send(event);
        },
    );
    assert!(backend.call("createSession", "amara".to_owned()));
    let error = std::iter::from_fn(|| events.recv_timeout(WAIT).ok())
        .find(|e| matches!(e, Event::ErrorOccurred { .. }));
    assert!(error.is_some());
}

#[test]
fn demo_mode_logs_in_with_the_demo_password() {
    let (tx, events) = mpsc::channel();
    let backend = Backend::start(
        Options {
            demo: true,
            ..Options::default()
        },
        move |event| {
            let _ = tx.send(event);
        },
    );
    assert_eq!(backend.initial().users.len(), 3);
    let signal = || loop {
        match events.recv_timeout(WAIT).unwrap() {
            Event::State { .. } | Event::Power { .. } => {}
            other => return other,
        }
    };
    assert!(backend.call("createSession", "keza".to_owned()));
    assert_eq!(signal(), prompt_event());
    assert!(backend.call("respond", "lugh".to_owned()));
    assert_eq!(signal(), Event::AuthSucceeded);
    assert!(backend.call("startSession", "lugh-session".to_owned()));
    assert_eq!(signal(), Event::SessionStarted);
}
