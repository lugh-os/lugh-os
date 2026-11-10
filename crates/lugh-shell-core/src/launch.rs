//! Starting apps, each in its own systemd scope (ADR-015).
//!
//! 1. [`exec_to_argv`] turns a desktop entry's `Exec` value into an argument
//!    vector (Desktop Entry spec §The Exec key: quoting and field codes).
//! 2. [`AppLauncher::launch`] spawns it detached in its own process group,
//!    then asks the user's systemd to adopt the process into a transient
//!    `app-lugh-<appid>-<random>.scope` ([`scope_unit_name`]) in `app.slice`
//!    through `org.freedesktop.systemd1.Manager.StartTransientUnit`. The
//!    scope gives Lugh Tasks exact per-app grouping and Shield per-app limits.
//!
//! When the session bus or systemd is unavailable the app keeps running
//! outside a scope and a warning is logged: launching never fails for that.
//!
//! Known limit: a process that forks before it is moved into its scope
//! leaves those children in the shell's cgroup (the same race every
//! desktop that adopts PIDs after spawning has).

use std::fmt;
use std::hash::{BuildHasher, Hasher};
use std::io;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Unit-name prefix of app scopes (systemd XDG convention: `app-<launcher>-`).
pub const SCOPE_PREFIX: &str = "app-lugh-";

/// systemd's limit on unit-name length.
pub const UNIT_NAME_MAX: usize = 255;

/// Terminal emulators tried, in order, after `$TERMINAL`.
pub const FALLBACK_TERMINALS: &[&str] = &["foot", "x-terminal-emulator"];

/// Errors from building a command line or starting an app.
#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    /// The `Exec` value cannot be parsed.
    #[error("invalid Exec value {exec:?}: {reason}")]
    InvalidExec {
        /// The value.
        exec: String,
        /// What is wrong with it.
        reason: &'static str,
    },

    /// Nothing to run.
    #[error("empty command line")]
    EmptyCommand,

    /// `Terminal=true` but no terminal emulator is installed.
    #[error("no terminal emulator found ($TERMINAL, foot, x-terminal-emulator)")]
    NoTerminal,

    /// The process could not be started.
    #[error("cannot start {program}: {source}")]
    Spawn {
        /// Program name.
        program: String,
        /// Underlying error.
        #[source]
        source: io::Error,
    },
}

/// Errors from creating a scope. [`AppLauncher::launch`] only logs these.
#[derive(Debug, thiserror::Error)]
pub enum ScopeError {
    /// The session bus or systemd refused or failed the call.
    #[error("StartTransientUnit failed: {0}")]
    Bus(#[from] zbus::Error),
}

// ---------------------------------------------------------------------------
// Exec line
// ---------------------------------------------------------------------------

/// A piece of one argument while tokenising: field codes are expanded in
/// both, but only an unquoted, stand-alone `%F`/`%U`/`%i` becomes several
/// arguments.
#[derive(Debug)]
struct Arg {
    text: String,
    quoted: bool,
}

/// Splits an `Exec` value into arguments per the Desktop Entry spec: space
/// separated; `"…"` quotes, inside which `\"`, `` \` ``, `\$` and `\\` are
/// escapes. A backslash outside quotes escapes the next character (as a
/// shell would), which the spec does not require but real entries rely on.
///
/// `exec` must already have the desktop-file string escapes (`\s`, `\n`,
/// `\t`, `\r`, `\\`) decoded, as any desktop-entry parser does.
fn tokenize(exec: &str) -> Result<Vec<Arg>, LaunchError> {
    let invalid = |reason| LaunchError::InvalidExec {
        exec: exec.to_owned(),
        reason,
    };
    let mut args = Vec::new();
    let mut cur: Option<Arg> = None;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' | '\n' => args.extend(cur.take()),
            '"' => {
                let arg = cur.get_or_insert_with(|| Arg {
                    text: String::new(),
                    quoted: false,
                });
                arg.quoted = true;
                loop {
                    match chars.next() {
                        None => return Err(invalid("unterminated quote")),
                        Some('"') => break,
                        Some('\\') => match chars.peek() {
                            Some(&e @ ('"' | '`' | '$' | '\\')) => {
                                arg.text.push(e);
                                chars.next();
                            }
                            _ => arg.text.push('\\'),
                        },
                        Some(other) => arg.text.push(other),
                    }
                }
            }
            '\\' => {
                let arg = cur.get_or_insert_with(|| Arg {
                    text: String::new(),
                    quoted: false,
                });
                arg.text.push(chars.next().unwrap_or('\\'));
            }
            other => cur
                .get_or_insert_with(|| Arg {
                    text: String::new(),
                    quoted: false,
                })
                .text
                .push(other),
        }
    }
    args.extend(cur);
    Ok(args)
}

