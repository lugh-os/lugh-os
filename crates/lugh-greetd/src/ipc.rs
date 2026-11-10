//! greetd IPC client (greetd-ipc(7)).
//!
//! Wire format: a native-endian `u32` payload length, then that many bytes of
//! JSON. The greeter sends [`Request`]s and reads one [`Response`] per request.
//!
//! [`Login`] runs the conversation on top of a [`Client`]:
//!
//! ```text
//! create_session ─► auth_message (secret/visible) ─► post_auth_message_response ─┐
//!        │                 ▲  info/error are acknowledged automatically         │
//!        │                 └─────────────────────────────────────────────────────┘
//!        ├─► success ─► start_session ─► success  (the greeter then exits)
//!        └─► error   ─► cancel_session            (next attempt starts over)
//! ```

use std::fmt;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

/// Largest payload accepted in either direction.
pub const MAX_FRAME_LEN: usize = 1024 * 1024;

/// Most `info`/`error` PAM messages acknowledged in a row before giving up.
const MAX_INFO_MESSAGES: usize = 64;

/// A greeter → greetd message.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    /// Starts a login attempt for `username`.
    CreateSession {
        /// Login name.
        username: String,
    },
    /// Answers the last `auth_message` (`None` acknowledges info/error).
    PostAuthMessageResponse {
        /// The typed answer, if the message asked for one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        response: Option<String>,
    },
    /// Starts the authenticated session with `cmd`, adding `env` (`K=V`).
    StartSession {
        /// Command line, already split.
        cmd: Vec<String>,
        /// Extra environment, `KEY=value`.
        #[serde(default)]
        env: Vec<String>,
    },
    /// Drops the session being configured.
    CancelSession,
}

impl fmt::Debug for Request {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CreateSession { username } => f
                .debug_struct("CreateSession")
                .field("username", username)
                .finish(),
            // Never print what the user typed.
            Self::PostAuthMessageResponse { response } => f
                .debug_struct("PostAuthMessageResponse")
                .field("response", &response.as_ref().map(|_| "<redacted>"))
                .finish(),
            Self::StartSession { cmd, env } => f
                .debug_struct("StartSession")
                .field("cmd", cmd)
                .field("env", env)
                .finish(),
            Self::CancelSession => f.write_str("CancelSession"),
        }
    }
}

/// Kind of greetd `error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorType {
    /// Authentication failed (wrong password, unknown user, ...).
    AuthError,
    /// Anything else.
    Error,
}

/// Kind of greetd `auth_message`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMessageType {
    /// Asks for input that may be shown.
    Visible,
    /// Asks for input that must be hidden.
    Secret,
    /// Information, no answer wanted.
    Info,
    /// An error text, no answer wanted.
    Error,
}

/// A greetd → greeter message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    /// The request worked.
    Success,
    /// The request failed.
    Error {
        /// Why, roughly.
        error_type: ErrorType,
        /// greetd's (PAM's) text.
        description: String,
    },
    /// PAM wants to say or ask something.
    AuthMessage {
        /// What kind.
        auth_message_type: AuthMessageType,
        /// The text.
        auth_message: String,
    },
}

/// What can go wrong talking to greetd.
#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    /// Could not connect or lost the connection.
    #[error("greetd socket: {0}")]
    Io(#[from] io::Error),
    /// greetd did not answer in time.
    #[error("greetd did not answer in time")]
    Timeout,
    /// greetd closed the connection.
    #[error("greetd closed the connection")]
    Closed,
    /// A frame longer than [`MAX_FRAME_LEN`].
    #[error("frame of {0} bytes is over the 1 MiB limit")]
    FrameTooLarge(usize),
    /// A frame that is not a known message.
    #[error("malformed greetd message: {0}")]
    Protocol(String),
    /// A call that does not fit the conversation state.
    #[error("{0}")]
    State(&'static str),
    /// greetd refused `start_session`; the session was cancelled.
    #[error("greetd refused to start the session: {0}")]
    Refused(String),
}

impl IpcError {
    /// True when the connection can no longer be trusted and must be reopened.
    #[must_use]
    pub fn is_fatal(&self) -> bool {
        !matches!(self, Self::State(_) | Self::Refused(_))
    }
}

fn map_io(err: io::Error) -> IpcError {
    match err.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => IpcError::Timeout,
        io::ErrorKind::UnexpectedEof
        | io::ErrorKind::BrokenPipe
        | io::ErrorKind::ConnectionReset => IpcError::Closed,
        _ => IpcError::Io(err),
    }
}

