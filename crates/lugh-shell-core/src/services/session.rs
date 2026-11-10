//! `Services.session`: who is logged in, the lock, and power actions.
//!
//! State: `userName`, `realName`, `avatar`, `hostName`, `osVersion`,
//! `locked`, `authenticating`, `authError`, `canSuspend`, `lastError`.
//! Methods: `lock()`, `unlock(password)`, `logout()`, `restart()`,
//! `shutdown()`, `suspend()`. Signal: `unlocked()`.
//!
//! The lock (ADR-029) is decided by the pure state machine in
//! [`lock`]; this file only carries out its effects:
//!
//! - the flag file `$XDG_RUNTIME_DIR/lugh/locked` (0600, directory 0700)
//!   exists exactly while the session is locked, so a restarted shell starts
//!   locked (`locked: true` is in the very first state);
//! - passwords are checked on a blocking thread through [`auth`] (PAM), are
//!   never logged and are overwritten as soon as the check returns;
//! - logind's `Lock`/`Unlock` signals for our session lock/unlock, and a
//!   *delay* sleep inhibitor makes sure the lock is on screen before the
//!   machine sleeps.
//!
//! Nothing here polls: timers exist only while a retry delay is running.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use futures_util::StreamExt as _;
use serde_json::{Map, Value, json};

use super::{CallError, Context, Service, Sink};
use crate::wm::hyprland::HyprlandAdapter;

mod auth;
mod identity;
mod lock;
mod logind;

use auth::{Authenticator, Secret};
use identity::Identity;
use lock::{Effect, Input, LockMachine, LockView};
use logind::{Logind, PowerAction};

const NAME: &str = "session";
/// How long the UI gets to draw the lock before sleep goes on.
const DRAW_BEFORE_SLEEP: Duration = Duration::from_millis(250);

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let me = identity::read();
    let avatar = local_avatar(&me);
    let inner = Inner::new(
        ctx.sink.clone(),
        ctx.runtime.clone(),
        auth::system(),
        Box::new(FileFlag::from_env(me.uid)),
        me,
        avatar,
    );
    ctx.runtime.spawn(watch_logind(Arc::clone(&inner)));
    ctx.runtime.spawn(fetch_avatar(Arc::clone(&inner)));
    Box::new(SessionService(inner))
}

// ---- the `locked` flag ------------------------------------------------------

/// Where the locked state survives a shell restart.
trait FlagStore: Send + Sync + fmt::Debug {
    fn exists(&self) -> bool;
    fn set(&self) -> std::io::Result<()>;
    fn clear(&self) -> std::io::Result<()>;
}

/// `$XDG_RUNTIME_DIR/lugh/locked`.
#[derive(Debug)]
struct FileFlag {
    path: Option<PathBuf>,
}

impl FileFlag {
    fn from_env(uid: u32) -> Self {
        let dir = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .filter(|d| d.is_absolute())
            .or_else(|| Some(PathBuf::from(format!("/run/user/{uid}"))).filter(|d| d.is_dir()));
        if dir.is_none() {
            tracing::warn!("no XDG_RUNTIME_DIR: the lock will not survive a shell restart");
        }
        Self {
            path: dir.map(|d| d.join("lugh").join("locked")),
        }
    }
}

impl FlagStore for FileFlag {
    fn exists(&self) -> bool {
        self.path
            .as_ref()
            .is_some_and(|p| p.symlink_metadata().is_ok())
    }

    fn set(&self) -> std::io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(dir) = path.parent() {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)?;
        }
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
            .map(drop)
    }

    fn clear(&self) -> std::io::Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        match std::fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }
}

// ---- the service ------------------------------------------------------------

/// State that changes outside the lock machine.
#[derive(Debug, Default)]
struct Extra {
    avatar: String,
    can_suspend: bool,
    last_error: String,
}

struct Inner {
    sink: Sink,
    runtime: tokio::runtime::Handle,
    auth: Arc<dyn Authenticator>,
    flag: Box<dyn FlagStore>,
    me: Identity,
    machine: Mutex<LockMachine>,
    extra: Mutex<Extra>,
    logind: tokio::sync::OnceCell<Logind>,
}

impl fmt::Debug for Inner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("session::Inner")
            .field("user", &self.me.user_name)
            .field("machine", &self.machine)
            .finish_non_exhaustive()
    }
}