/// Converts a `file://` URL to a local path (percent-decoded); `None` for
/// other schemes or remote hosts.
pub fn file_url_to_path(url: &str) -> Option<String> {
    let rest = url.strip_prefix("file://")?;
    let path = if rest.starts_with('/') {
        rest
    } else {
        rest.strip_prefix("localhost")?
    };
    if !path.starts_with('/') {
        return None;
    }
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| char::from(b).to_digit(16);
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push(u8::try_from(h * 16 + l).unwrap_or(b'?'));
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}

/// Builds the argument vector for a desktop entry.
///
/// - `exec`: the `Exec` value (desktop-file string escapes already decoded).
/// - `files` / `urls`: what to open. `%f`/`%F` receive `files` plus local
///   `file://` URLs converted to paths; `%u`/`%U` receive `urls` plus
///   `files` (a path is a valid `%u` argument).
/// - `icon`: the `Icon` value, for `%i` (`--icon <icon>`).
/// - `name`: the translated `Name`, for `%c`.
/// - `desktop_path`: the `.desktop` file, for `%k`.
///
/// Field codes: `%f %F %u %U %i %c %k %%`. The deprecated `%d %D %n %N %v %m`
/// and unknown codes are removed. A stand-alone unquoted `%f`/`%u`/`%c`/`%k`
/// that expands to nothing is dropped; a quoted one becomes an empty
/// argument. `%F`/`%U`/`%i` embedded in a longer argument expand to their
/// first value only. When only `%f`/`%u` is present and several items are
/// given, the first is used (the spec would start one instance per item).
pub fn exec_to_argv(
    exec: &str,
    files: &[String],
    urls: &[String],
    icon: Option<&str>,
    name: &str,
    desktop_path: Option<&Path>,
) -> Result<Vec<String>, LaunchError> {
    let file_args: Vec<String> = files
        .iter()
        .cloned()
        .chain(urls.iter().filter_map(|u| file_url_to_path(u)))
        .collect();
    let url_args: Vec<String> = urls.iter().chain(files).cloned().collect();
    let icon = icon.filter(|i| !i.is_empty());
    let desktop = desktop_path.map(|p| p.to_string_lossy().into_owned());

    let mut argv = Vec::new();
    for arg in tokenize(exec)? {
        if !arg.quoted {
            let list = match arg.text.as_str() {
                "%F" => Some(file_args.clone()),
                "%U" => Some(url_args.clone()),
                "%i" => Some(
                    icon.map(|i| vec!["--icon".to_owned(), i.to_owned()])
                        .unwrap_or_default(),
                ),
                _ => None,
            };
            if let Some(list) = list {
                argv.extend(list);
                continue;
            }
        }
        let mut out = String::with_capacity(arg.text.len());
        let mut had_code = false;
        let mut chars = arg.text.chars();
        while let Some(c) = chars.next() {
            if c != '%' {
                out.push(c);
                continue;
            }
            let Some(code) = chars.next() else {
                out.push('%');
                break;
            };
            if code == '%' {
                out.push('%');
                continue;
            }
            had_code = true;
            match code {
                'f' | 'F' => out.push_str(file_args.first().map_or("", String::as_str)),
                'u' | 'U' => out.push_str(url_args.first().map_or("", String::as_str)),
                'i' => out.push_str(icon.unwrap_or_default()),
                'c' => out.push_str(name),
                'k' => out.push_str(desktop.as_deref().unwrap_or_default()),
                'd' | 'D' | 'n' | 'N' | 'v' | 'm' => {}
                other => tracing::debug!(code = %other, exec, "dropping unknown field code"),
            }
        }
        if out.is_empty() && had_code && !arg.quoted {
            continue;
        }
        argv.push(out);
    }
    if argv.is_empty() {
        return Err(LaunchError::EmptyCommand);
    }
    Ok(argv)
}

