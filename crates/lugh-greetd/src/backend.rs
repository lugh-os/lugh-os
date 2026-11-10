//! The greeter's worker: one thread that owns the greetd connection, takes
//! the UI's calls and reports back with [`Event`]s.
//!
//! The UI bridge (`ui/greeter`) forwards `call(method, arg)` from QML and
//! turns every event into JSON for the QML adapter, which presents the
//! `greetdBackend` contract of `ui/greeter/README.md`.

use std::collections::HashMap;
use std::fs;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::fake::{FakeConfig, FakeGreetd};
use crate::ipc::{Client, IpcError, Login, Notice, Step, Timeouts};
use crate::power::{self, Action};
use crate::sessions::{self, DEFAULT_SESSION, Session};
use crate::state::State;
use crate::users::{self, UserEntry};

/// Password of every demo user.
pub const DEMO_PASSWORD: &str = "lugh";
/// Above this many users the UI shows a username field, so failures must not
/// say whether the account exists.
const MAX_LISTED_USERS: usize = 10;

const MSG_WRONG_PASSWORD: &str = "Wrong password. Try again.";
const MSG_WRONG_USER_OR_PASSWORD: &str = "Wrong username or password. Try again.";
const MSG_UNAVAILABLE: &str = "Sign-in isn't available right now. Try again in a moment.";
const MSG_NO_LOGIN: &str = "No login in progress.";
const MSG_START_FAILED: &str = "Couldn't start the session. Try again.";
const MSG_POWER_REFUSED: &str = "The computer refused that power action.";
const MSG_DEMO_POWER: &str = "Demo mode: power actions are turned off.";

/// Files and directories the backend reads and writes.
#[derive(Debug, Clone)]
pub struct Paths {
    /// `/etc/passwd`.
    pub passwd: PathBuf,
    /// `/etc/login.defs`.
    pub login_defs: PathBuf,
    /// `/var/lib/AccountsService/icons`.
    pub icons_dir: PathBuf,
    /// `/usr/share/wayland-sessions`.
    pub sessions_dir: PathBuf,
    /// `/var/lib/lugh-greeter` (state file, wallpaper copy).
    pub state_dir: PathBuf,
    /// `/etc/lugh/greeter.toml`.
    pub config_file: PathBuf,
    /// `/etc/default/keyboard`.
    pub keyboard_file: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        Self {
            passwd: "/etc/passwd".into(),
            login_defs: "/etc/login.defs".into(),
            icons_dir: "/var/lib/AccountsService/icons".into(),
            sessions_dir: "/usr/share/wayland-sessions".into(),
            state_dir: "/var/lib/lugh-greeter".into(),
            config_file: "/etc/lugh/greeter.toml".into(),
            keyboard_file: "/etc/default/keyboard".into(),
        }
    }
}

/// How to start the backend.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// greetd's socket (`$GREETD_SOCK`). Ignored in demo mode.
    pub socket: Option<PathBuf>,
    /// Fake users and a built-in fake greetd; password [`DEMO_PASSWORD`].
    pub demo: bool,
    /// Where things live.
    pub paths: Paths,
    /// Socket timeouts.
    pub timeouts: Timeouts,
    /// `$XKB_DEFAULT_LAYOUT`, if set.
    pub xkb_layout: Option<String>,
}

/// `/etc/lugh/greeter.toml`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct GreeterConfig {
    /// Show a username field instead of the user list.
    pub hide_users: bool,
}

impl GreeterConfig {
    /// Parses the file's text; anything wrong gives the default.
    #[must_use]
    pub fn parse(text: &str) -> Self {
        toml::from_str(text).unwrap_or_default()
    }
}

/// XKB layouts: `$XKB_DEFAULT_LAYOUT` (what cage uses), else `XKBLAYOUT` in
/// the text of `/etc/default/keyboard`, else `us`.
#[must_use]
pub fn parse_layouts(env: Option<&str>, keyboard_file: Option<&str>) -> Vec<String> {
    let split = |list: &str| -> Vec<String> {
        list.split(',')
            .map(|s| s.trim().trim_matches('"').trim_matches('\'').trim())
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    };
    let from_env = env.map(split).unwrap_or_default();
    if !from_env.is_empty() {
        return from_env;
    }
    let from_file = keyboard_file
        .and_then(|text| {
            text.lines()
                .filter_map(|line| line.trim().strip_prefix("XKBLAYOUT="))
                .next_back()
        })
        .map(split)
        .unwrap_or_default();
    if from_file.is_empty() {
        vec!["us".to_owned()]
    } else {
        from_file
    }
}

