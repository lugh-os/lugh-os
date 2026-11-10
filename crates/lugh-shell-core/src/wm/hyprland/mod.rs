//! Hyprland IPC adapter (Phases 1–4, ADR-012).
//!
//! Hyprland exposes two Unix sockets in
//! `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/` (before 0.40:
//! `/tmp/hypr/<signature>/`):
//!
//! - `.socket.sock`: one request per connection (`j/clients`,
//!   `dispatch workspace 2`, `[[BATCH]]cmd;cmd`), answered and closed.
//! - `.socket2.sock`: a stream of `EVENT>>DATA\n` lines, parsed by
//!   [`parse_event`].
//!
//! The event reader thread reconnects with exponential backoff when the
//! socket drops and then emits [`WmEvent::Reconnected`].

mod event;
mod json;

use std::ffi::OsStr;
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::Duration;

use serde::de::DeserializeOwned;

pub use event::parse_event;

use super::{
    CompositorAdapter, EventStream, Toplevel, WindowId, WmError, WmEvent, WmSnapshot, Workspace,
    WorkspaceId,
};
use json::{Client, MonitorJson, WorkspaceJson, WsRef};

/// Request socket file name.
pub const REQUEST_SOCKET: &str = ".socket.sock";
/// Event socket file name.
pub const EVENT_SOCKET: &str = ".socket2.sock";

/// Longest accepted event line; longer lines are dropped.
const MAX_EVENT_LINE: usize = 64 * 1024;
/// Largest accepted request reply.
const MAX_REPLY: u64 = 16 * 1024 * 1024;
/// How often the event reader checks whether its stream was dropped.
const POLL: Duration = Duration::from_millis(200);
const BACKOFF_START: Duration = Duration::from_millis(100);
const BACKOFF_MAX: Duration = Duration::from_secs(5);

/// Finds the socket directory for an instance signature: the first of
/// `<runtime_dir>/hypr/<sig>` and `/tmp/hypr/<sig>` for which `exists`
/// holds. Kept free of process state for testing; see
/// [`HyprlandAdapter::from_env`].
pub fn resolve_socket_dir(
    runtime_dir: Option<&OsStr>,
    signature: Option<&OsStr>,
    exists: impl Fn(&Path) -> bool,
) -> Result<PathBuf, WmError> {
    let sig = signature
        .filter(|s| !s.is_empty())
        .ok_or_else(|| WmError::Unavailable("HYPRLAND_INSTANCE_SIGNATURE is not set".into()))?;
    let sig_path = Path::new(sig);
    if sig_path.components().count() != 1 || sig_path.file_name() != Some(sig) {
        return Err(WmError::Unavailable(format!(
            "invalid HYPRLAND_INSTANCE_SIGNATURE {sig:?}"
        )));
    }
    let mut candidates = Vec::with_capacity(2);
    if let Some(rt) = runtime_dir.map(Path::new).filter(|p| p.is_absolute()) {
        candidates.push(rt.join("hypr").join(sig));
    }
    candidates.push(Path::new("/tmp/hypr").join(sig));
    candidates
        .iter()
        .find(|dir| exists(&dir.join(REQUEST_SOCKET)))
        .cloned()
        .ok_or_else(|| {
            WmError::Unavailable(format!("no Hyprland socket in {}", show_paths(&candidates)))
        })
}

fn show_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(" or ")
}

/// [`CompositorAdapter`] over Hyprland's IPC sockets.
#[derive(Debug, Clone)]
pub struct HyprlandAdapter {
    dir: PathBuf,
    timeout: Duration,
}

impl HyprlandAdapter {
    /// Locates the running instance through `HYPRLAND_INSTANCE_SIGNATURE`
    /// and `XDG_RUNTIME_DIR`.
    pub fn from_env() -> Result<Self, WmError> {
        let rt = std::env::var_os("XDG_RUNTIME_DIR");
        let sig = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE");
        let dir = resolve_socket_dir(rt.as_deref(), sig.as_deref(), Path::exists)?;
        Ok(Self::with_socket_dir(dir))
    }

