//! Thin async client for `org.freedesktop.login1` (system bus).
//!
//! Everything is optional: without logind (containers, some dev setups)
//! [`Logind::connect`] fails and the session service simply has no sleep
//! lock, no `Lock`/`Unlock` signals and `canSuspend: false`.

use zbus::proxy::CacheProperties;
use zbus::zvariant::{OwnedFd, OwnedObjectPath};
use zbus::{Connection, Proxy};

const DEST: &str = "org.freedesktop.login1";
const MANAGER_PATH: &str = "/org/freedesktop/login1";
const MANAGER_IFACE: &str = "org.freedesktop.login1.Manager";
const SESSION_IFACE: &str = "org.freedesktop.login1.Session";

/// A power request for the manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PowerAction {
    Reboot,
    PowerOff,
    Suspend,
}

impl PowerAction {
    fn method(self) -> &'static str {
        match self {
            Self::Reboot => "Reboot",
            Self::PowerOff => "PowerOff",
            Self::Suspend => "Suspend",
        }
    }
}

/// A plain proxy without the property cache (no extra match rules, no
/// background task).
pub(crate) async fn proxy(
    conn: &Connection,
    dest: &'static str,
    path: impl Into<String>,
    iface: &'static str,
) -> zbus::Result<Proxy<'static>> {
    zbus::proxy::Builder::new(conn)
        .destination(dest)?
        .path(path.into())?
        .interface(iface)?
        .cache_properties(CacheProperties::No)
        .build()
        .await
}

/// The login manager and, when it can be found, our session object.
#[derive(Debug, Clone)]
pub(crate) struct Logind {
    conn: Connection,
    manager: Proxy<'static>,
    session: Option<Proxy<'static>>,
}

impl Logind {
    /// Connects and looks our session up. `session_id` is `XDG_SESSION_ID`
    /// (imported into the user manager by `lugh-session`); without it the
    /// session of this process, then the first seated session of `uid`.
    pub(crate) async fn connect(session_id: Option<String>, uid: u32) -> zbus::Result<Self> {
        let conn = Connection::system().await?;
        let manager = proxy(&conn, DEST, MANAGER_PATH, MANAGER_IFACE).await?;
        // Fails when logind is not running, which is what callers want to know.
        let sessions: Vec<(String, u32, String, String, OwnedObjectPath)> =
            manager.call("ListSessions", &()).await?;
        let path = Self::session_path(&manager, session_id, uid, &sessions).await;
        let session = match path {
            Some(path) => Some(proxy(&conn, DEST, path.as_str().to_owned(), SESSION_IFACE).await?),
            None => {
                tracing::warn!("no logind session found for this user; lock signals unavailable");
                None
            }
        };
        Ok(Self {
            conn,
            manager,
            session,
        })
    }

    async fn session_path(
        manager: &Proxy<'static>,
        session_id: Option<String>,
        uid: u32,
        sessions: &[(String, u32, String, String, OwnedObjectPath)],
    ) -> Option<OwnedObjectPath> {
        if let Some(id) = session_id.filter(|id| !id.is_empty())
            && let Ok(path) = manager
                .call::<_, _, OwnedObjectPath>("GetSession", &(id.as_str(),))
                .await
        {
            return Some(path);
        }
        if let Ok(path) = manager
            .call::<_, _, OwnedObjectPath>("GetSessionByPID", &(std::process::id(),))
            .await
        {
            return Some(path);
        }
        let mine = || sessions.iter().filter(|s| s.1 == uid);
        mine()
            .find(|s| !s.3.is_empty())
            .or_else(|| mine().next())
            .map(|s| s.4.clone())
    }

    pub(crate) fn manager(&self) -> &Proxy<'static> {
        &self.manager
    }

    pub(crate) fn session(&self) -> Option<&Proxy<'static>> {
        self.session.as_ref()
    }

    /// `CanSuspend == "yes"`.
    pub(crate) async fn can_suspend(&self) -> bool {
        self.manager
            .call::<_, _, String>("CanSuspend", &())
            .await
            .is_ok_and(|answer| answer == "yes")
    }

    /// Reboot / PowerOff / Suspend with `interactive = true` (polkit may ask).
    pub(crate) async fn power(&self, action: PowerAction) -> zbus::Result<()> {
        self.manager.call(action.method(), &(true,)).await
    }

    /// Ends our session (the `loginctl terminate-session` fallback of logout).
    pub(crate) async fn terminate_session(&self) -> zbus::Result<()> {
        match &self.session {
            Some(session) => session.call("Terminate", &()).await,
            None => Err(zbus::Error::Failure("no logind session".into())),
        }
    }

    /// Takes a *delay* inhibitor for sleep. Sleep waits (up to logind's
    /// `InhibitDelayMaxSec`) until the returned descriptor is dropped.
    pub(crate) async fn inhibit_sleep(&self) -> zbus::Result<OwnedFd> {
        self.manager
            .call(
                "Inhibit",
                &("sleep", "Lugh", "Lock the screen before sleep", "delay"),
            )
            .await
    }

    /// Takes a *block* inhibitor for idle ("Keep awake"): the idle daemon
    /// (hypridle honours logind inhibitors) neither dims, locks nor sleeps
    /// until the returned descriptor is dropped.
    pub(crate) async fn inhibit_idle(&self) -> zbus::Result<OwnedFd> {
        self.manager
            .call("Inhibit", &("idle", "Lugh", "Keep awake is on", "block"))
            .await
    }

    pub(crate) fn connection(&self) -> &Connection {
        &self.conn
    }
}
