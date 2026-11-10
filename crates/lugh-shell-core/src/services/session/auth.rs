//! Password check for the lock screen, behind [`Authenticator`].
//!
//! - With the cargo feature `pam` (production): PAM through the `nonstick`
//!   crate, service `lugh-lock` (`data/pam/lugh-lock`, installed to
//!   `/etc/pam.d/`), or `login` when that file is not installed. pam_unix
//!   checks the calling user's own password through its setgid helper, so no
//!   privilege is needed.
//! - Without it (machines without libpam's development files): the same
//!   setgid helper, `unix_chkpwd`, run directly. It checks the password and
//!   nothing else of the PAM stack. When the helper is missing too, every
//!   attempt is refused, and that is logged.
//!
//! Manual check against the real system (asks for nothing, reads the
//! password from the environment so it never lands in shell history files of
//! this repo; use a throwaway account):
//!
//! ```text
//! LUGH_TEST_PASSWORD='…' cargo test -p lugh-shell-core --features pam \
//!     -- --ignored real_authenticator --nocapture
//! ```

use std::fmt;

pub(crate) use super::lock::AuthOutcome;

/// A password this process is about to check. The buffer is overwritten when
/// the value is dropped; `Debug` never prints it; it cannot be cloned.
pub(crate) struct Secret(String);

impl Secret {
    pub(crate) fn new(password: &str) -> Self {
        Self(password.to_owned())
    }

    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.0);
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(…)")
    }
}

/// Checks a user's password. Called on a blocking thread; may take seconds
/// (pam_unix delays failures by about two).
pub(crate) trait Authenticator: Send + Sync + fmt::Debug {
    fn authenticate(&self, user: &str, password: &Secret) -> AuthOutcome;
}

/// The authenticator for this build (see the module docs).
pub(crate) fn system() -> std::sync::Arc<dyn Authenticator> {
    #[cfg(feature = "pam")]
    {
        let auth = pam::PamAuthenticator::new();
        tracing::info!(
            service = auth.service(),
            "lock screen authenticates through PAM"
        );
        std::sync::Arc::new(auth)
    }
    #[cfg(not(feature = "pam"))]
    {
        match helper::HelperAuthenticator::find() {
            Some(auth) => {
                tracing::warn!(
                    helper = %auth.path().display(),
                    "built without the `pam` feature: the lock screen checks the password \
                     with unix_chkpwd only (no PAM stack)"
                );
                std::sync::Arc::new(auth)
            }
            None => {
                tracing::error!(
                    "built without the `pam` feature and unix_chkpwd is missing: \
                     the lock screen cannot check passwords and will refuse every attempt \
                     (`loginctl unlock-session` from a console unlocks)"
                );
                std::sync::Arc::new(RefuseAll)
            }
        }
    }
}

/// Refuses everything: the last resort when nothing can check a password.
#[derive(Debug)]
#[cfg_attr(feature = "pam", allow(dead_code))]
pub(crate) struct RefuseAll;

impl Authenticator for RefuseAll {
    fn authenticate(&self, _user: &str, _password: &Secret) -> AuthOutcome {
        AuthOutcome::Unavailable
    }
}

#[cfg(feature = "pam")]
mod pam {
    use std::ffi::{OsStr, OsString};
    use std::path::Path;

    use nonstick::{
        AuthnFlags, ConversationAdapter, ErrorCode, Result as PamResult, Transaction,
        TransactionBuilder,
    };

    use super::{AuthOutcome, Authenticator, Secret};

    const SERVICE: &str = "lugh-lock";
    const FALLBACK_SERVICE: &str = "login";

