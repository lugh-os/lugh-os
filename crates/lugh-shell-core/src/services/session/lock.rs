//! The lock state machine (ADR-029). Pure: no I/O, no clock of its own.
//!
//! The service feeds it [`Input`]s and carries out the [`Effect`]s it
//! returns. Everything security-relevant is decided here so it can be tested
//! exhaustively:
//!
//! - the session unlocks only on a granted authentication that this machine
//!   started, or on logind's `Unlock` (root/polkit-gated);
//! - one authentication at a time;
//! - from the third consecutive failure on, a growing delay before the next
//!   attempt (2 s, 4 s, 8 s, 16 s, then 30 s). Locking again does not reset it.

use std::time::{Duration, Instant};

/// Consecutive failures allowed before delays start.
pub(crate) const FREE_ATTEMPTS: u32 = 3;
/// Longest delay between attempts.
pub(crate) const MAX_DELAY: Duration = Duration::from_secs(30);

/// Message for a wrong password.
pub(crate) const MSG_WRONG: &str = "Wrong password. Try again.";
/// Message when the password could not be checked at all.
pub(crate) const MSG_UNAVAILABLE: &str = "Could not check the password. Try again.";

/// How an authentication attempt ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthOutcome {
    /// The password is right and the account may be used.
    Granted,
    /// Wrong password (or the account is not allowed in).
    Denied,
    /// The check itself failed (no PAM, helper missing, …).
    Unavailable,
}

/// Something that happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Input {
    /// `session.lock()`, logind `Lock`, or the system is about to sleep.
    Lock,
    /// `session.unlock(password)` was called.
    UnlockRequested {
        /// Now.
        now: Instant,
    },
    /// The authentication started by [`Effect::StartAuth`] finished.
    AuthFinished {
        /// Its result.
        outcome: AuthOutcome,
        /// Now.
        now: Instant,
    },
    /// logind `Unlock` for our session (`loginctl unlock-session`).
    ExternalUnlock,
    /// The timer set by [`Effect::ClearErrorAfter`] fired.
    RetryElapsed {
        /// Now.
        now: Instant,
    },
}

/// What the service must do after an input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Effect {
    /// Create the `locked` flag file.
    WriteFlag,
    /// Remove the `locked` flag file.
    RemoveFlag,
    /// Check the password given with the unlock request.
    StartAuth,
    /// Emit `session.unlocked()`.
    EmitUnlocked,
    /// Send [`Input::RetryElapsed`] after this long.
    ClearErrorAfter(Duration),
}

/// The QML-visible part of the state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LockView {
    pub(crate) locked: bool,
    pub(crate) authenticating: bool,
    pub(crate) auth_error: String,
}

/// See the module docs.
#[derive(Debug)]
pub(crate) struct LockMachine {
    locked: bool,
    authenticating: bool,
    auth_error: String,
    failures: u32,
    retry_at: Option<Instant>,
}

/// Delay imposed after `failures` consecutive failures.
pub(crate) fn delay_after(failures: u32) -> Option<Duration> {
    if failures < FREE_ATTEMPTS {
        return None;
    }
    let exp = (failures - FREE_ATTEMPTS + 1).min(5);
    Some(Duration::from_secs(1 << exp).min(MAX_DELAY))
}

fn too_many(remaining: Duration) -> String {
    // Round up: "0 s" would invite an attempt that is refused.
    let secs = remaining.as_secs() + u64::from(remaining.subsec_nanos() > 0);
    format!("Too many attempts. Try again in {} s.", secs.max(1))
}

impl LockMachine {
    /// `flag_exists`: the `locked` flag survived from a previous shell
    /// process, so this one starts locked.
    pub(crate) fn new(flag_exists: bool) -> Self {
        Self {
            locked: flag_exists,
            authenticating: false,
            auth_error: String::new(),
            failures: 0,
            retry_at: None,
        }
    }

    pub(crate) fn view(&self) -> LockView {
        LockView {
            locked: self.locked,
            authenticating: self.authenticating,
            auth_error: self.auth_error.clone(),
        }
    }