/// Wraps `payload` in a frame.
pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, IpcError> {
    if payload.len() > MAX_FRAME_LEN {
        return Err(IpcError::FrameTooLarge(payload.len()));
    }
    let len = u32::try_from(payload.len()).map_err(|_| IpcError::FrameTooLarge(payload.len()))?;
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&len.to_ne_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

/// Looks for one complete frame at the start of `buf`.
///
/// Returns the payload and the number of bytes used, `None` when more bytes
/// are needed, or an error when the announced length is over the limit.
pub fn decode_frame(buf: &[u8]) -> Result<Option<(&[u8], usize)>, IpcError> {
    let Some(header) = buf.first_chunk::<4>() else {
        return Ok(None);
    };
    let len = usize::try_from(u32::from_ne_bytes(*header)).unwrap_or(usize::MAX);
    if len > MAX_FRAME_LEN {
        return Err(IpcError::FrameTooLarge(len));
    }
    Ok(buf.get(4..4 + len).map(|payload| (payload, 4 + len)))
}

/// Parses a response payload.
pub fn decode_response(payload: &[u8]) -> Result<Response, IpcError> {
    serde_json::from_slice(payload).map_err(|e| IpcError::Protocol(e.to_string()))
}

/// Parses a request payload (used by the fake server).
pub fn decode_request(payload: &[u8]) -> Result<Request, IpcError> {
    // serde_json's error can quote the input; keep it out (it may hold a password).
    serde_json::from_slice(payload).map_err(|e| IpcError::Protocol(format!("{:?}", e.classify())))
}

/// Reads one frame, coping with short reads.
pub fn read_frame<R: Read>(reader: &mut R) -> Result<Vec<u8>, IpcError> {
    let mut header = [0_u8; 4];
    reader.read_exact(&mut header).map_err(map_io)?;
    let len = usize::try_from(u32::from_ne_bytes(header)).unwrap_or(usize::MAX);
    if len > MAX_FRAME_LEN {
        return Err(IpcError::FrameTooLarge(len));
    }
    let mut payload = vec![0_u8; len];
    reader.read_exact(&mut payload).map_err(map_io)?;
    Ok(payload)
}

/// Writes one frame.
pub fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> Result<(), IpcError> {
    let frame = Zeroizing::new(encode_frame(payload)?);
    writer.write_all(&frame).map_err(map_io)?;
    writer.flush().map_err(map_io)
}

/// Socket timeouts.
#[derive(Debug, Clone, Copy)]
pub struct Timeouts {
    /// Longest wait for an answer. PAM can be slow (fail delay, fingerprint).
    pub read: Duration,
    /// Longest wait to send a request.
    pub write: Duration,
}

impl Default for Timeouts {
    fn default() -> Self {
        Self {
            read: Duration::from_secs(120),
            write: Duration::from_secs(5),
        }
    }
}

/// One connection to greetd: send a request, read its response.
#[derive(Debug)]
pub struct Client<S> {
    stream: S,
}

impl Client<UnixStream> {
    /// Connects to greetd's socket (`$GREETD_SOCK`).
    pub fn connect(path: &Path, timeouts: Timeouts) -> Result<Self, IpcError> {
        let stream = UnixStream::connect(path)?;
        stream.set_read_timeout(Some(timeouts.read))?;
        stream.set_write_timeout(Some(timeouts.write))?;
        Ok(Self { stream })
    }
}

impl<S: Read + Write> Client<S> {
    /// Wraps an already connected stream.
    pub fn new(stream: S) -> Self {
        Self { stream }
    }

    /// Sends `request` and waits for greetd's response.
    pub fn request(&mut self, request: &Request) -> Result<Response, IpcError> {
        let payload = Zeroizing::new(
            serde_json::to_vec(request).map_err(|e| IpcError::Protocol(e.to_string()))?,
        );
        write_frame(&mut self.stream, &payload)?;
        let mut answer = read_frame(&mut self.stream)?;
        let response = decode_response(&answer);
        answer.zeroize();
        response
    }
}

/// Result of a step of the login conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// greetd asks a question; answer with [`Login::respond`].
    Prompt {
        /// Hide the typed answer.
        secret: bool,
        /// PAM's prompt, such as `Password:`.
        text: String,
    },
    /// Authentication is done; call [`Login::start_session`].
    Authenticated,
    /// greetd said no. The session has been cancelled already.
    Failed {
        /// True for `auth_error` (wrong credentials).
        auth: bool,
        /// greetd's text, for the log.
        description: String,
    },
}