/// Everything the UI needs when it starts.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Initial {
    /// Accounts to list.
    pub users: Vec<UserEntry>,
    /// Admin asked for a username field.
    pub hide_users: bool,
    /// User to preselect, `""` for the first.
    pub last_user: String,
    /// Installed sessions (never empty).
    pub sessions: Vec<Session>,
    /// Session id to preselect.
    pub last_session: String,
    /// Machine name.
    pub host_name: String,
    /// File URL of the greeter's wallpaper copy, `""` for the default.
    pub wallpaper: String,
    /// XKB layouts.
    pub layouts: Vec<String>,
    /// Active layout (the first: cage has no runtime switch).
    pub layout: String,
    /// Demo mode.
    pub demo: bool,
}

/// Something the UI must hear about.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(
    tag = "event",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Event {
    /// `authenticating` / `sessionUser` / `lastUser` changed. Always sent
    /// before the signal-like event it belongs to.
    State {
        /// A login attempt is running.
        authenticating: bool,
        /// User of the open greetd session, `""` when none.
        session_user: String,
        /// Set after a successful authentication.
        #[serde(skip_serializing_if = "Option::is_none")]
        last_user: Option<String>,
    },
    /// logind's answers arrived.
    Power {
        /// `CanReboot` is `yes`.
        can_reboot: bool,
        /// `CanPowerOff` is `yes`.
        can_power_off: bool,
    },
    /// greetd asks for input.
    PromptRequested {
        /// Hide the input.
        secret: bool,
        /// The prompt.
        text: String,
    },
    /// PAM chatter to show.
    InfoMessage {
        /// The text.
        text: String,
    },
    /// Authentication worked; `startSession` may be called.
    AuthSucceeded,
    /// Wrong credentials; the greetd session is already cancelled.
    AuthFailed {
        /// Plain-language message.
        message: String,
    },
    /// greetd accepted `start_session`: the greeter must exit now.
    SessionStarted,
    /// IPC failure or refused power action.
    ErrorOccurred {
        /// Plain-language message.
        message: String,
    },
}

enum Command {
    Create(String),
    Respond(Zeroizing<String>),
    Cancel,
    Start(String),
    Power(Action),
}

/// Handle to the worker thread.
#[derive(Debug)]
pub struct Backend {
    commands: Sender<Command>,
    initial: Initial,
}

fn demo_users() -> Vec<UserEntry> {
    [
        ("amara", "Amara Nkusi"),
        ("jeanpaul", "Jean-Paul Habimana"),
        ("keza", "Keza Uwase"),
    ]
    .into_iter()
    .map(|(user, real)| UserEntry {
        user_name: user.to_owned(),
        real_name: real.to_owned(),
        avatar: String::new(),
    })
    .collect()
}

fn host_name() -> String {
    ["/proc/sys/kernel/hostname", "/etc/hostname"]
        .iter()
        .filter_map(|path| fs::read_to_string(path).ok())
        .map(|text| text.trim().to_owned())
        .find(|name| !name.is_empty())
        .unwrap_or_default()
}

fn wallpaper(state_dir: &Path) -> String {
    [
        "wallpaper.jpg",
        "wallpaper.png",
        "wallpaper.webp",
        "wallpaper",
    ]
    .iter()
    .map(|name| state_dir.join(name))
    .find(|path| path.is_file() && fs::File::open(path).is_ok())
    .map(|path| users::file_url(&path))
    .unwrap_or_default()
}