    /// Uses the sockets in `dir` (tests, or a known instance).
    pub fn with_socket_dir(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            timeout: Duration::from_secs(2),
        }
    }

    /// Sets the per-request I/O timeout (default 2 s).
    #[must_use]
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// The socket directory in use.
    pub fn socket_dir(&self) -> &Path {
        &self.dir
    }

    /// Sends a raw request (e.g. `j/clients`, `dispatch exec foot`) and
    /// returns the reply text.
    pub fn request(&self, request: &str) -> Result<String, WmError> {
        let io = |context: &str| {
            let context = format!("{context} ({request})");
            move |source| WmError::Io { context, source }
        };
        let path = self.dir.join(REQUEST_SOCKET);
        let mut stream = UnixStream::connect(&path).map_err(io("connecting to Hyprland"))?;
        stream
            .set_read_timeout(Some(self.timeout))
            .and_then(|()| stream.set_write_timeout(Some(self.timeout)))
            .map_err(io("configuring the Hyprland socket"))?;
        stream
            .write_all(request.as_bytes())
            .map_err(io("writing to Hyprland"))?;
        let mut reply = Vec::new();
        (&mut stream)
            .take(MAX_REPLY)
            .read_to_end(&mut reply)
            .map_err(io("reading from Hyprland"))?;
        Ok(String::from_utf8_lossy(&reply).into_owned())
    }

    fn request_json<T: DeserializeOwned>(&self, request: &str) -> Result<T, WmError> {
        let reply = self.request(request)?;
        serde_json::from_str(&reply).map_err(|source| WmError::Json {
            request: request.to_owned(),
            source,
        })
    }

    /// Runs one dispatcher: `dispatch <dispatcher> <arg>`.
    pub fn dispatch(&self, dispatcher: &str, arg: &str) -> Result<(), WmError> {
        let request = format!("dispatch {dispatcher} {arg}");
        check_ok(&request, self.request(&request)?)
    }

    /// Runs several commands in one `[[BATCH]]` request; fails unless every
    /// one answers `ok`.
    pub fn batch(&self, commands: &[String]) -> Result<(), WmError> {
        if commands.is_empty() {
            return Ok(());
        }
        if let Some(bad) = commands.iter().find(|c| c.contains(';')) {
            return Err(WmError::InvalidArgument(format!(
                "batch command contains ';': {bad:?}"
            )));
        }
        let request = format!("[[BATCH]]{}", commands.join(";"));
        check_ok(&request, self.request(&request)?)
    }

    /// Mapped windows (`j/clients`).
    pub fn clients(&self) -> Result<Vec<Toplevel>, WmError> {
        let clients: Vec<Client> = self.request_json("j/clients")?;
        Ok(clients
            .into_iter()
            .filter_map(Client::into_toplevel)
            .collect())
    }
}

/// Address in the form Hyprland's `address:` selector accepts; rejects
/// anything that could smuggle extra arguments or commands.
fn address(id: &WindowId) -> Result<String, WmError> {
    let ok = id
        .as_str()
        .strip_prefix("0x")
        .is_some_and(|hex| !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit()));
    if ok {
        Ok(format!("address:{}", id.as_str()))
    } else {
        Err(WmError::InvalidArgument(format!(
            "not a Hyprland window address: {:?}",
            id.as_str()
        )))
    }
}

fn regular(ws: WorkspaceId) -> Result<i64, WmError> {
    if ws.0 >= 1 {
        Ok(ws.0)
    } else {
        Err(WmError::InvalidArgument(format!(
            "workspace {ws} is not a regular workspace"
        )))
    }
}

/// Every reply in a (batch) answer must be `ok`.
fn check_ok(request: &str, reply: String) -> Result<(), WmError> {
    let all_ok = !reply.trim().is_empty()
        && reply.split_whitespace().all(|tok| {
            tok.len().is_multiple_of(2) && tok.as_bytes().chunks(2).all(|pair| pair == b"ok")
        });
    if all_ok {
        Ok(())
    } else {
        Err(WmError::Rejected {
            request: request.to_owned(),
            reply: reply.trim().to_owned(),
        })
    }
}

impl CompositorAdapter for HyprlandAdapter {
    fn snapshot(&self) -> Result<WmSnapshot, WmError> {
        let toplevels = self.clients()?;
        let workspaces: Vec<WorkspaceJson> = self.request_json("j/workspaces")?;
        let monitors: Vec<MonitorJson> = self.request_json("j/monitors")?;
        let active_window: Client = self.request_json("j/activewindow")?;
        let active_ws: WsRef = self.request_json("j/activeworkspace")?;

        let mut workspaces: Vec<Workspace> = workspaces.into_iter().map(Workspace::from).collect();
        workspaces.sort_by_key(|w| w.id);
        let focused = active_window
            .address
            .as_deref()
            .and_then(WindowId::from_hyprland);
        let toplevels = toplevels
            .into_iter()
            .map(|mut t| {
                t.focused = focused.as_ref() == Some(&t.id);
                t
            })
            .collect();
        Ok(WmSnapshot {
            workspaces,
            toplevels,
            monitors: monitors
                .into_iter()
                .filter_map(MonitorJson::into_monitor)
                .collect(),
            active_workspace: active_ws.id.map(WorkspaceId),
            focused,
        })
    }