/// An `info` or `error` text from PAM that needs no answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    /// True for `error`, false for `info`.
    pub error: bool,
    /// The text.
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Prompting,
    Authenticated,
    Started,
}

/// The login conversation with greetd.
#[derive(Debug)]
pub struct Login<S> {
    client: Client<S>,
    phase: Phase,
}

impl<S: Read + Write> Login<S> {
    /// Starts with no session open.
    pub fn new(client: Client<S>) -> Self {
        Self {
            client,
            phase: Phase::Idle,
        }
    }

    /// True while a greetd session is open (being configured or ready).
    #[must_use]
    pub fn is_open(&self) -> bool {
        matches!(self.phase, Phase::Prompting | Phase::Authenticated)
    }

    /// True when greetd waits for an answer to a prompt.
    #[must_use]
    pub fn is_prompting(&self) -> bool {
        self.phase == Phase::Prompting
    }

    /// True when authentication succeeded and the session can be started.
    #[must_use]
    pub fn is_authenticated(&self) -> bool {
        self.phase == Phase::Authenticated
    }

    /// `create_session`. Cancels an open session first.
    pub fn create_session(
        &mut self,
        username: &str,
        notice: &mut dyn FnMut(Notice),
    ) -> Result<Step, IpcError> {
        if self.phase == Phase::Started {
            return Err(IpcError::State("the session has already started"));
        }
        if self.is_open() {
            self.cancel()?;
        }
        let response = self.client.request(&Request::CreateSession {
            username: username.to_owned(),
        })?;
        self.advance(response, notice)
    }

    /// `post_auth_message_response` with the user's answer.
    pub fn respond(
        &mut self,
        answer: Zeroizing<String>,
        notice: &mut dyn FnMut(Notice),
    ) -> Result<Step, IpcError> {
        if self.phase != Phase::Prompting {
            return Err(IpcError::State("no prompt is waiting for an answer"));
        }
        let mut answer = answer;
        // Moves the text out (no copy); the request's copy is wiped below.
        let mut request = Request::PostAuthMessageResponse {
            response: Some(std::mem::take(&mut *answer)),
        };
        let response = self.client.request(&request);
        if let Request::PostAuthMessageResponse {
            response: Some(text),
        } = &mut request
        {
            text.zeroize();
        }
        self.advance(response?, notice)
    }

    /// `start_session`. On refusal the session is cancelled and
    /// [`IpcError::Refused`] is returned.
    pub fn start_session(&mut self, cmd: Vec<String>, env: Vec<String>) -> Result<(), IpcError> {
        if self.phase != Phase::Authenticated {
            return Err(IpcError::State("not authenticated"));
        }
        match self.client.request(&Request::StartSession { cmd, env })? {
            Response::Success => {
                self.phase = Phase::Started;
                Ok(())
            }
            Response::Error { description, .. } => {
                self.cancel()?;
                Err(IpcError::Refused(description))
            }
            Response::AuthMessage { .. } => Err(IpcError::Protocol(
                "auth_message after start_session".into(),
            )),
        }
    }

    /// `cancel_session`. A no-op when nothing is open.
    pub fn cancel(&mut self) -> Result<(), IpcError> {
        if !self.is_open() {
            return Ok(());
        }
        self.phase = Phase::Idle;
        // greetd answers `error` when there was nothing to cancel; both are fine.
        match self.client.request(&Request::CancelSession)? {
            Response::Success | Response::Error { .. } => Ok(()),
            Response::AuthMessage { .. } => Err(IpcError::Protocol(
                "auth_message after cancel_session".into(),
            )),
        }
    }