    pub(crate) fn handle(&mut self, input: Input) -> Vec<Effect> {
        match input {
            Input::Lock => {
                if !self.locked {
                    self.locked = true;
                    self.auth_error.clear();
                }
                // Also when already locked: restores a flag that went missing.
                vec![Effect::WriteFlag]
            }
            Input::UnlockRequested { now } => {
                if !self.locked || self.authenticating {
                    return Vec::new();
                }
                if let Some(at) = self.retry_at
                    && at > now
                {
                    self.auth_error = too_many(at - now);
                    return Vec::new();
                }
                self.authenticating = true;
                self.auth_error.clear();
                vec![Effect::StartAuth]
            }
            Input::AuthFinished { outcome, now } => {
                if !self.authenticating {
                    // A result nobody asked for never changes anything.
                    return Vec::new();
                }
                self.authenticating = false;
                if !self.locked {
                    // Unlocked from outside meanwhile; nothing left to do.
                    return Vec::new();
                }
                match outcome {
                    AuthOutcome::Granted => self.open(),
                    AuthOutcome::Denied => {
                        self.failures = self.failures.saturating_add(1);
                        if let Some(delay) = delay_after(self.failures) {
                            self.retry_at = Some(now + delay);
                            self.auth_error = too_many(delay);
                            vec![Effect::ClearErrorAfter(delay)]
                        } else {
                            self.auth_error = MSG_WRONG.into();
                            Vec::new()
                        }
                    }
                    AuthOutcome::Unavailable => {
                        self.auth_error = MSG_UNAVAILABLE.into();
                        Vec::new()
                    }
                }
            }
            Input::ExternalUnlock => {
                if self.locked {
                    self.open()
                } else {
                    Vec::new()
                }
            }
            Input::RetryElapsed { now } => {
                if self.retry_at.is_some_and(|at| at <= now) && !self.authenticating {
                    self.retry_at = None;
                    if self.locked {
                        self.auth_error.clear();
                    }
                }
                Vec::new()
            }
        }
    }

    fn open(&mut self) -> Vec<Effect> {
        self.locked = false;
        self.auth_error.clear();
        self.failures = 0;
        self.retry_at = None;
        vec![Effect::RemoveFlag, Effect::EmitUnlocked]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    /// Requests an unlock and finishes it with `outcome`, both at `now`.
    fn attempt(m: &mut LockMachine, outcome: AuthOutcome, now: Instant) -> Vec<Effect> {
        assert_eq!(
            m.handle(Input::UnlockRequested { now }),
            [Effect::StartAuth],
            "attempt must be allowed"
        );
        assert!(m.view().authenticating);
        m.handle(Input::AuthFinished { outcome, now })
    }

    #[test]
    fn starts_from_the_flag() {
        assert!(!LockMachine::new(false).view().locked);
        let m = LockMachine::new(true);
        assert_eq!(
            m.view(),
            LockView {
                locked: true,
                authenticating: false,
                auth_error: String::new()
            }
        );
    }

    #[test]
    fn lock_writes_the_flag_every_time() {
        let mut m = LockMachine::new(false);
        assert_eq!(m.handle(Input::Lock), [Effect::WriteFlag]);
        assert!(m.view().locked);
        assert_eq!(m.handle(Input::Lock), [Effect::WriteFlag]);
        assert!(m.view().locked);
    }

    #[test]
    fn granted_unlocks_once() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        assert_eq!(
            attempt(&mut m, AuthOutcome::Granted, t),
            [Effect::RemoveFlag, Effect::EmitUnlocked]
        );
        assert_eq!(
            m.view(),
            LockView {
                locked: false,
                authenticating: false,
                auth_error: String::new()
            }
        );
        // Unlocking an unlocked session does nothing at all.
        assert!(m.handle(Input::UnlockRequested { now: t }).is_empty());
        assert!(!m.view().authenticating);
    }