    fn subscribe(&self) -> Result<EventStream, WmError> {
        let path = self.dir.join(EVENT_SOCKET);
        let stream = UnixStream::connect(&path).map_err(|source| WmError::Io {
            context: format!("connecting to {}", path.display()),
            source,
        })?;
        let (tx, rx) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let reader = EventReader {
            path,
            tx,
            stop: Arc::clone(&stop),
        };
        std::thread::Builder::new()
            .name("lugh-wm-events".into())
            .spawn(move || reader.run(stream))
            .map_err(|source| WmError::Io {
                context: "spawning the event reader".into(),
                source,
            })?;
        Ok(EventStream::new(rx, stop))
    }

    fn activate(&self, id: &WindowId) -> Result<(), WmError> {
        self.dispatch("focuswindow", &address(id)?)
    }

    fn close(&self, id: &WindowId) -> Result<(), WmError> {
        self.dispatch("closewindow", &address(id)?)
    }

    fn switch_workspace(&self, ws: WorkspaceId) -> Result<(), WmError> {
        self.dispatch("workspace", &regular(ws)?.to_string())
    }

    fn move_to_workspace(&self, id: &WindowId, ws: WorkspaceId) -> Result<(), WmError> {
        let arg = format!("{},{}", regular(ws)?, address(id)?);
        self.dispatch("movetoworkspacesilent", &arg)
    }

    fn toggle_floating(&self, id: &WindowId) -> Result<(), WmError> {
        self.dispatch("togglefloating", &address(id)?)
    }

    fn toggle_workspace_tiling(&self, ws: WorkspaceId) -> Result<bool, WmError> {
        let on_ws: Vec<Toplevel> = self
            .clients()?
            .into_iter()
            .filter(|t| t.workspace == ws)
            .collect();
        let tile = on_ws.iter().any(|t| t.floating);
        let dispatcher = if tile { "settiled" } else { "setfloating" };
        let commands = on_ws
            .iter()
            .map(|t| Ok(format!("dispatch {dispatcher} {}", address(&t.id)?)))
            .collect::<Result<Vec<_>, WmError>>()?;
        self.batch(&commands)?;
        Ok(tile)
    }

    fn reload(&self) -> Result<(), WmError> {
        check_ok("reload", self.request("reload")?)
    }
}

/// Background reader of `.socket2.sock`.
struct EventReader {
    path: PathBuf,
    tx: Sender<WmEvent>,
    stop: Arc<AtomicBool>,
}

enum ReadEnd {
    /// The stream was dropped (or asked to stop).
    Stopped,
    /// The socket closed or failed; reconnect.
    Lost,
}

