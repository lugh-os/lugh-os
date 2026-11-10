//! `LughBackend`: the production front-end of the JSON bridge
//! (docs/specs/shell-bridge.md). Owns the `ShellCore`; forwards QML calls to
//! it and delivers its events on the Qt thread.
//!
//! Event delivery: services send from arbitrary threads. Each event goes into
//! one shared queue; the first event after the queue was drained posts **one**
//! callback to the Qt event loop, every later one only pushes. The callback
//! drains the queue in order, folds consecutive patches of the same service
//! into one (later keys win: same final state) and emits `event(json)`. A
//! burst of 200 title changes is one wakeup and one model sync.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use cxx_qt::{CxxQtThread, CxxQtType, Threading};
use cxx_qt_lib::QString;
use lugh_shell_core::services::{Event, ShellCore, Sink};
use serde_json::Value;

use crate::bridge::ffi;

static STARTED: OnceLock<Instant> = OnceLock::new();

/// Call first thing in `main`: fixes the zero of [`uptime_ms`].
pub(crate) fn mark_start() {
    STARTED.get_or_init(Instant::now);
}

/// Milliseconds since [`mark_start`].
pub(crate) fn uptime_ms() -> f64 {
    STARTED.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

/// Qt messages (QML warnings included) → `tracing`, so they land in the journal
/// with the same format and filter as the Rust side.
pub(crate) fn qt_log(level: i32, category: &QString, message: &QString) {
    let category = category.to_string();
    let message = message.to_string();
    match level {
        0 => tracing::debug!(target: "qt", %category, "{message}"),
        1 => tracing::info!(target: "qt", %category, "{message}"),
        2 => tracing::warn!(target: "qt", %category, "{message}"),
        _ => tracing::error!(target: "qt", %category, "{message}"),
    }
}

/// Events waiting for the Qt thread.
#[derive(Default)]
struct Pending {
    events: Mutex<Vec<Event>>,
    /// True while a drain callback is queued on the Qt event loop.
    scheduled: AtomicBool,
}

impl Pending {
    /// Pushes `event`; returns true when the caller must schedule a drain.
    fn push(&self, event: Event) -> bool {
        match self.events.lock() {
            Ok(mut q) => q.push(event),
            Err(poisoned) => poisoned.into_inner().push(event),
        }
        !self.scheduled.swap(true, Ordering::AcqRel)
    }

    /// Takes everything queued so far. Clears `scheduled` first, so an event
    /// pushed during the drain schedules the next one (never lost).
    fn take(&self) -> Vec<Event> {
        self.scheduled.store(false, Ordering::Release);
        match self.events.lock() {
            Ok(mut q) => std::mem::take(&mut *q),
            Err(poisoned) => std::mem::take(&mut *poisoned.into_inner()),
        }
    }
}

/// Folds each run of consecutive patches of one service into a single patch.
/// `launcher` is left alone: its patches are tagged with the query they answer.
fn coalesce(events: Vec<Event>) -> Vec<Event> {
    let mut out: Vec<Event> = Vec::with_capacity(events.len());
    for event in events {
        if let (
            Event::Patch { service, data },
            Some(Event::Patch {
                service: last,
                data: merged,
            }),
        ) = (&event, out.last_mut())
        {
            if service == last && *service != "launcher" {
                for (k, v) in data {
                    merged.insert(k.clone(), v.clone());
                }
                continue;
            }
        }
        out.push(event);
    }
    out
}

/// `shell.primary == false`: another lugh-shell owns `space.lugh.Shell1`.
fn says_secondary(shell_state: Option<&Value>) -> bool {
    shell_state.and_then(|s| s.get("primary")) == Some(&Value::Bool(false))
}

/// Rust state behind the `Backend` QObject.
#[derive(Default)]
pub struct BackendRust {
    core: Option<ShellCore>,
    started: bool,
    pending: Arc<Pending>,
    snapshots: Arc<AtomicU32>,
}

/// Runs `f`, turning a panic into an error log: unwinding into Qt would abort
/// the shell.
fn guarded(what: &str, f: impl FnOnce()) {
    if catch_unwind(AssertUnwindSafe(f)).is_err() {
        tracing::error!("panic in {what}; the shell keeps running");
    }
}

impl ffi::Backend {
    /// See the bridge declaration.
    pub(crate) fn start(mut self: Pin<&mut Self>, mock: bool) -> i32 {
        let mut code = 2;
        let this = self.as_mut();
        guarded("start", || code = Self::start_inner(this, mock));
        code
    }

    fn start_inner(mut self: Pin<&mut Self>, mock: bool) -> i32 {
        if std::mem::replace(&mut self.as_mut().rust_mut().started, true) {
            return 0;
        }
        let qt = self.qt_thread();
        watch_signals(qt.clone());
        if mock {
            tracing::info!("--mock: no backend attached, QML runs on its mock data");
            return 0;
        }

        let pending = Arc::clone(&self.pending);
        let sink = Sink::new(move |event| {
            if let Event::Patch { service, data } = &event {
                if *service == "shell" && data.get("primary") == Some(&Value::Bool(false)) {
                    tracing::info!("another lugh-shell owns the bus name; exiting");
                    let _ = qt.queue(|_| ffi::host_quit(0));
                    return;
                }
            }
            if pending.push(event) {
                // Fails only when the QObject is gone (shutdown): nothing to do.
                let _ = qt.queue(|backend| backend.drain());
            }
        });

        let core = match ShellCore::start(sink) {
            Ok(core) => core,
            Err(e) => {
                tracing::error!(%e, "could not start the shell core");
                return 2;
            }
        };
        if says_secondary(core.snapshot().get("shell")) {
            tracing::info!("another lugh-shell owns the bus name; exiting");
            return 1;
        }
        tracing::info!(ms = uptime_ms().round(), "core started");
        self.as_mut().rust_mut().core = Some(core);
        0
    }

    /// See the bridge declaration.
    pub(crate) fn snapshots(&self) -> i32 {
        i32::try_from(self.snapshots.load(Ordering::Relaxed)).unwrap_or(i32::MAX)
    }

    /// See the bridge declaration.
    pub(crate) fn call(mut self: Pin<&mut Self>, method: &QString, args_json: &QString) {
        let this = self.as_mut();
        guarded("call", || Self::call_inner(this, method, args_json));
    }

    fn call_inner(mut self: Pin<&mut Self>, method: &QString, args_json: &QString) {
        let method = method.to_string();
        let Some(core) = self.core.as_ref() else {
            tracing::debug!(%method, "call without a core (mock mode); ignored");
            return;
        };
        if method == "core.snapshot" {
            let json = serde_json::json!({ "t": "snapshot", "d": core.snapshot() }).to_string();
            self.snapshots.fetch_add(1, Ordering::Relaxed);
            tracing::debug!(bytes = json.len(), "snapshot");
            self.as_mut().event(QString::from(&json));
            return;
        }
        let args = args_json.to_string();
        let args: Vec<Value> = if args.is_empty() || args == "[]" {
            Vec::new()
        } else {
            match serde_json::from_str(&args) {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!(%method, %e, "call arguments are not a JSON array; ignored");
                    return;
                }
            }
        };
        if let Err(e) = core.call(&method, &args) {
            tracing::debug!(%method, %e, "call failed");
        }
    }

    /// Qt thread: delivers everything queued since the last drain, in order.
    fn drain(mut self: Pin<&mut Self>) {
        let this = self.as_mut();
        guarded("event delivery", || {
            let mut this = this;
            let events = coalesce(this.pending.take());
            for event in events {
                let json = event.to_json().to_string();
                this.as_mut().event(QString::from(&json));
            }
        });
    }
}

