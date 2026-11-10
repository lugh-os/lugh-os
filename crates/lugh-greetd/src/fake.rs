//! A scripted greetd for tests, the end-to-end check and `--demo`.
//!
//! It speaks the real wire protocol on a Unix socket and behaves like greetd
//! with `pam_unix`: every user is asked for a password, unknown users fail
//! only after answering (no account probing), a failed session must be
//! cancelled before the next `create_session`.

use std::collections::HashMap;
use std::io;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use crate::ipc::{
    AuthMessageType, ErrorType, Request, Response, decode_request, read_frame, write_frame,
};

/// How the fake behaves.
#[derive(Debug, Clone, Default)]
pub struct FakeConfig {
    /// User name → password.
    pub users: HashMap<String, String>,
    /// Users that get the long conversation: an `info` message, the password
    /// (`secret`), then a one-time code (`visible`) that must equal
    /// [`FakeConfig::otp`].
    pub multi_prompt_users: Vec<String>,
    /// The one-time code for [`FakeConfig::multi_prompt_users`].
    pub otp: String,
    /// Refuse every `start_session`.
    pub fail_start: bool,
    /// Wait this long before answering an auth response (PAM is not instant).
    pub delay: Duration,
}

impl FakeConfig {
    /// A config with one `user` / `password` pair.
    #[must_use]
    pub fn with_user(user: &str, password: &str) -> Self {
        let mut config = Self::default();
        config.users.insert(user.to_owned(), password.to_owned());
        config
    }
}

/// What the fake saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Seen {
    /// A request (its `Debug` output hides typed answers).
    Request(Request),
    /// `start_session` was accepted for `user`.
    Started {
        /// The authenticated user.
        user: String,
        /// The command.
        cmd: Vec<String>,
        /// The extra environment.
        env: Vec<String>,
    },
    /// A client disconnected.
    Disconnected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ask {
    Info,
    Password,
    Otp,
}

#[derive(Debug, Default)]
struct Session {
    user: String,
    /// Questions left, the first being the one already sent.
    pending: Vec<Ask>,
    good: bool,
    authenticated: bool,
}

#[derive(Debug)]
struct Shared {
    config: FakeConfig,
    session: Mutex<Option<Session>>,
    seen: Mutex<Sender<Seen>>,
}

/// Handle to a running fake greetd. The server threads live until the
/// process ends.
#[derive(Debug)]
pub struct FakeGreetd {
    seen: Receiver<Seen>,
}

fn error(error_type: ErrorType, description: &str) -> Response {
    Response::Error {
        error_type,
        description: description.to_owned(),
    }
}

fn ask(kind: Ask) -> Response {
    let (auth_message_type, text) = match kind {
        Ask::Info => (AuthMessageType::Info, "Your password expires in 3 days."),
        Ask::Password => (AuthMessageType::Secret, "Password:"),
        Ask::Otp => (AuthMessageType::Visible, "One-time code:"),
    };
    Response::AuthMessage {
        auth_message_type,
        auth_message: text.to_owned(),
    }
}

impl Shared {
    fn note(&self, seen: Seen) {
        let sender = self.seen.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = sender.send(seen);
    }

    fn handle(&self, request: Request) -> Response {
        self.note(Seen::Request(request.clone()));
        let mut slot = self.session.lock().unwrap_or_else(PoisonError::into_inner);
        match request {
            Request::CreateSession { username } => {
                if slot.is_some() {
                    return error(ErrorType::Error, "a session is already being configured");
                }
                let pending = if self.config.multi_prompt_users.contains(&username) {
                    vec![Ask::Info, Ask::Password, Ask::Otp]
                } else {
                    vec![Ask::Password]
                };
                let first = pending[0];
                *slot = Some(Session {
                    user: username,
                    pending,
                    good: true,
                    authenticated: false,
                });
                ask(first)
            }
            Request::PostAuthMessageResponse { response } => {
                let Some(session) = slot.as_mut() else {
                    return error(ErrorType::Error, "no session under configuration");
                };
                if session.authenticated || session.pending.is_empty() {
                    return error(ErrorType::Error, "no auth message to answer");
                }
                let answered = session.pending.remove(0);
                let expected = match answered {
                    Ask::Info => None,
                    Ask::Password => Some(self.config.users.get(&session.user).cloned()),
                    Ask::Otp => Some(Some(self.config.otp.clone())),
                };
                if let Some(expected) = expected {
                    session.good &= expected.is_some() && expected == response;
                    thread::sleep(self.config.delay);
                }
                match session.pending.first() {
                    Some(next) => ask(*next),
                    None if session.good => {
                        session.authenticated = true;
                        Response::Success
                    }
                    None => error(ErrorType::AuthError, "pam_authenticate: AUTH_ERR"),
                }
            }
            Request::StartSession { cmd, env } => match slot.as_ref() {
                Some(session) if session.authenticated => {
                    if self.config.fail_start || cmd.is_empty() {
                        return error(ErrorType::Error, "session could not be started");
                    }
                    let user = session.user.clone();
                    *slot = None;
                    self.note(Seen::Started { user, cmd, env });
                    Response::Success
                }
                _ => error(ErrorType::Error, "session is not ready"),
            },
            Request::CancelSession => {
                *slot = None;
                Response::Success
            }
        }
    }

    fn serve(&self, mut stream: UnixStream) {
        while let Ok(payload) = read_frame(&mut stream) {
            let response = match decode_request(&payload) {
                Ok(request) => self.handle(request),
                Err(err) => error(ErrorType::Error, &err.to_string()),
            };
            let Ok(bytes) = serde_json::to_vec(&response) else {
                break;
            };
            if write_frame(&mut stream, &bytes).is_err() {
                break;
            }
        }
        self.note(Seen::Disconnected);
    }
}

impl FakeGreetd {
    /// Binds `socket` and serves clients on background threads.
    pub fn spawn(socket: &Path, config: FakeConfig) -> io::Result<Self> {
        let _ = std::fs::remove_file(socket);
        let listener = UnixListener::bind(socket)?;
        let (sender, seen) = mpsc::channel();
        let shared = Arc::new(Shared {
            config,
            session: Mutex::new(None),
            seen: Mutex::new(sender),
        });
        thread::Builder::new()
            .name("fake-greetd".into())
            .spawn(move || {
                for stream in listener.incoming().flatten() {
                    let shared = Arc::clone(&shared);
                    let _ = thread::Builder::new()
                        .name("fake-greetd-client".into())
                        .spawn(move || shared.serve(stream));
                }
            })?;
        Ok(Self { seen })
    }

    /// Waits for the next thing the fake saw.
    #[must_use]
    pub fn next(&self, timeout: Duration) -> Option<Seen> {
        self.seen.recv_timeout(timeout).ok()
    }

    /// Everything seen so far, without waiting.
    #[must_use]
    pub fn drain(&self) -> Vec<Seen> {
        self.seen.try_iter().collect()
    }
}