// ---------------------------------------------------------------------------
// Unit names
// ---------------------------------------------------------------------------

/// Escapes a string for use inside a unit name, like `systemd-escape`:
/// ASCII letters, digits, `:`, `_` and `.` (except a leading `.`) stay; `/`
/// becomes `-`; every other byte, including `-`, becomes `\xNN`.
///
/// At most `max` bytes are produced; an escape sequence is never cut.
pub fn escape_unit_component(s: &str, max: usize) -> String {
    let mut out = String::with_capacity(s.len().min(max));
    for (i, b) in s.bytes().enumerate() {
        let keep = b.is_ascii_alphanumeric() || b == b':' || b == b'_' || (b == b'.' && i > 0);
        let piece = if keep {
            char::from(b).to_string()
        } else if b == b'/' {
            "-".to_owned()
        } else {
            format!("\\x{b:02x}")
        };
        if out.len() + piece.len() > max {
            break;
        }
        out.push_str(&piece);
    }
    out
}

/// A fresh scope name for an app: `app-lugh-<escaped app id>-<16 hex>.scope`,
/// at most [`UNIT_NAME_MAX`] bytes (long app ids are truncated).
pub fn scope_unit_name(app_id: &str) -> String {
    scope_unit_name_with(app_id, &random_hex())
}

fn scope_unit_name_with(app_id: &str, random: &str) -> String {
    const SUFFIX: &str = ".scope";
    let app_id = app_id.trim();
    let app_id = if app_id.is_empty() { "unknown" } else { app_id };
    let budget = UNIT_NAME_MAX - SCOPE_PREFIX.len() - 1 - random.len() - SUFFIX.len();
    format!(
        "{SCOPE_PREFIX}{}-{random}{SUFFIX}",
        escape_unit_component(app_id, budget)
    )
}

/// 64 random bits as hex, from std's per-process random hash keys mixed with
/// a counter, the pid and the time (no extra dependency needed for this).
fn random_hex() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
    h.write_u32(std::process::id());
    if let Ok(t) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        h.write_u128(t.as_nanos());
    }
    format!("{:016x}", h.finish())
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