impl Backend {
    /// Reads users, sessions and state, then starts the worker. `emit` is
    /// called on the worker thread for every [`Event`].
    pub fn start(options: Options, emit: impl Fn(Event) + Send + 'static) -> Self {
        let paths = &options.paths;
        let config = fs::read_to_string(&paths.config_file)
            .map(|text| GreeterConfig::parse(&text))
            .unwrap_or_default();
        let users = if options.demo {
            demo_users()
        } else {
            users::load(&paths.passwd, &paths.login_defs, &paths.icons_dir)
        };
        let mut sessions = sessions::load(&paths.sessions_dir);
        if sessions.is_empty() {
            // Never leave the user without a way in.
            sessions.push(Session {
                id: DEFAULT_SESSION.to_owned(),
                name: "Lugh".to_owned(),
                comment: "The Lugh desktop".to_owned(),
                exec: "lugh-session".to_owned(),
                desktop_names: vec!["Lugh".to_owned()],
            });
        }
        let state = State::load(&paths.state_dir.join("state.json"));
        let last_user = if config.hide_users || users.iter().any(|u| u.user_name == state.last_user)
        {
            state.last_user
        } else {
            String::new()
        };
        let last_session = sessions
            .iter()
            .find(|s| s.id == state.last_session)
            .or(sessions.first())
            .map(|s| s.id.clone())
            .unwrap_or_default();
        let layouts = parse_layouts(
            options.xkb_layout.as_deref(),
            fs::read_to_string(&paths.keyboard_file).ok().as_deref(),
        );
        let initial = Initial {
            hide_users: config.hide_users,
            last_user,
            last_session,
            host_name: host_name(),
            wallpaper: wallpaper(&paths.state_dir),
            layout: layouts.first().cloned().unwrap_or_default(),
            layouts,
            demo: options.demo,
            users,
            sessions,
        };

        let (commands, inbox) = mpsc::channel();
        let worker = Worker {
            listed: !initial.hide_users && initial.users.len() <= MAX_LISTED_USERS,
            users: initial.users.iter().map(|u| u.user_name.clone()).collect(),
            sessions: initial.sessions.clone(),
            options,
            login: None,
            session_user: String::new(),
            demo_greetd: None,
            emit: Box::new(emit),
        };
        let spawned = thread::Builder::new()
            .name("greetd-worker".into())
            .spawn(move || worker.run(&inbox));
        if let Err(err) = spawned {
            tracing::error!(%err, "could not start the greetd worker");
        }
        Self { commands, initial }
    }

    /// The start-up state.
    #[must_use]
    pub fn initial(&self) -> &Initial {
        &self.initial
    }

    /// The start-up state as JSON, for the QML adapter.
    #[must_use]
    pub fn initial_json(&self) -> String {
        serde_json::to_string(&self.initial).unwrap_or_else(|_| "{}".to_owned())
    }

    /// Runs a contract function: `createSession(user)`, `respond(text)`,
    /// `cancelSession()`, `startSession(exec)`, `reboot()`, `powerOff()`.
    /// Returns false for an unknown method. Results arrive as events.
    pub fn call(&self, method: &str, arg: String) -> bool {
        let command = match method {
            "createSession" => Command::Create(arg),
            "respond" => Command::Respond(Zeroizing::new(arg)),
            "cancelSession" => Command::Cancel,
            "startSession" => Command::Start(arg),
            "reboot" => Command::Power(Action::Reboot),
            "powerOff" => Command::Power(Action::PowerOff),
            _ => return false,
        };
        self.commands.send(command).is_ok()
    }
}

struct Worker {
    options: Options,
    users: Vec<String>,
    listed: bool,
    sessions: Vec<Session>,
    login: Option<Login<UnixStream>>,
    session_user: String,
    demo_greetd: Option<(FakeGreetd, PathBuf)>,
    emit: Box<dyn Fn(Event) + Send>,
}

impl Worker {
    fn run(mut self, inbox: &Receiver<Command>) {
        let (can_reboot, can_power_off) = if self.options.demo {
            (true, true)
        } else {
            (power::can(Action::Reboot), power::can(Action::PowerOff))
        };
        (self.emit)(Event::Power {
            can_reboot,
            can_power_off,
        });
        while let Ok(command) = inbox.recv() {
            match command {
                Command::Create(user) => self.create(user),
                Command::Respond(answer) => self.respond(answer),
                Command::Cancel => self.cancel(),
                Command::Start(exec) => self.start(&exec),
                Command::Power(action) => self.power(action),
            }
        }
        // The UI is gone: do not leave a half-open session behind.
        self.cancel();
    }