/// SIGTERM / SIGINT → `QCoreApplication::exit(0)` on the Qt thread. The watcher
/// thread sleeps in `sigwait`-like blocking until a signal arrives (no polling).
fn watch_signals(qt: CxxQtThread<ffi::Backend>) {
    use signal_hook::consts::{SIGINT, SIGTERM};
    let mut signals = match signal_hook::iterator::Signals::new([SIGTERM, SIGINT]) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(%e, "could not install signal handlers");
            return;
        }
    };
    let spawned = std::thread::Builder::new()
        .name("lugh-signals".into())
        .spawn(move || {
            if let Some(signal) = signals.forever().next() {
                tracing::info!(signal, "termination signal; quitting");
                if qt.queue(|_| ffi::host_quit(0)).is_err() {
                    std::process::exit(0);
                }
            }
        });
    if let Err(e) = spawned {
        tracing::warn!(%e, "could not start the signal thread");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn patch(service: &'static str, data: Value) -> Event {
        let Value::Object(data) = data else {
            unreachable!("test patches are objects")
        };
        Event::Patch { service, data }
    }

    #[test]
    fn coalesce_merges_runs_and_keeps_order() {
        let out = coalesce(vec![
            patch("wm", json!({ "title": "a", "x": 1 })),
            patch("wm", json!({ "title": "b" })),
            Event::Signal { service: "osd", name: "requested", args: vec![] },
            patch("wm", json!({ "title": "c" })),
            patch("launcher", json!({ "query": "a" })),
            patch("launcher", json!({ "query": "ab" })),
        ]);
        assert_eq!(out.len(), 5);
        assert_eq!(out[0], patch("wm", json!({ "title": "b", "x": 1 })));
        assert_eq!(out[2], patch("wm", json!({ "title": "c" })));
    }

    #[test]
    fn pending_schedules_once_per_drain() {
        let p = Pending::default();
        assert!(p.push(patch("wm", json!({ "a": 1 }))));
        assert!(!p.push(patch("wm", json!({ "a": 2 }))));
        assert_eq!(p.take().len(), 2);
        assert!(p.push(patch("wm", json!({ "a": 3 }))));
    }

    #[test]
    fn secondary_detection() {
        assert!(says_secondary(Some(&json!({ "primary": false }))));
        assert!(!says_secondary(Some(&json!({ "primary": true }))));
        assert!(!says_secondary(Some(&json!({}))));
        assert!(!says_secondary(None));
    }
}