    /// PAM service to use: ours when installed, else `login` (an unknown
    /// service would silently fall through to `other`).
    fn pick_service(installed: impl Fn(&Path) -> bool) -> &'static str {
        let ours = ["/etc/pam.d", "/usr/lib/pam.d"]
            .iter()
            .any(|dir| installed(&Path::new(dir).join(SERVICE)));
        if ours { SERVICE } else { FALLBACK_SERVICE }
    }

    #[derive(Debug)]
    pub(super) struct PamAuthenticator {
        service: &'static str,
    }

    impl PamAuthenticator {
        pub(super) fn new() -> Self {
            Self {
                service: pick_service(Path::exists),
            }
        }

        pub(super) fn service(&self) -> &'static str {
            self.service
        }
    }

    /// Answers PAM's questions: the user name for a visible prompt, the
    /// password for a hidden one. Messages go to the debug log (they never
    /// contain the password).
    struct Conv<'a> {
        user: &'a str,
        password: &'a Secret,
    }

    impl ConversationAdapter for Conv<'_> {
        fn prompt(&self, _request: impl AsRef<OsStr>) -> PamResult<OsString> {
            Ok(OsString::from(self.user))
        }
        fn masked_prompt(&self, _request: impl AsRef<OsStr>) -> PamResult<OsString> {
            // nonstick copies this into PAM's buffer and zeroes that itself.
            Ok(OsString::from(self.password.expose()))
        }
        fn error_msg(&self, message: impl AsRef<OsStr>) {
            tracing::debug!(message = ?message.as_ref(), "PAM error message");
        }
        fn info_msg(&self, message: impl AsRef<OsStr>) {
            tracing::debug!(message = ?message.as_ref(), "PAM info message");
        }
    }

    impl Authenticator for PamAuthenticator {
        fn authenticate(&self, user: &str, password: &Secret) -> AuthOutcome {
            let conv = Conv { user, password };
            let result = (|| -> PamResult<()> {
                let mut txn = TransactionBuilder::new_with_service(self.service)
                    .username(user)
                    .build(conv.into_conversation())?;
                txn.authenticate(AuthnFlags::empty())?;
                match txn.account_management(AuthnFlags::empty()) {
                    // The password is right but due for a change: let the
                    // user in, they change it from the desktop.
                    Err(ErrorCode::NewAuthTokRequired) => Ok(()),
                    other => other,
                }
            })();
            match result {
                Ok(()) => AuthOutcome::Granted,
                Err(
                    code @ (ErrorCode::AuthenticationError
                    | ErrorCode::UserUnknown
                    | ErrorCode::MaxTries
                    | ErrorCode::PermissionDenied
                    | ErrorCode::AccountExpired
                    | ErrorCode::CredentialsInsufficient),
                ) => {
                    tracing::info!(service = self.service, ?code, "unlock refused by PAM");
                    AuthOutcome::Denied
                }
                Err(code) => {
                    tracing::error!(service = self.service, ?code, "PAM could not authenticate");
                    AuthOutcome::Unavailable
                }
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn service_falls_back_to_login() {
            assert_eq!(pick_service(|_| false), "login");
            assert_eq!(
                pick_service(|p| p == Path::new("/etc/pam.d/lugh-lock")),
                "lugh-lock"
            );
            assert_eq!(
                pick_service(|p| p == Path::new("/usr/lib/pam.d/lugh-lock")),
                "lugh-lock"
            );
        }
    }
}

#[cfg(not(feature = "pam"))]
mod helper {
    use std::io::Write as _;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};

    use super::{AuthOutcome, Authenticator, Secret};

    /// Exit status of unix_chkpwd for a wrong password (`PAM_AUTH_ERR`).
    const PAM_AUTH_ERR: i32 = 7;
    /// … and for an unknown user (`PAM_USER_UNKNOWN`).
    const PAM_USER_UNKNOWN: i32 = 10;

    /// Runs pam_unix's setgid helper the way pam_unix does:
    /// `unix_chkpwd <user> nullok`, the password and a NUL on stdin, exit
    /// status 0 when it matches. The helper only answers for the calling
    /// user, and refuses a terminal as stdin.
    #[derive(Debug)]
    pub(super) struct HelperAuthenticator {
        path: PathBuf,
    }

    impl HelperAuthenticator {
        pub(super) fn find() -> Option<Self> {
            ["/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd"]
                .iter()
                .map(PathBuf::from)
                .find(|p| p.is_file())
                .map(|path| Self { path })
        }

        pub(super) fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Authenticator for HelperAuthenticator {
        fn authenticate(&self, user: &str, password: &Secret) -> AuthOutcome {
            let spawned = Command::new(&self.path)
                .arg(user)
                .arg("nullok")
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .env_clear()
                .spawn();
            let mut child = match spawned {
                Ok(c) => c,
                Err(e) => {
                    tracing::error!(%e, "could not run unix_chkpwd");
                    return AuthOutcome::Unavailable;
                }
            };
            let written = child.stdin.take().map(|mut stdin| {
                stdin
                    .write_all(password.expose().as_bytes())
                    .and_then(|()| stdin.write_all(&[0]))
            });
            let status = child.wait();
            match (written, status) {
                (Some(Ok(())), Ok(s)) if s.success() => AuthOutcome::Granted,
                (Some(Ok(())), Ok(s))
                    if matches!(s.code(), Some(PAM_AUTH_ERR | PAM_USER_UNKNOWN)) =>
                {
                    tracing::info!("unlock refused: wrong password");
                    AuthOutcome::Denied
                }
                (_, status) => {
                    tracing::error!(?status, "unix_chkpwd could not check the password");
                    AuthOutcome::Unavailable
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_is_not_printed() {
        let s = Secret::new("hunter2");
        assert_eq!(s.expose(), "hunter2");
        assert!(!format!("{s:?}").contains("hunter2"));
    }

    #[test]
    fn refuse_all_never_grants() {
        assert_eq!(
            RefuseAll.authenticate("anyone", &Secret::new("x")),
            AuthOutcome::Unavailable
        );
    }

    /// Manual: checks `LUGH_TEST_PASSWORD` for the current user against the
    /// real system (see the module docs). A wrong value must print `Denied`
    /// after about two seconds, the right one `Granted`.
    #[test]
    #[ignore = "talks to the real PAM stack; needs LUGH_TEST_PASSWORD"]
    fn real_authenticator() {
        let Ok(password) = std::env::var("LUGH_TEST_PASSWORD") else {
            panic!("set LUGH_TEST_PASSWORD");
        };
        let user = std::env::var("USER").unwrap_or_default();
        let started = std::time::Instant::now();
        let outcome = system().authenticate(&user, &Secret::new(&password));
        // Not the password: only the verdict and how long it took.
        tracing::info!(?outcome, elapsed = ?started.elapsed(), "real authentication");
        assert_ne!(outcome, AuthOutcome::Unavailable);
        if std::env::var_os("LUGH_TEST_EXPECT_DENIED").is_some() {
            assert_eq!(outcome, AuthOutcome::Denied);
        } else {
            assert_eq!(outcome, AuthOutcome::Granted);
        }
    }
}