    fn set_state(&self, authenticating: bool, last_user: Option<String>) {
        (self.emit)(Event::State {
            authenticating,
            session_user: self.session_user.clone(),
            last_user,
        });
    }

    fn reset(&mut self) {
        self.session_user.clear();
        self.set_state(false, None);
    }

    fn error(&self, message: &str) {
        (self.emit)(Event::ErrorOccurred {
            message: message.to_owned(),
        });
    }

    fn socket(&mut self) -> Result<PathBuf, IpcError> {
        if !self.options.demo {
            return self
                .options
                .socket
                .clone()
                .ok_or(IpcError::State("GREETD_SOCK is not set"));
        }
        if let Some((_, path)) = &self.demo_greetd {
            return Ok(path.clone());
        }
        let path =
            std::env::temp_dir().join(format!("lugh-greeter-demo-{}.sock", std::process::id()));
        let config = FakeConfig {
            users: demo_users()
                .into_iter()
                .map(|u| (u.user_name, DEMO_PASSWORD.to_owned()))
                .collect::<HashMap<_, _>>(),
            delay: Duration::from_millis(500),
            ..FakeConfig::default()
        };
        let fake = FakeGreetd::spawn(&path, config)?;
        self.demo_greetd = Some((fake, path.clone()));
        Ok(path)
    }

    fn connect(&mut self) -> Result<&mut Login<UnixStream>, IpcError> {
        let login = match self.login.take() {
            Some(login) => login,
            None => {
                let socket = self.socket()?;
                Login::new(Client::connect(&socket, self.options.timeouts)?)
            }
        };
        Ok(self.login.insert(login))
    }

    fn notice(emit: &dyn Fn(Event)) -> impl FnMut(Notice) + '_ {
        move |notice| emit(Event::InfoMessage { text: notice.text })
    }

    fn create(&mut self, user: String) {
        self.session_user = user.clone();
        self.set_state(true, None);
        let step = match self.connect() {
            Ok(_) => self.with_login(|login, notice| login.create_session(&user, notice)),
            Err(err) => Err(err),
        };
        self.after(step);
    }

    fn respond(&mut self, answer: Zeroizing<String>) {
        if !self.login.as_ref().is_some_and(Login::is_prompting) {
            self.error(MSG_NO_LOGIN);
            return;
        }
        let step = self.with_login(|login, notice| login.respond(answer, notice));
        self.after(step);
    }

    /// Runs `f` on the open login, forwarding PAM notices as events.
    fn with_login(
        &mut self,
        f: impl FnOnce(&mut Login<UnixStream>, &mut dyn FnMut(Notice)) -> Result<Step, IpcError>,
    ) -> Result<Step, IpcError> {
        let Some(login) = self.login.as_mut() else {
            return Err(IpcError::State("not connected"));
        };
        let mut notice = Self::notice(&*self.emit);
        f(login, &mut notice)
    }

    fn after(&mut self, step: Result<Step, IpcError>) {
        match step {
            Ok(Step::Prompt { secret, text }) => {
                (self.emit)(Event::PromptRequested { secret, text });
            }
            Ok(Step::Authenticated) => {
                self.set_state(false, Some(self.session_user.clone()));
                (self.emit)(Event::AuthSucceeded);
            }
            Ok(Step::Failed { auth, description }) => {
                // PAM's text can tell an attacker more than the UI should.
                tracing::info!(auth, %description, "greetd refused the login");
                let listed = self.listed && self.users.contains(&self.session_user);
                self.reset();
                if auth {
                    (self.emit)(Event::AuthFailed {
                        message: if listed {
                            MSG_WRONG_PASSWORD.to_owned()
                        } else {
                            MSG_WRONG_USER_OR_PASSWORD.to_owned()
                        },
                    });
                } else {
                    self.error(MSG_UNAVAILABLE);
                }
            }
            Err(err) => self.fail(&err, MSG_UNAVAILABLE),
        }
    }

    fn fail(&mut self, err: &IpcError, message: &str) {
        tracing::warn!(%err, "greetd conversation failed");
        if err.is_fatal() {
            // The stream may be out of step: start over with a new connection.
            self.login = None;
        }
        self.reset();
        self.error(message);
    }

    fn cancel(&mut self) {
        if let Some(login) = self.login.as_mut()
            && let Err(err) = login.cancel()
        {
            tracing::warn!(%err, "cancel_session failed");
            self.login = None;
        }
        if !self.session_user.is_empty() {
            self.reset();
        }
    }

    fn start(&mut self, exec: &str) {
        let Some(login) = self.login.as_mut().filter(|l| l.is_authenticated()) else {
            self.error(MSG_NO_LOGIN);
            return;
        };
        let session = self.sessions.iter().find(|s| s.exec == exec);
        let cmd = sessions::split_exec(exec);
        if cmd.is_empty() {
            self.error(MSG_START_FAILED);
            return;
        }
        let mut env = vec!["XDG_SESSION_TYPE=wayland".to_owned()];
        if let Some(session) = session {
            env.push(format!("XDG_SESSION_DESKTOP={}", session.id));
            if !session.desktop_names.is_empty() {
                env.push(format!(
                    "XDG_CURRENT_DESKTOP={}",
                    session.desktop_names.join(":")
                ));
            }
        }
        match login.start_session(cmd, env) {
            Ok(()) => {
                if !self.options.demo {
                    let state = State {
                        last_user: self.session_user.clone(),
                        last_session: session.map(|s| s.id.clone()).unwrap_or_default(),
                    };
                    if let Err(err) = state.save(&self.options.paths.state_dir.join("state.json")) {
                        tracing::warn!(%err, "could not save the greeter state");
                    }
                }
                (self.emit)(Event::SessionStarted);
            }
            Err(err) => self.fail(&err, MSG_START_FAILED),
        }
    }

    fn power(&self, action: Action) {
        if self.options.demo {
            self.error(MSG_DEMO_POWER);
        } else if let Err(err) = power::run(action) {
            tracing::warn!(%err, ?action, "power action failed");
            self.error(MSG_POWER_REFUSED);
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some((_, path)) = &self.demo_greetd {
            let _ = fs::remove_file(path);
        }
    }
}