/// Finds an executable: a name with a `/` is checked as is, others are
/// looked up in `$PATH`.
pub fn find_program(name: &str) -> Option<PathBuf> {
    let executable = |p: &Path| {
        use std::os::unix::fs::PermissionsExt;
        p.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if name.contains('/') {
        let p = PathBuf::from(name);
        return executable(&p).then_some(p);
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|p| executable(p))
}

/// Wraps `argv` in a terminal emulator: `$TERMINAL` (which may carry its own
/// options), then [`FALLBACK_TERMINALS`]. foot, footclient and kitty take
/// the command directly; others get `-e` (the `x-terminal-emulator`
/// convention).
pub fn terminal_argv(
    argv: &[String],
    terminal_env: Option<&str>,
    find: impl Fn(&str) -> Option<PathBuf>,
) -> Result<Vec<String>, LaunchError> {
    let from_env = terminal_env
        .map(|t| t.split_whitespace().map(str::to_owned).collect::<Vec<_>>())
        .filter(|words| !words.is_empty());
    let candidates = from_env
        .into_iter()
        .chain(FALLBACK_TERMINALS.iter().map(|t| vec![(*t).to_owned()]));
    for mut term in candidates {
        let Some(program) = term.first() else {
            continue;
        };
        if find(program).is_none() {
            continue;
        }
        let base = Path::new(program)
            .file_name()
            .map(|b| b.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !matches!(base.as_str(), "foot" | "footclient" | "kitty") {
            term.push("-e".to_owned());
        }
        term.extend(argv.iter().cloned());
        return Ok(term);
    }
    Err(LaunchError::NoTerminal)
}

// ---------------------------------------------------------------------------
// Scopes
// ---------------------------------------------------------------------------

/// Moves a running process into a new transient scope. Kept behind a trait
/// so launching is testable without a bus.
pub trait ScopeManager: Send + Sync + fmt::Debug {
    /// Creates `unit` containing `pid`.
    fn start_scope(&self, unit: &str, pid: u32, description: &str) -> Result<(), ScopeError>;
}

/// [`ScopeManager`] calling `StartTransientUnit` on the user's systemd over
/// the session bus. The connection is opened on first use and reopened after
/// a failure.
#[derive(Debug, Default)]
pub struct SystemdScopes {
    conn: Mutex<Option<zbus::blocking::Connection>>,
}

impl SystemdScopes {
    /// A manager that connects lazily.
    pub fn new() -> Self {
        Self::default()
    }

    fn connection(&self) -> Result<zbus::blocking::Connection, zbus::Error> {
        let mut guard = self
            .conn
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(conn) = guard.as_ref() {
            return Ok(conn.clone());
        }
        let conn = zbus::blocking::connection::Builder::session()?
            .method_timeout(Duration::from_secs(5))
            .build()?;
        *guard = Some(conn.clone());
        Ok(conn)
    }

    fn forget_connection(&self) {
        *self
            .conn
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }
}

impl ScopeManager for SystemdScopes {
    fn start_scope(&self, unit: &str, pid: u32, description: &str) -> Result<(), ScopeError> {
        use zbus::zvariant::Value;

        let conn = self.connection()?;
        let properties: Vec<(&str, Value<'_>)> = vec![
            ("PIDs", Value::from(vec![pid])),
            ("CollectMode", Value::from("inactive-or-failed")),
            ("Description", Value::from(description)),
            ("Slice", Value::from("app.slice")),
        ];
        let aux: Vec<(&str, Vec<(&str, Value<'_>)>)> = Vec::new();
        let result = conn.call_method(
            Some("org.freedesktop.systemd1"),
            "/org/freedesktop/systemd1",
            Some("org.freedesktop.systemd1.Manager"),
            "StartTransientUnit",
            &(unit, "fail", properties, aux),
        );
        match result {
            Ok(_) => Ok(()),
            Err(e) => {
                // A D-Bus error reply means the bus is fine; anything else
                // may be a dead connection, so open a new one next time.
                if !matches!(e, zbus::Error::MethodError(..)) {
                    self.forget_connection();
                }
                Err(e.into())
            }
        }
    }
}

impl<T: ScopeManager + ?Sized> ScopeManager for std::sync::Arc<T> {
    fn start_scope(&self, unit: &str, pid: u32, description: &str) -> Result<(), ScopeError> {
        (**self).start_scope(unit, pid, description)
    }
}

/// [`ScopeManager`] that does nothing (sessions without systemd, tests).
#[derive(Debug, Default, Clone, Copy)]
pub struct NoScopes;

impl ScopeManager for NoScopes {
    fn start_scope(&self, _unit: &str, _pid: u32, _description: &str) -> Result<(), ScopeError> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Launching
// ---------------------------------------------------------------------------

/// What to start.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaunchRequest {
    /// Desktop-entry id without `.desktop` (`org.codeberg.dnkl.foot`); names
    /// the scope.
    pub app_id: String,
    /// Argument vector, usually from [`exec_to_argv`].
    pub exec: Vec<String>,
    /// `Terminal=true`: run inside the default terminal emulator.
    pub terminal: bool,
    /// Working directory (`Path=`); the home directory when `None`.
    pub working_dir: Option<PathBuf>,
    /// Extra environment variables.
    pub env: Vec<(String, String)>,
    /// Scope description (the app's display name); defaults to the app id.
    pub description: Option<String>,
}

impl LaunchRequest {
    /// A request with no terminal, working directory or extra environment.
    pub fn new(app_id: impl Into<String>, exec: Vec<String>) -> Self {
        Self {
            app_id: app_id.into(),
            exec,
            ..Self::default()
        }
    }
}

/// A started app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchHandle {
    /// Process id of the started program (the terminal for `Terminal=true`).
    pub pid: u32,
    /// Scope unit name.
    pub unit: String,
    /// Whether the scope was created. `false` when systemd was unreachable;
    /// the app runs anyway.
    pub scoped: bool,
}

/// Starts apps in scopes through a [`ScopeManager`].
#[derive(Debug, Default)]
pub struct AppLauncher<S: ScopeManager = SystemdScopes> {
    scopes: S,
}

impl AppLauncher<SystemdScopes> {
    /// A launcher using the user's systemd.
    pub fn new() -> Self {
        Self::with_scopes(SystemdScopes::new())
    }
}

impl<S: ScopeManager> AppLauncher<S> {
    /// A launcher using `scopes`.
    pub fn with_scopes(scopes: S) -> Self {
        Self { scopes }
    }

    /// Spawns the app detached (own process group, stdin from `/dev/null`,
    /// reaped by a small background thread) and moves it into a new scope.
    /// Fails only when the process cannot be started.
    pub fn launch(&self, req: &LaunchRequest) -> Result<LaunchHandle, LaunchError> {
        let argv = if req.terminal {
            let term = std::env::var("TERMINAL").ok();
            terminal_argv(&req.exec, term.as_deref(), find_program)?
        } else {
            req.exec.clone()
        };
        let (program, args) = argv.split_first().ok_or(LaunchError::EmptyCommand)?;

        let mut cmd = Command::new(program);
        cmd.args(args).stdin(Stdio::null()).process_group(0);
        match &req.working_dir {
            Some(dir) if dir.is_dir() => {
                cmd.current_dir(dir);
            }
            other => {
                if let Some(dir) = other {
                    tracing::warn!(dir = %dir.display(), app = %req.app_id, "working directory missing, using home");
                }
                if let Some(home) = std::env::var_os("HOME") {
                    cmd.current_dir(home);
                }
            }
        }
        cmd.envs(req.env.iter().map(|(k, v)| (k, v)));

        let child = cmd.spawn().map_err(|source| LaunchError::Spawn {
            program: program.clone(),
            source,
        })?;
        let pid = child.id();
        reap(child);

        let unit = scope_unit_name(&req.app_id);
        let description = req.description.as_deref().unwrap_or(&req.app_id);
        let scoped = match self.scopes.start_scope(&unit, pid, description) {
            Ok(()) => {
                tracing::debug!(%unit, pid, "app started in its scope");
                true
            }
            Err(e) => {
                tracing::warn!(error = %e, %unit, pid, app = %req.app_id, "app runs without its own scope");
                false
            }
        };
        Ok(LaunchHandle { pid, unit, scoped })
    }
}

/// Waits for the child in the background so it never lingers as a zombie.
fn reap(mut child: Child) {
    let spawned = std::thread::Builder::new()
        .name("lugh-reap".into())
        .stack_size(64 * 1024)
        .spawn(move || {
            let _ = child.wait();
        });
    if let Err(e) = spawned {
        tracing::warn!(error = %e, "cannot start a reaper thread; the app may linger as a zombie when it exits");
    }
}

/// Launches with a process-wide [`AppLauncher`] on the user's systemd.
pub fn launch(req: &LaunchRequest) -> Result<LaunchHandle, LaunchError> {
    static LAUNCHER: OnceLock<AppLauncher> = OnceLock::new();
    LAUNCHER.get_or_init(AppLauncher::new).launch(req)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn argv(exec: &str) -> Vec<String> {
        exec_to_argv(exec, &[], &[], None, "App", None).unwrap()
    }

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| (*x).to_owned()).collect()
    }

    #[test]
    fn plain_and_quoted() {
        assert_eq!(argv("firefox"), s(&["firefox"]));
        assert_eq!(argv("  foot   -e  htop "), s(&["foot", "-e", "htop"]));
        assert_eq!(
            argv(r#""/opt/My App/bin/app" --name "a \"b\" \$c \\ \`d\`""#),
            s(&["/opt/My App/bin/app", "--name", r#"a "b" $c \ `d`"#])
        );
        assert_eq!(argv(r#"app --title="x y""#), s(&["app", "--title=x y"]));
        assert_eq!(argv(r#"app """#), s(&["app", ""]));
        assert_eq!(argv(r"app a\ b"), s(&["app", "a b"]));
        assert_eq!(argv(r#"sh -c "echo \q""#), s(&["sh", "-c", r"echo \q"]));
    }

    #[test]
    fn exec_errors() {
        assert!(matches!(
            exec_to_argv(r#"app "unterminated"#, &[], &[], None, "", None),
            Err(LaunchError::InvalidExec { .. })
        ));
        assert!(matches!(
            exec_to_argv("   ", &[], &[], None, "", None),
            Err(LaunchError::EmptyCommand)
        ));
        assert!(matches!(
            exec_to_argv("%U", &[], &[], None, "", None),
            Err(LaunchError::EmptyCommand)
        ));
    }

    #[test]
    fn field_codes() {
        let files = s(&["/home/a/My File.pdf", "/tmp/b.txt"]);
        let urls = s(&["https://lugh.example/x", "file:///home/a/c%20d.png"]);
        let desktop = Path::new("/usr/share/applications/app.desktop");
        let run = |exec: &str| {
            exec_to_argv(
                exec,
                &files,
                &urls,
                Some("app-icon"),
                "My App",
                Some(desktop),
            )
            .unwrap()
        };
        assert_eq!(
            run("app %F"),
            s(&[
                "app",
                "/home/a/My File.pdf",
                "/tmp/b.txt",
                "/home/a/c d.png"
            ])
        );
        assert_eq!(run("app %f"), s(&["app", "/home/a/My File.pdf"]));
        assert_eq!(
            run("app %U"),
            s(&[
                "app",
                "https://lugh.example/x",
                "file:///home/a/c%20d.png",
                "/home/a/My File.pdf",
                "/tmp/b.txt"
            ])
        );
        assert_eq!(
            run("app --url=%u"),
            s(&["app", "--url=https://lugh.example/x"])
        );
        assert_eq!(
            run("app %i %c %k"),
            s(&[
                "app",
                "--icon",
                "app-icon",
                "My App",
                "/usr/share/applications/app.desktop"
            ])
        );
        assert_eq!(run("app 100%% %d %D %n %N %v %m"), s(&["app", "100%"]));
        assert_eq!(run(r#"app "%c""#), s(&["app", "My App"]));
        assert_eq!(run("app %x"), s(&["app"]));
        assert_eq!(run("app 50%"), s(&["app", "50%"]));
    }

    #[test]
    fn missing_values_drop_arguments() {
        assert_eq!(argv("app %f %F %u %U %i"), s(&["app"]));
        assert_eq!(argv("app --file=%f"), s(&["app", "--file="]));
        assert_eq!(argv(r#"app "%f""#), s(&["app", ""]));
        assert_eq!(
            exec_to_argv("app %i", &[], &[], Some(""), "", None).unwrap(),
            s(&["app"])
        );
    }

    #[test]
    fn file_urls() {
        assert_eq!(file_url_to_path("file:///a/b%2Fc"), Some("/a/b/c".into()));
        assert_eq!(
            file_url_to_path("file://localhost/x%20y"),
            Some("/x y".into())
        );
        assert_eq!(file_url_to_path("file:///bad%zz%"), Some("/bad%zz%".into()));
        assert_eq!(file_url_to_path("file:///end%4"), Some("/end%4".into()));
        assert_eq!(file_url_to_path("file://server/share"), None);
        assert_eq!(file_url_to_path("https://x/y"), None);
    }

    #[test]
    fn unit_names() {
        assert_eq!(
            scope_unit_name_with("firefox", "0123456789abcdef"),
            "app-lugh-firefox-0123456789abcdef.scope"
        );
        assert_eq!(
            scope_unit_name_with("org.codeberg.dnkl.foot", "ab"),
            "app-lugh-org.codeberg.dnkl.foot-ab.scope"
        );
        assert_eq!(
            scope_unit_name_with("lugh-files", "ab"),
            r"app-lugh-lugh\x2dfiles-ab.scope"
        );
        assert_eq!(
            scope_unit_name_with(".hidden app/é", "ab"),
            r"app-lugh-\x2ehidden\x20app-\xc3\xa9-ab.scope"
        );
        assert_eq!(
            scope_unit_name_with("  ", "ab"),
            "app-lugh-unknown-ab.scope"
        );

        let long = scope_unit_name(&"-".repeat(500));
        assert!(long.len() <= UNIT_NAME_MAX, "{}", long.len());
        assert!(long.starts_with(SCOPE_PREFIX) && long.ends_with(".scope"));
        let middle = &long[SCOPE_PREFIX.len()..long.len() - ".scope".len() - 17];
        assert!(middle.len().is_multiple_of(4), "no escape sequence is cut");

        let a = scope_unit_name("firefox");
        let b = scope_unit_name("firefox");
        assert_ne!(a, b);
        assert_eq!(a.len(), "app-lugh-firefox-".len() + 16 + ".scope".len());
        assert!(a.is_ascii());
    }

    #[test]
    fn terminals() {
        let cmd = s(&["htop"]);
        let have = |names: &'static [&'static str]| {
            move |p: &str| names.contains(&p).then(|| PathBuf::from(p))
        };
        assert_eq!(
            terminal_argv(
                &cmd,
                Some("alacritty --class x"),
                have(&["alacritty", "foot"])
            )
            .unwrap(),
            s(&["alacritty", "--class", "x", "-e", "htop"])
        );
        assert_eq!(
            terminal_argv(&cmd, Some("missing-term"), have(&["foot"])).unwrap(),
            s(&["foot", "htop"])
        );
        assert_eq!(
            terminal_argv(&cmd, None, have(&["x-terminal-emulator"])).unwrap(),
            s(&["x-terminal-emulator", "-e", "htop"])
        );
        assert_eq!(
            terminal_argv(&cmd, Some(""), have(&["foot"])).unwrap(),
            s(&["foot", "htop"])
        );
        assert!(matches!(
            terminal_argv(&cmd, None, have(&[])),
            Err(LaunchError::NoTerminal)
        ));
    }

    #[test]
    fn find_program_on_path() {
        assert!(find_program("sh").is_some());
        assert!(find_program("/bin/sh").is_some());
        assert!(find_program("definitely-not-a-program-lugh").is_none());
        assert!(find_program("/etc/hostname-not-exec-lugh").is_none());
    }

    #[derive(Debug, Default)]
    struct Recorder {
        calls: Mutex<Vec<(String, u32, String)>>,
        fail: bool,
    }

    impl ScopeManager for Arc<Recorder> {
        fn start_scope(&self, unit: &str, pid: u32, description: &str) -> Result<(), ScopeError> {
            self.calls
                .lock()
                .unwrap()
                .push((unit.to_owned(), pid, description.to_owned()));
            if self.fail {
                Err(ScopeError::Bus(zbus::Error::Failure("no bus".into())))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn launch_moves_the_process_into_a_scope() {
        let rec = Arc::new(Recorder::default());
        let launcher = AppLauncher::with_scopes(Arc::clone(&rec));
        let mut req = LaunchRequest::new("lugh-files", s(&["sh", "-c", "exit 0"]));
        req.description = Some("Files".into());
        req.env.push(("LUGH_TEST".into(), "1".into()));
        req.working_dir = Some(std::env::temp_dir());
        let h = launcher.launch(&req).unwrap();
        assert!(h.scoped);
        assert!(h.unit.starts_with(r"app-lugh-lugh\x2dfiles-"));
        let calls = rec.calls.lock().unwrap();
        assert_eq!(
            calls.as_slice(),
            [(h.unit.clone(), h.pid, "Files".to_owned())]
        );
    }

    #[test]
    fn launch_survives_scope_failure() {
        let rec = Arc::new(Recorder {
            fail: true,
            ..Recorder::default()
        });
        let launcher = AppLauncher::with_scopes(Arc::clone(&rec));
        let mut req = LaunchRequest::new("true", s(&["true"]));
        req.working_dir = Some("/nonexistent/lugh".into());
        let h = launcher.launch(&req).unwrap();
        assert!(!h.scoped);
        assert!(h.pid > 0);
    }

    #[test]
    fn launch_errors() {
        let launcher = AppLauncher::with_scopes(NoScopes);
        assert!(matches!(
            launcher.launch(&LaunchRequest::new("x", vec![])),
            Err(LaunchError::EmptyCommand)
        ));
        assert!(matches!(
            launcher.launch(&LaunchRequest::new("x", s(&["/nonexistent/lugh-app"]))),
            Err(LaunchError::Spawn { .. })
        ));
    }
}