    fn advance(
        &mut self,
        mut response: Response,
        notice: &mut dyn FnMut(Notice),
    ) -> Result<Step, IpcError> {
        for _ in 0..=MAX_INFO_MESSAGES {
            match response {
                Response::Success => {
                    self.phase = Phase::Authenticated;
                    return Ok(Step::Authenticated);
                }
                Response::Error {
                    error_type,
                    description,
                } => {
                    // greetd keeps the failed session until it is cancelled.
                    self.phase = Phase::Prompting;
                    self.cancel()?;
                    return Ok(Step::Failed {
                        auth: error_type == ErrorType::AuthError,
                        description,
                    });
                }
                Response::AuthMessage {
                    auth_message_type: kind @ (AuthMessageType::Secret | AuthMessageType::Visible),
                    auth_message,
                } => {
                    self.phase = Phase::Prompting;
                    return Ok(Step::Prompt {
                        secret: kind == AuthMessageType::Secret,
                        text: auth_message,
                    });
                }
                Response::AuthMessage {
                    auth_message_type: kind,
                    auth_message,
                } => {
                    self.phase = Phase::Prompting;
                    notice(Notice {
                        error: kind == AuthMessageType::Error,
                        text: auth_message,
                    });
                    response = self
                        .client
                        .request(&Request::PostAuthMessageResponse { response: None })?;
                }
            }
        }
        self.phase = Phase::Prompting;
        self.cancel()?;
        Err(IpcError::Protocol("too many info messages in a row".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Small deterministic PRNG (xorshift64*), enough for fuzz-ish tests.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }
        fn bytes(&mut self, max: usize) -> Vec<u8> {
            let len = usize::try_from(self.next()).unwrap_or(0) % (max + 1);
            (0..len).map(|_| self.next().to_le_bytes()[0]).collect()
        }
    }

    #[test]
    fn requests_serialize_like_greetd_expects() {
        let json = |r: &Request| serde_json::to_string(r).unwrap();
        assert_eq!(
            json(&Request::CreateSession {
                username: "amara".into()
            }),
            r#"{"type":"create_session","username":"amara"}"#
        );
        assert_eq!(
            json(&Request::PostAuthMessageResponse {
                response: Some("pw".into())
            }),
            r#"{"type":"post_auth_message_response","response":"pw"}"#
        );
        assert_eq!(
            json(&Request::PostAuthMessageResponse { response: None }),
            r#"{"type":"post_auth_message_response"}"#
        );
        assert_eq!(
            json(&Request::StartSession {
                cmd: vec!["lugh-session".into()],
                env: vec!["A=b".into()]
            }),
            r#"{"type":"start_session","cmd":["lugh-session"],"env":["A=b"]}"#
        );
        assert_eq!(
            json(&Request::CancelSession),
            r#"{"type":"cancel_session"}"#
        );
    }

    #[test]
    fn responses_parse() {
        assert_eq!(
            decode_response(br#"{"type":"success"}"#).unwrap(),
            Response::Success
        );
        assert_eq!(
            decode_response(
                br#"{"type":"error","error_type":"auth_error","description":"pam says no"}"#
            )
            .unwrap(),
            Response::Error {
                error_type: ErrorType::AuthError,
                description: "pam says no".into()
            }
        );
        for (name, kind) in [
            ("visible", AuthMessageType::Visible),
            ("secret", AuthMessageType::Secret),
            ("info", AuthMessageType::Info),
            ("error", AuthMessageType::Error),
        ] {
            let text = format!(
                r#"{{"type":"auth_message","auth_message_type":"{name}","auth_message":"m"}}"#
            );
            assert_eq!(
                decode_response(text.as_bytes()).unwrap(),
                Response::AuthMessage {
                    auth_message_type: kind,
                    auth_message: "m".into()
                }
            );
        }
        assert!(decode_response(br#"{"type":"nope"}"#).is_err());
        assert!(decode_response(b"").is_err());
    }

    #[test]
    fn debug_never_shows_the_answer() {
        let text = format!(
            "{:?}",
            Request::PostAuthMessageResponse {
                response: Some("hunter2".into())
            }
        );
        assert!(!text.contains("hunter2"), "{text}");
    }

    #[test]
    fn frame_round_trip_and_limits() {
        let frame = encode_frame(b"{}").unwrap();
        assert_eq!(decode_frame(&frame).unwrap(), Some((&b"{}"[..], 6)));
        for cut in 0..frame.len() {
            assert_eq!(decode_frame(&frame[..cut]).unwrap(), None);
        }
        assert!(matches!(
            encode_frame(&vec![0; MAX_FRAME_LEN + 1]),
            Err(IpcError::FrameTooLarge(_))
        ));
        let huge = u32::MAX.to_ne_bytes();
        assert!(matches!(
            decode_frame(&huge),
            Err(IpcError::FrameTooLarge(_))
        ));
        assert!(matches!(
            read_frame(&mut Cursor::new(huge.to_vec())),
            Err(IpcError::FrameTooLarge(_))
        ));
    }

    /// A reader that hands out one byte per call.
    struct Trickle(Cursor<Vec<u8>>);
    impl Read for Trickle {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = buf.len().min(1);
            self.0.read(&mut buf[..n])
        }
    }

    #[test]
    fn read_frame_survives_short_reads_and_truncation() {
        let frame = encode_frame(br#"{"type":"success"}"#).unwrap();
        let mut trickle = Trickle(Cursor::new(frame.clone()));
        let payload = read_frame(&mut trickle).unwrap();
        assert_eq!(decode_response(&payload).unwrap(), Response::Success);
        for cut in 0..frame.len() {
            let err = read_frame(&mut Cursor::new(frame[..cut].to_vec())).unwrap_err();
            assert!(matches!(err, IpcError::Closed), "cut {cut}: {err}");
        }
    }

    #[test]
    fn random_input_never_panics() {
        let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
        for _ in 0..20_000 {
            let bytes = rng.bytes(96);
            let _ = decode_response(&bytes);
            let _ = decode_request(&bytes);
            if let Ok(Some((payload, used))) = decode_frame(&bytes) {
                assert!(used <= bytes.len());
                let _ = decode_response(payload);
            }
            if let Ok(payload) = read_frame(&mut Cursor::new(bytes)) {
                let _ = decode_response(&payload);
            }
        }
    }

    #[test]
    fn mutated_valid_messages_never_panic() {
        let mut rng = Rng(42);
        let seeds: [&[u8]; 3] = [
            br#"{"type":"success"}"#,
            br#"{"type":"error","error_type":"auth_error","description":"no"}"#,
            br#"{"type":"auth_message","auth_message_type":"secret","auth_message":"Password:"}"#,
        ];
        for round in 0..20_000_usize {
            let mut frame = encode_frame(seeds[round % seeds.len()]).unwrap();
            let flips = 1 + usize::try_from(rng.next() % 4).unwrap();
            for _ in 0..flips {
                let at = usize::try_from(rng.next()).unwrap_or(0) % frame.len();
                frame[at] = rng.next().to_le_bytes()[0];
            }
            let cut = usize::try_from(rng.next()).unwrap_or(0) % (frame.len() + 1);
            if rng.next().is_multiple_of(3) {
                frame.truncate(cut);
            }
            let mut client = Client::new(ReadOnly(Cursor::new(frame)));
            let _ = client.request(&Request::CancelSession);
        }
    }

    /// Reads from the cursor, swallows writes.
    struct ReadOnly(Cursor<Vec<u8>>);
    impl Read for ReadOnly {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.0.read(buf)
        }
    }
    impl Write for ReadOnly {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn scripted(responses: &[&str]) -> Login<ReadOnly> {
        let mut bytes = Vec::new();
        for r in responses {
            bytes.extend(encode_frame(r.as_bytes()).unwrap());
        }
        Login::new(Client::new(ReadOnly(Cursor::new(bytes))))
    }

    #[test]
    fn state_machine_rejects_out_of_order_calls() {
        let mut login = scripted(&[]);
        let mut none = |_: Notice| {};
        assert!(matches!(
            login.respond(Zeroizing::new("x".into()), &mut none),
            Err(IpcError::State(_))
        ));
        assert!(matches!(
            login.start_session(vec!["x".into()], vec![]),
            Err(IpcError::State(_))
        ));
        login.cancel().unwrap(); // nothing open: no request sent
    }

    #[test]
    fn state_machine_happy_path_with_notices() {
        let mut login = scripted(&[
            r#"{"type":"auth_message","auth_message_type":"info","auth_message":"hi"}"#,
            r#"{"type":"auth_message","auth_message_type":"secret","auth_message":"Password:"}"#,
            r#"{"type":"success"}"#,
            r#"{"type":"success"}"#,
        ]);
        let mut notices = Vec::new();
        let step = login
            .create_session("amara", &mut |n| notices.push(n))
            .unwrap();
        assert_eq!(
            step,
            Step::Prompt {
                secret: true,
                text: "Password:".into()
            }
        );
        assert_eq!(
            notices,
            [Notice {
                error: false,
                text: "hi".into()
            }]
        );
        let step = login
            .respond(Zeroizing::new("pw".into()), &mut |_| {})
            .unwrap();
        assert_eq!(step, Step::Authenticated);
        assert!(login.is_authenticated());
        login
            .start_session(vec!["lugh-session".into()], vec![])
            .unwrap();
        assert!(!login.is_open());
        assert!(matches!(
            login.create_session("amara", &mut |_| {}),
            Err(IpcError::State(_))
        ));
    }

    #[test]
    fn endless_info_messages_are_cut_off() {
        let info = r#"{"type":"auth_message","auth_message_type":"info","auth_message":"x"}"#;
        let many: Vec<&str> = std::iter::repeat_n(info, MAX_INFO_MESSAGES + 2)
            .chain([r#"{"type":"success"}"#])
            .collect();
        let mut login = scripted(&many);
        let err = login.create_session("amara", &mut |_| {}).unwrap_err();
        assert!(matches!(err, IpcError::Protocol(_)), "{err}");
        assert!(!login.is_open());
    }
}