fn guard<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// The keys of `after` that differ from `before`.
fn lock_diff(before: &LockView, after: &LockView) -> Map<String, Value> {
    let mut d = Map::new();
    if before.locked != after.locked {
        d.insert("locked".into(), after.locked.into());
    }
    if before.authenticating != after.authenticating {
        d.insert("authenticating".into(), after.authenticating.into());
    }
    if before.auth_error != after.auth_error {
        d.insert("authError".into(), after.auth_error.clone().into());
    }
    d
}

impl Inner {
    fn new(
        sink: Sink,
        runtime: tokio::runtime::Handle,
        auth: Arc<dyn Authenticator>,
        flag: Box<dyn FlagStore>,
        me: Identity,
        avatar: String,
    ) -> Arc<Self> {
        let machine = LockMachine::new(flag.exists());
        Arc::new(Self {
            sink,
            runtime,
            auth,
            flag,
            me,
            machine: Mutex::new(machine),
            extra: Mutex::new(Extra {
                avatar,
                ..Extra::default()
            }),
            logind: tokio::sync::OnceCell::new(),
        })
    }

    fn state(&self) -> Value {
        let view = guard(&self.machine).view();
        let extra = guard(&self.extra);
        json!({
            "userName": self.me.user_name,
            "realName": self.me.real_name,
            "avatar": extra.avatar,
            "hostName": self.me.host_name,
            "osVersion": self.me.os_version,
            "locked": view.locked,
            "authenticating": view.authenticating,
            "authError": view.auth_error,
            "canSuspend": extra.can_suspend,
            "lastError": extra.last_error,
        })
    }

    /// Feeds the machine and carries out everything but `StartAuth`, which
    /// the caller (who holds the password) does. The machine stays locked
    /// until the patch is sent, so patches leave in the order of the changes.
    fn apply(self: &Arc<Self>, input: Input) -> Vec<Effect> {
        let mut machine = guard(&self.machine);
        let before = machine.view();
        let effects = machine.handle(input);
        let after = machine.view();
        for effect in &effects {
            match *effect {
                Effect::WriteFlag => {
                    if let Err(e) = self.flag.set() {
                        tracing::error!(%e, "could not write the locked flag; a shell restart would unlock");
                    }
                }
                Effect::RemoveFlag => {
                    if let Err(e) = self.flag.clear() {
                        tracing::error!(%e, "could not remove the locked flag");
                    }
                }
                Effect::ClearErrorAfter(delay) => {
                    let inner = Arc::clone(self);
                    self.runtime.spawn(async move {
                        tokio::time::sleep(delay).await;
                        inner.apply(Input::RetryElapsed {
                            now: Instant::now(),
                        });
                    });
                }
                Effect::StartAuth | Effect::EmitUnlocked => {}
            }
        }
        self.sink
            .patch(NAME, Value::Object(lock_diff(&before, &after)));
        if effects.contains(&Effect::EmitUnlocked) {
            tracing::info!("session unlocked");
            self.sink.signal(NAME, "unlocked", Vec::new());
        }
        if !before.locked && after.locked {
            tracing::info!("session locked");
        }
        effects
    }

    fn unlock(self: &Arc<Self>, password: Secret) {
        let effects = self.apply(Input::UnlockRequested {
            now: Instant::now(),
        });
        if !effects.contains(&Effect::StartAuth) {
            return; // `password` is wiped on drop
        }
        let inner = Arc::clone(self);
        self.runtime.spawn_blocking(move || {
            let outcome = inner.auth.authenticate(&inner.me.user_name, &password);
            drop(password);
            inner.apply(Input::AuthFinished {
                outcome,
                now: Instant::now(),
            });
        });
    }

    fn set_extra(&self, change: impl FnOnce(&mut Extra) -> Value) {
        let mut extra = guard(&self.extra);
        let patch = change(&mut extra);
        self.sink.patch(NAME, patch);
    }

    fn set_last_error(&self, message: String) {
        self.set_extra(|extra| {
            if extra.last_error == message {
                return json!({});
            }
            extra.last_error.clone_from(&message);
            json!({ "lastError": message })
        });
    }