impl std::fmt::Debug for Worker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Worker")
            .field("session_user", &self.session_user)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts() {
        assert_eq!(parse_layouts(Some("us,fr"), None), ["us", "fr"]);
        assert_eq!(parse_layouts(Some(" "), Some("XKBLAYOUT=\"de\"\n")), ["de"]);
        assert_eq!(
            parse_layouts(
                None,
                Some("# x\nXKBMODEL=\"pc105\"\nXKBLAYOUT=\"us, rw\"\n")
            ),
            ["us", "rw"]
        );
        assert_eq!(parse_layouts(None, Some("XKBLAYOUT=\"\"\n")), ["us"]);
        assert_eq!(parse_layouts(None, None), ["us"]);
    }

    #[test]
    fn config() {
        assert!(GreeterConfig::parse("hide_users = true\n").hide_users);
        assert!(!GreeterConfig::parse("").hide_users);
        assert!(!GreeterConfig::parse("hide_users = \"yes\"").hide_users);
        assert!(!GreeterConfig::parse("\0 not toml [[[").hide_users);
        assert!(GreeterConfig::parse("other = 1\nhide_users = true").hide_users);
    }

    #[test]
    fn events_are_camel_case_json() {
        let json = |e: &Event| serde_json::to_string(e).unwrap();
        assert_eq!(
            json(&Event::PromptRequested {
                secret: true,
                text: "Password:".into()
            }),
            r#"{"event":"promptRequested","secret":true,"text":"Password:"}"#
        );
        assert_eq!(
            json(&Event::State {
                authenticating: false,
                session_user: "a".into(),
                last_user: None
            }),
            r#"{"event":"state","authenticating":false,"sessionUser":"a"}"#
        );
        assert_eq!(
            json(&Event::Power {
                can_reboot: true,
                can_power_off: false
            }),
            r#"{"event":"power","canReboot":true,"canPowerOff":false}"#
        );
        assert_eq!(
            json(&Event::SessionStarted),
            r#"{"event":"sessionStarted"}"#
        );
    }
}
