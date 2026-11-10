//! The one Rust-backed QObject of the greeter: a thin pipe between the QML
//! adapter (`qml/backend/GreetdBackend.qml`) and `lugh_greetd::backend`.
//!
//! QML calls `init()` once (start-up state as JSON) and `call(method, arg)`
//! for every contract function; results come back through `notified(json)`,
//! queued onto the Qt thread from the backend's worker thread.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;

        include!("shim.h");
        /// Runs the application; see `cpp/shim.h`.
        #[namespace = "lugh"]
        fn greeter_run(qml_dir: &str, import_path: &str, offscreen: bool, check: bool) -> i32;
        /// Ends the event loop.
        #[namespace = "lugh"]
        fn greeter_quit(code: i32);
    }

    extern "RustQt" {
        /// Exposed to QML as `GreetdBridge` in `import os.lugh.greeter`.
        #[qobject]
        #[qml_element]
        type GreetdBridge = super::GreetdBridgeRust;

        /// Starts the backend and returns the start-up state as JSON.
        #[qinvokable]
        fn init(self: Pin<&mut GreetdBridge>) -> QString;

        /// Runs a contract function (`createSession`, `respond`, ...).
        #[qinvokable]
        fn call(self: Pin<&mut GreetdBridge>, method: &QString, arg: &QString);

        /// A backend event as JSON (`{"event": "promptRequested", ...}`).
        #[qsignal]
        fn notified(self: Pin<&mut GreetdBridge>, json: QString);
    }

    impl cxx_qt::Threading for GreetdBridge {}
}

use core::pin::Pin;
use std::sync::OnceLock;
use std::time::Duration;

use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::QString;
use lugh_greetd::backend::{Backend, Event, Options};

/// How the backend starts; set by `main` before the QML loads.
pub static OPTIONS: OnceLock<Options> = OnceLock::new();

/// After greetd accepts `start_session` the greeter must go away: greetd
/// waits for it before starting the session. Leave even if Qt hangs.
const EXIT_GRACE: Duration = Duration::from_secs(2);

/// Rust-side state behind `GreetdBridge`.
#[derive(Debug, Default)]
pub struct GreetdBridgeRust {
    backend: Option<Backend>,
}

impl qobject::GreetdBridge {
    /// Starts the backend (once) and returns the start-up state.
    pub fn init(mut self: Pin<&mut Self>) -> QString {
        if self.backend.is_none() {
            let options = OPTIONS.get().cloned().unwrap_or_default();
            let qt_thread = self.qt_thread();
            let backend = Backend::start(options, move |event| {
                let started = event == Event::SessionStarted;
                let Ok(json) = serde_json::to_string(&event) else {
                    return;
                };
                let queued = qt_thread.queue(move |bridge| {
                    bridge.notified(QString::from(&json));
                    if started {
                        qobject::greeter_quit(0);
                    }
                });
                if started {
                    std::thread::spawn(|| {
                        std::thread::sleep(EXIT_GRACE);
                        std::process::exit(0);
                    });
                } else if queued.is_err() {
                    tracing::warn!("the UI is gone; dropping a backend event");
                }
            });
            self.as_mut().rust_mut().backend = Some(backend);
        }
        let json = self
            .backend
            .as_ref()
            .map(Backend::initial_json)
            .unwrap_or_default();
        QString::from(&autotest::annotate(json))
    }

    /// Forwards a contract function to the backend.
    pub fn call(self: Pin<&mut Self>, method: &QString, arg: &QString) {
        let method = String::from(method);
        // `arg` may be a password: it moves into the backend, which wipes it.
        let known = self
            .backend
            .as_ref()
            .is_some_and(|backend| backend.call(&method, String::from(arg)));
        if !known {
            tracing::warn!(%method, "call ignored (unknown method or backend not started)");
        }
    }
}

/// `LUGH_GREETER_AUTOTEST=user:password` (feature `test-hooks` only): tells
/// the QML adapter to log in by itself, for the end-to-end check.
mod autotest {
    #[cfg(feature = "test-hooks")]
    pub(super) fn annotate(json: String) -> String {
        let Ok(spec) = std::env::var("LUGH_GREETER_AUTOTEST") else {
            return json;
        };
        let Some((user, password)) = spec.split_once(':') else {
            return json;
        };
        let Ok(serde_json::Value::Object(mut state)) = serde_json::from_str(&json) else {
            return json;
        };
        state.insert(
            "autotest".to_owned(),
            serde_json::json!({ "user": user, "password": password }),
        );
        serde_json::Value::Object(state).to_string()
    }

    #[cfg(not(feature = "test-hooks"))]
    pub(super) fn annotate(json: String) -> String {
        json
    }
}