    async fn logind(&self) -> zbus::Result<&Logind> {
        self.logind
            .get_or_try_init(|| {
                let id = std::env::var("XDG_SESSION_ID").ok();
                Logind::connect(id, self.me.uid)
            })
            .await
    }

    fn power(self: &Arc<Self>, action: PowerAction) {
        let inner = Arc::clone(self);
        self.runtime.spawn(async move {
            inner.set_last_error(String::new());
            let result = match inner.logind().await {
                Ok(logind) => logind.power(action).await,
                Err(e) => Err(e),
            };
            if let Err(e) = result {
                tracing::error!(?action, %e, "power request failed");
                inner.set_last_error(format!("{}: {}", power_failure(action), reason(&e)));
            }
        });
    }

    fn logout(self: &Arc<Self>) {
        let inner = Arc::clone(self);
        self.runtime.spawn(async move {
            inner.set_last_error(String::new());
            // The compositor exiting ends the session: `lugh-session` then
            // stops lugh-session.target and the app scopes.
            let asked = tokio::task::spawn_blocking(|| {
                let adapter = HyprlandAdapter::from_env().map_err(|e| e.to_string())?;
                let reply = adapter
                    .request(HYPRLAND_EXIT)
                    .map_err(|e| e.to_string())?;
                if reply.trim() == "ok" {
                    Ok(())
                } else {
                    Err(format!("Hyprland answered `{}`", reply.trim()))
                }
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()));
            let Err(why) = asked else {
                return;
            };
            tracing::warn!(%why, "could not ask the compositor to exit; terminating the session through logind");
            let result = match inner.logind().await {
                Ok(logind) => logind.terminate_session().await,
                Err(e) => Err(e),
            };
            if let Err(e) = result {
                tracing::error!(%e, "logout failed");
                inner.set_last_error(format!("Could not log out: {}", reason(&e)));
            }
        });
    }
}

/// Hyprland 0.55 (Lua config): dispatch arguments are Lua expressions
/// (docs/dev/hyprland.md); `hl.dsp.exit()` leaves the compositor cleanly.
const HYPRLAND_EXIT: &str = "dispatch hl.dsp.exit()";

fn power_failure(action: PowerAction) -> &'static str {
    match action {
        PowerAction::Reboot => "Could not restart",
        PowerAction::PowerOff => "Could not shut down",
        PowerAction::Suspend => "Could not suspend",
    }
}

/// The human part of a D-Bus error.
fn reason(e: &zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(_, Some(text), _) if !text.is_empty() => text.clone(),
        other => other.to_string(),
    }
}

fn local_avatar(me: &Identity) -> String {
    let face = me.home.as_ref().map(|h| h.join(".face"));
    identity::avatar_url(face.as_deref())
}

/// Asks AccountsService for the user's picture; `~/.face` stays when there
/// is no AccountsService or its file is unreadable.
async fn fetch_avatar(inner: Arc<Inner>) {
    let icon = async {
        let conn = zbus::Connection::system().await?;
        let accounts = logind::proxy(
            &conn,
            "org.freedesktop.Accounts",
            "/org/freedesktop/Accounts",
            "org.freedesktop.Accounts",
        )
        .await?;
        let path: zbus::zvariant::OwnedObjectPath = accounts
            .call("FindUserById", &(i64::from(inner.me.uid),))
            .await?;
        let user = logind::proxy(
            &conn,
            "org.freedesktop.Accounts",
            path.as_str().to_owned(),
            "org.freedesktop.Accounts.User",
        )
        .await?;
        user.get_property::<String>("IconFile").await
    }
    .await;
    let icon = match icon {
        Ok(icon) => PathBuf::from(icon),
        Err(e) => {
            tracing::debug!(%e, "no avatar from AccountsService");
            return;
        }
    };
    let face = inner.me.home.as_ref().map(|h| h.join(".face"));
    let candidates = std::iter::once(icon.as_path()).chain(face.as_deref());
    let url = identity::avatar_url(candidates);
    inner.set_extra(|extra| {
        if url.is_empty() || extra.avatar == url {
            return json!({});
        }
        extra.avatar.clone_from(&url);
        json!({ "avatar": url })
    });
}