    #[test]
    fn denied_keeps_locked_and_explains() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        assert!(attempt(&mut m, AuthOutcome::Denied, t).is_empty());
        let v = m.view();
        assert!(v.locked && !v.authenticating);
        assert_eq!(v.auth_error, MSG_WRONG);
        // The next request clears the message while it runs.
        assert_eq!(
            m.handle(Input::UnlockRequested { now: t }),
            [Effect::StartAuth]
        );
        assert_eq!(m.view().auth_error, "");
    }

    #[test]
    fn unavailable_is_not_counted() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        for _ in 0..10 {
            assert!(attempt(&mut m, AuthOutcome::Unavailable, t).is_empty());
            assert_eq!(m.view().auth_error, MSG_UNAVAILABLE);
            assert!(m.view().locked);
        }
    }

    #[test]
    fn a_result_without_a_request_never_unlocks() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        let granted = Input::AuthFinished {
            outcome: AuthOutcome::Granted,
            now: t,
        };
        assert!(m.handle(granted).is_empty());
        assert!(m.view().locked);
        // Nor a second result for one request.
        assert!(attempt(&mut m, AuthOutcome::Denied, t).is_empty());
        assert!(m.handle(granted).is_empty());
        assert!(m.view().locked);
    }

    #[test]
    fn one_authentication_at_a_time() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        assert_eq!(
            m.handle(Input::UnlockRequested { now: t }),
            [Effect::StartAuth]
        );
        assert!(m.handle(Input::UnlockRequested { now: t }).is_empty());
        assert!(m.view().authenticating);
    }

    #[test]
    fn delays_grow_and_cap() {
        assert_eq!(delay_after(0), None);
        assert_eq!(delay_after(2), None);
        let got: Vec<u64> = (3..=9)
            .filter_map(delay_after)
            .map(|d| d.as_secs())
            .collect();
        assert_eq!(got, [2, 4, 8, 16, 30, 30, 30]);
        assert_eq!(delay_after(u32::MAX), Some(MAX_DELAY));
    }

    #[test]
    fn third_failure_starts_the_backoff() {
        let mut now = Instant::now();
        let mut m = LockMachine::new(true);
        assert!(attempt(&mut m, AuthOutcome::Denied, now).is_empty());
        assert!(attempt(&mut m, AuthOutcome::Denied, now).is_empty());
        assert_eq!(
            attempt(&mut m, AuthOutcome::Denied, now),
            [Effect::ClearErrorAfter(secs(2))]
        );
        assert_eq!(m.view().auth_error, "Too many attempts. Try again in 2 s.");

        // Too early: refused without authenticating, with the time left.
        now += Duration::from_millis(500);
        assert!(m.handle(Input::UnlockRequested { now }).is_empty());
        assert!(!m.view().authenticating);
        assert_eq!(m.view().auth_error, "Too many attempts. Try again in 2 s.");
        now += Duration::from_millis(1000);
        assert!(m.handle(Input::UnlockRequested { now }).is_empty());
        assert_eq!(m.view().auth_error, "Too many attempts. Try again in 1 s.");

        // An early timer changes nothing; the real one clears the message.
        assert!(m.handle(Input::RetryElapsed { now }).is_empty());
        assert_ne!(m.view().auth_error, "");
        now += Duration::from_millis(500);
        assert!(m.handle(Input::RetryElapsed { now }).is_empty());
        assert_eq!(m.view().auth_error, "");

        // Fourth failure: 4 s; then 8 s.
        assert_eq!(
            attempt(&mut m, AuthOutcome::Denied, now),
            [Effect::ClearErrorAfter(secs(4))]
        );
        assert_eq!(m.view().auth_error, "Too many attempts. Try again in 4 s.");
        now += secs(4);
        assert_eq!(
            attempt(&mut m, AuthOutcome::Denied, now),
            [Effect::ClearErrorAfter(secs(8))]
        );
        assert_eq!(m.view().auth_error, "Too many attempts. Try again in 8 s.");
    }

    #[test]
    fn relocking_does_not_reset_the_backoff_but_success_does() {
        let mut now = Instant::now();
        let mut m = LockMachine::new(true);
        for _ in 0..3 {
            let _ = attempt(&mut m, AuthOutcome::Denied, now);
            now += secs(60);
        }
        now -= secs(60);
        assert_eq!(m.handle(Input::Lock), [Effect::WriteFlag]);
        assert!(m.handle(Input::UnlockRequested { now }).is_empty());
        assert!(m.view().auth_error.starts_with("Too many attempts"));

        now += secs(2);
        assert_eq!(
            attempt(&mut m, AuthOutcome::Granted, now),
            [Effect::RemoveFlag, Effect::EmitUnlocked]
        );
        // Locked again later: three free attempts again.
        let _ = m.handle(Input::Lock);
        assert!(attempt(&mut m, AuthOutcome::Denied, now).is_empty());
        assert_eq!(m.view().auth_error, MSG_WRONG);
    }

    #[test]
    fn external_unlock() {
        let t = Instant::now();
        let mut m = LockMachine::new(false);
        assert!(m.handle(Input::ExternalUnlock).is_empty());

        let _ = m.handle(Input::Lock);
        let _ = attempt(&mut m, AuthOutcome::Denied, t);
        assert_eq!(
            m.handle(Input::ExternalUnlock),
            [Effect::RemoveFlag, Effect::EmitUnlocked]
        );
        assert_eq!(
            m.view(),
            LockView {
                locked: false,
                authenticating: false,
                auth_error: String::new()
            }
        );
    }

    #[test]
    fn external_unlock_during_authentication_emits_once() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        assert_eq!(
            m.handle(Input::UnlockRequested { now: t }),
            [Effect::StartAuth]
        );
        assert_eq!(
            m.handle(Input::ExternalUnlock),
            [Effect::RemoveFlag, Effect::EmitUnlocked]
        );
        // The late result only ends `authenticating`, whatever it says.
        let late = Input::AuthFinished {
            outcome: AuthOutcome::Denied,
            now: t,
        };
        assert!(m.handle(late).is_empty());
        assert_eq!(
            m.view(),
            LockView {
                locked: false,
                authenticating: false,
                auth_error: String::new()
            }
        );
    }

    #[test]
    fn lock_during_authentication_stays_locked_on_denial() {
        let t = Instant::now();
        let mut m = LockMachine::new(true);
        assert_eq!(
            m.handle(Input::UnlockRequested { now: t }),
            [Effect::StartAuth]
        );
        assert_eq!(m.handle(Input::Lock), [Effect::WriteFlag]);
        let denied = Input::AuthFinished {
            outcome: AuthOutcome::Denied,
            now: t,
        };
        assert!(m.handle(denied).is_empty());
        assert!(m.view().locked);
    }

    /// Every input in every reachable state: `locked` only ever becomes false
    /// through a granted authentication that was started, or ExternalUnlock.
    #[test]
    fn exhaustive_unlock_paths() {
        let t = Instant::now();
        let inputs = [
            Input::Lock,
            Input::UnlockRequested { now: t },
            Input::AuthFinished {
                outcome: AuthOutcome::Granted,
                now: t,
            },
            Input::AuthFinished {
                outcome: AuthOutcome::Denied,
                now: t,
            },
            Input::AuthFinished {
                outcome: AuthOutcome::Unavailable,
                now: t,
            },
            Input::ExternalUnlock,
            Input::RetryElapsed { now: t + secs(60) },
        ];
        // All input sequences of length 5 from the locked state.
        let n = inputs.len();
        for code in 0..n.pow(5) {
            let mut m = LockMachine::new(true);
            let mut c = code;
            for _ in 0..5 {
                let input = inputs[c % n];
                c /= n;
                let before = m.view();
                let effects = m.handle(input);
                let after = m.view();
                if before.locked && !after.locked {
                    let legit = match input {
                        Input::AuthFinished {
                            outcome: AuthOutcome::Granted,
                            ..
                        } => before.authenticating,
                        Input::ExternalUnlock => true,
                        _ => false,
                    };
                    assert!(legit, "unlocked by {input:?} from {before:?}");
                    assert_eq!(effects, [Effect::RemoveFlag, Effect::EmitUnlocked]);
                } else {
                    assert!(!effects.contains(&Effect::EmitUnlocked));
                    assert!(!effects.contains(&Effect::RemoveFlag));
                }
                if !before.locked && after.locked {
                    assert_eq!(input, Input::Lock);
                }
                if effects.contains(&Effect::StartAuth) {
                    assert!(before.locked && !before.authenticating && after.authenticating);
                }
                if !after.locked {
                    assert_eq!(after.auth_error, "");
                }
            }
        }
    }
}