impl EventReader {
    fn run(self, first: UnixStream) {
        let mut stream = first;
        loop {
            match self.read_lines(stream) {
                ReadEnd::Stopped => return,
                ReadEnd::Lost => {}
            }
            tracing::warn!(path = %self.path.display(), "Hyprland event socket lost, reconnecting");
            match self.reconnect() {
                Some(s) => {
                    stream = s;
                    if self.tx.send(WmEvent::Reconnected).is_err() {
                        return;
                    }
                }
                None => return,
            }
        }
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    /// Reconnects with exponential backoff; `None` once stopped.
    fn reconnect(&self) -> Option<UnixStream> {
        let mut delay = BACKOFF_START;
        loop {
            // Sleep in short slices so a dropped stream ends the thread quickly.
            let mut slept = Duration::ZERO;
            while slept < delay {
                if self.stopped() {
                    return None;
                }
                let step = POLL.min(delay - slept);
                std::thread::sleep(step);
                slept += step;
            }
            match UnixStream::connect(&self.path) {
                Ok(s) => {
                    tracing::info!("Hyprland event socket reconnected");
                    return Some(s);
                }
                Err(e) => tracing::debug!(error = %e, ?delay, "Hyprland event socket unavailable"),
            }
            delay = (delay * 2).min(BACKOFF_MAX);
        }
    }

    fn read_lines(&self, stream: UnixStream) -> ReadEnd {
        if let Err(e) = stream.set_read_timeout(Some(POLL)) {
            tracing::warn!(error = %e, "cannot set a read timeout on the event socket");
            return ReadEnd::Lost;
        }
        let mut reader = BufReader::with_capacity(8 * 1024, stream);
        let mut line = Vec::with_capacity(256);
        let mut skipping = false;
        loop {
            if self.stopped() {
                return ReadEnd::Stopped;
            }
            let chunk = match reader.fill_buf() {
                Ok([]) => return ReadEnd::Lost,
                Ok(chunk) => chunk,
                Err(e)
                    if matches!(
                        e.kind(),
                        ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                    ) =>
                {
                    continue;
                }
                Err(e) => {
                    tracing::warn!(error = %e, "reading Hyprland events failed");
                    return ReadEnd::Lost;
                }
            };
            let (used, complete) = match chunk.iter().position(|&b| b == b'\n') {
                Some(i) => {
                    if !skipping {
                        line.extend_from_slice(&chunk[..i]);
                    }
                    (i + 1, true)
                }
                None => {
                    if !skipping {
                        line.extend_from_slice(chunk);
                    }
                    (chunk.len(), false)
                }
            };
            reader.consume(used);
            if complete {
                if !skipping && !line.is_empty() {
                    let ev = parse_event(&String::from_utf8_lossy(&line));
                    if let WmEvent::Unknown { name, .. } = &ev {
                        tracing::trace!(event = %name, "unhandled Hyprland event");
                    }
                    if self.tx.send(ev).is_err() {
                        return ReadEnd::Stopped;
                    }
                }
                line.clear();
                skipping = false;
            } else if line.len() > MAX_EVENT_LINE {
                tracing::warn!("dropping an over-long Hyprland event line");
                line.clear();
                skipping = true;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_dir_prefers_runtime_dir() {
        let got = resolve_socket_dir(
            Some(OsStr::new("/run/user/1000")),
            Some(OsStr::new("abc_123_456")),
            |_| true,
        )
        .unwrap();
        assert_eq!(got, Path::new("/run/user/1000/hypr/abc_123_456"));
    }

    #[test]
    fn socket_dir_falls_back_to_tmp() {
        let got = resolve_socket_dir(
            Some(OsStr::new("/run/user/1000")),
            Some(OsStr::new("sig")),
            |p| p.starts_with("/tmp"),
        )
        .unwrap();
        assert_eq!(got, Path::new("/tmp/hypr/sig"));
        let got = resolve_socket_dir(None, Some(OsStr::new("sig")), |_| true).unwrap();
        assert_eq!(got, Path::new("/tmp/hypr/sig"));
    }

    #[test]
    fn socket_dir_errors() {
        let err = |rt: Option<&str>, sig: Option<&str>| {
            resolve_socket_dir(rt.map(OsStr::new), sig.map(OsStr::new), |_| true).is_err()
        };
        assert!(err(Some("/run/user/1000"), None));
        assert!(err(Some("/run/user/1000"), Some("")));
        assert!(err(Some("/run/user/1000"), Some("../../etc")));
        assert!(err(Some("/run/user/1000"), Some("a/b")));
        assert!(
            resolve_socket_dir(Some(OsStr::new("/r")), Some(OsStr::new("s")), |_| false).is_err()
        );
    }

    #[test]
    fn addresses_are_validated() {
        assert_eq!(address(&WindowId::new("0x55aa")).unwrap(), "address:0x55aa");
        for bad in ["55aa", "0x", "0x55aa;reload", "0x55 aa", ""] {
            assert!(address(&WindowId::new(bad)).is_err(), "{bad}");
        }
        assert!(regular(WorkspaceId(0)).is_err());
        assert!(regular(WorkspaceId(-98)).is_err());
        assert_eq!(regular(WorkspaceId(3)).unwrap(), 3);
    }

    #[test]
    fn ok_replies() {
        assert!(check_ok("x", "ok".into()).is_ok());
        assert!(check_ok("x", "ok\n\nok\n\nok".into()).is_ok());
        assert!(check_ok("x", "okok".into()).is_ok());
        assert!(check_ok("x", "".into()).is_err());
        assert!(check_ok("x", "ok\n\nNo such window found".into()).is_err());
        assert!(check_ok("x", "Invalid dispatcher".into()).is_err());
    }
}