/// logind: `canSuspend`, `Lock`/`Unlock` for our session, lock before sleep.
async fn watch_logind(inner: Arc<Inner>) {
    let logind = match inner.logind().await {
        Ok(l) => l.clone(),
        Err(e) => {
            tracing::warn!(%e, "logind unavailable: no sleep lock, no lock signals, no suspend");
            return;
        }
    };
    let can_suspend = logind.can_suspend().await;
    inner.set_extra(|extra| {
        if extra.can_suspend == can_suspend {
            return json!({});
        }
        extra.can_suspend = can_suspend;
        json!({ "canSuspend": can_suspend })
    });

    let mut sleep = match logind.manager().receive_signal("PrepareForSleep").await {
        Ok(s) => s.boxed(),
        Err(e) => {
            tracing::warn!(%e, "cannot watch PrepareForSleep; the screen will not lock before sleep");
            futures_util::stream::pending().boxed()
        }
    };
    let (mut lock, mut unlock) = match logind.session() {
        Some(session) => (
            session
                .receive_signal("Lock")
                .await
                .map_or_else(|_| futures_util::stream::pending().boxed(), |s| s.boxed()),
            session
                .receive_signal("Unlock")
                .await
                .map_or_else(|_| futures_util::stream::pending().boxed(), |s| s.boxed()),
        ),
        None => (
            futures_util::stream::pending().boxed(),
            futures_util::stream::pending().boxed(),
        ),
    };
    let take_inhibitor = || async {
        match logind.inhibit_sleep().await {
            Ok(fd) => Some(fd),
            Err(e) => {
                tracing::warn!(%e, "no sleep inhibitor; the lock may appear only after resume");
                None
            }
        }
    };
    let mut inhibitor = take_inhibitor().await;

    loop {
        tokio::select! {
            Some(_) = lock.next() => {
                inner.apply(Input::Lock);
            }
            Some(_) = unlock.next() => {
                tracing::info!("logind asked to unlock the session");
                inner.apply(Input::ExternalUnlock);
            }
            Some(msg) = sleep.next() => {
                match msg.body().deserialize::<bool>() {
                    Ok(true) => {
                        inner.apply(Input::Lock);
                        if inhibitor.is_some() {
                            tokio::time::sleep(DRAW_BEFORE_SLEEP).await;
                        }
                        inhibitor = None; // lets the machine sleep
                    }
                    Ok(false) => inhibitor = take_inhibitor().await,
                    Err(e) => tracing::debug!(%e, "odd PrepareForSleep signal"),
                }
            }
            else => break,
        }
    }
    tracing::warn!(
        connection = ?logind.connection().unique_name(),
        "lost the logind signals"
    );
}

/// The `session` service.
#[derive(Debug)]
struct SessionService(Arc<Inner>);

impl Service for SessionService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        self.0.state()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let inner = &self.0;
        match method {
            "lock" => {
                inner.apply(Input::Lock);
            }
            "unlock" => {
                // Read by hand (not `args::string`): the one copy of the
                // password this crate owns is the `Secret`.
                let password = a
                    .first()
                    .and_then(Value::as_str)
                    .map(Secret::new)
                    .ok_or_else(|| CallError::BadArgs("argument 0: expected a string".into()))?;
                inner.unlock(password);
            }
            "logout" => inner.logout(),
            "restart" => inner.power(PowerAction::Reboot),
            "shutdown" => inner.power(PowerAction::PowerOff),
            "suspend" => inner.power(PowerAction::Suspend),
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;

    use super::lock::AuthOutcome;
    use super::*;
    use crate::services::Event;

    /// Grants exactly `"open sesame"`; remembers nothing else.
    #[derive(Debug, Default)]
    struct FakeAuth {
        calls: AtomicUsize,
        broken: AtomicBool,
    }

    impl Authenticator for FakeAuth {
        fn authenticate(&self, user: &str, password: &Secret) -> AuthOutcome {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(user, "amara");
            if self.broken.load(Ordering::SeqCst) {
                AuthOutcome::Unavailable
            } else if password.expose() == "open sesame" {
                AuthOutcome::Granted
            } else {
                AuthOutcome::Denied
            }
        }
    }

    struct Rig {
        svc: SessionService,
        events: mpsc::Receiver<Event>,
        auth: Arc<FakeAuth>,
        flag_path: PathBuf,
        _dir: tempfile::TempDir,
        _rt: tokio::runtime::Runtime,
    }

    fn rig(locked_at_start: bool) -> Rig {
        let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let flag_path = dir.path().join("lugh").join("locked");
        let flag = FileFlag {
            path: Some(flag_path.clone()),
        };
        if locked_at_start {
            flag.set().unwrap_or_else(|e| panic!("flag: {e}"));
        }
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap_or_else(|e| panic!("runtime: {e}"));
        let (tx, events) = mpsc::channel();
        let sink = Sink::new(move |e| {
            let _ = tx.send(e);
        });
        let auth = Arc::new(FakeAuth::default());
        let me = Identity {
            uid: 1000,
            user_name: "amara".into(),
            real_name: "Amara Nkusi".into(),
            home: None,
            host_name: "lugh-laptop".into(),
            os_version: "Lugh 0.1".into(),
        };
        let inner = Inner::new(
            sink,
            rt.handle().clone(),
            Arc::clone(&auth) as Arc<dyn Authenticator>,
            Box::new(flag),
            me,
            String::new(),
        );
        Rig {
            svc: SessionService(inner),
            events,
            auth,
            flag_path,
            _dir: dir,
            _rt: rt,
        }
    }

    impl Rig {
        fn call(&self, method: &str, args: &[Value]) {
            assert_eq!(self.svc.call(method, args), Ok(Value::Null), "{method}");
        }

        fn next(&self) -> Event {
            self.events
                .recv_timeout(Duration::from_secs(5))
                .unwrap_or_else(|e| panic!("no event: {e}"))
        }

        fn next_patch(&self) -> Value {
            match self.next() {
                Event::Patch { service, data } => {
                    assert_eq!(service, "session");
                    Value::Object(data)
                }
                other @ Event::Signal { .. } => panic!("expected a patch, got {other:?}"),
            }
        }

        fn quiet(&self) {
            assert!(self.events.recv_timeout(Duration::from_millis(50)).is_err());
        }
    }

    #[test]
    fn state_has_the_contract_keys_and_types() {
        let r = rig(false);
        assert_eq!(
            r.svc.state(),
            json!({
                "userName": "amara",
                "realName": "Amara Nkusi",
                "avatar": "",
                "hostName": "lugh-laptop",
                "osVersion": "Lugh 0.1",
                "locked": false,
                "authenticating": false,
                "authError": "",
                "canSuspend": false,
                "lastError": "",
            })
        );
        assert_eq!(r.svc.name(), "session");
        assert!(matches!(
            r.svc.call("selfDestruct", &[]),
            Err(CallError::UnknownMethod(_))
        ));
        assert!(matches!(
            r.svc.call("unlock", &[]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            r.svc.call("unlock", &[json!(42)]),
            Err(CallError::BadArgs(_))
        ));
    }

    #[test]
    fn lock_writes_a_private_flag_and_patches_once() {
        use std::os::unix::fs::PermissionsExt as _;
        let r = rig(false);
        r.call("lock", &[]);
        assert_eq!(r.next_patch(), json!({ "locked": true }));
        let mode = |p: &std::path::Path| {
            std::fs::metadata(p)
                .map(|m| m.permissions().mode() & 0o777)
                .unwrap_or_else(|e| panic!("stat {}: {e}", p.display()))
        };
        assert_eq!(mode(&r.flag_path), 0o600);
        assert_eq!(mode(r.flag_path.parent().unwrap_or(&r.flag_path)), 0o700);
        // Locking a locked session: no patch (nothing changed).
        r.call("lock", &[]);
        r.quiet();
        assert_eq!(r.svc.state()["locked"], true);
    }

    #[test]
    fn a_leftover_flag_means_locked_in_the_first_state() {
        let r = rig(true);
        assert_eq!(r.svc.state()["locked"], true);
        r.quiet();
    }

    #[test]
    fn wrong_then_right_password() {
        let r = rig(true);
        r.call("unlock", &[json!("nope")]);
        assert_eq!(r.next_patch(), json!({ "authenticating": true }));
        assert_eq!(
            r.next_patch(),
            json!({ "authenticating": false, "authError": "Wrong password. Try again." })
        );
        assert!(r.flag_path.exists());
        assert_eq!(r.svc.state()["locked"], true);

        r.call("unlock", &[json!("open sesame")]);
        assert_eq!(
            r.next_patch(),
            json!({ "authenticating": true, "authError": "" })
        );
        assert_eq!(
            r.next_patch(),
            json!({ "authenticating": false, "locked": false })
        );
        assert_eq!(
            r.next(),
            Event::Signal {
                service: "session",
                name: "unlocked",
                args: vec![]
            }
        );
        assert!(!r.flag_path.exists());
        assert_eq!(r.auth.calls.load(Ordering::SeqCst), 2);
        r.quiet();
    }

    #[test]
    fn unlock_when_not_locked_never_authenticates() {
        let r = rig(false);
        r.call("unlock", &[json!("open sesame")]);
        r.quiet();
        assert_eq!(r.auth.calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn third_failure_delays_without_calling_the_authenticator() {
        let r = rig(true);
        for _ in 0..2 {
            r.call("unlock", &[json!("nope")]);
            let _ = r.next_patch();
            assert_eq!(r.next_patch()["authError"], "Wrong password. Try again.");
        }
        r.call("unlock", &[json!("nope")]);
        let _ = r.next_patch();
        assert_eq!(
            r.next_patch()["authError"],
            "Too many attempts. Try again in 2 s."
        );
        // Even the right password has to wait, and is not checked.
        r.call("unlock", &[json!("open sesame")]);
        r.quiet();
        assert_eq!(r.auth.calls.load(Ordering::SeqCst), 3);
        assert_eq!(r.svc.state()["locked"], true);
        // The message clears by itself when the delay is over …
        assert_eq!(
            r.events.recv_timeout(Duration::from_secs(5)).ok(),
            Some(Event::Patch {
                service: "session",
                data: lock_diff(
                    &LockView {
                        locked: true,
                        authenticating: false,
                        auth_error: "x".into()
                    },
                    &LockView {
                        locked: true,
                        authenticating: false,
                        auth_error: String::new()
                    }
                ),
            })
        );
        // … and then the right password works.
        r.call("unlock", &[json!("open sesame")]);
        assert_eq!(r.next_patch(), json!({ "authenticating": true }));
        assert_eq!(
            r.next_patch(),
            json!({ "authenticating": false, "locked": false })
        );
    }

    #[test]
    fn a_broken_authenticator_keeps_the_session_locked() {
        let r = rig(true);
        r.auth.broken.store(true, Ordering::SeqCst);
        r.call("unlock", &[json!("open sesame")]);
        let _ = r.next_patch();
        assert_eq!(
            r.next_patch(),
            json!({
                "authenticating": false,
                "authError": "Could not check the password. Try again."
            })
        );
        assert_eq!(r.svc.state()["locked"], true);
        assert!(r.flag_path.exists());
    }

    #[test]
    fn external_unlock_and_lock_signals() {
        let r = rig(false);
        r.svc.0.apply(Input::Lock);
        assert_eq!(r.next_patch(), json!({ "locked": true }));
        r.svc.0.apply(Input::ExternalUnlock);
        assert_eq!(r.next_patch(), json!({ "locked": false }));
        assert!(matches!(
            r.next(),
            Event::Signal {
                name: "unlocked",
                ..
            }
        ));
        assert!(!r.flag_path.exists());
    }

    #[test]
    fn last_error_is_patched_only_when_it_changes() {
        let r = rig(false);
        r.svc.0.set_last_error(String::new());
        r.quiet();
        r.svc.0.set_last_error("Could not restart: no".into());
        assert_eq!(
            r.next_patch(),
            json!({ "lastError": "Could not restart: no" })
        );
        assert_eq!(r.svc.state()["lastError"], "Could not restart: no");
    }

    #[test]
    fn flag_without_a_runtime_dir_is_harmless() {
        let flag = FileFlag { path: None };
        assert!(!flag.exists());
        assert!(flag.set().is_ok());
        assert!(flag.clear().is_ok());
    }

    #[test]
    fn error_reasons_are_plain() {
        assert_eq!(
            reason(&zbus::Error::Failure("boom".into())),
            zbus::Error::Failure("boom".into()).to_string()
        );
        assert_eq!(power_failure(PowerAction::Reboot), "Could not restart");
    }
}
