//! The cxx-qt bridge: the only module of this crate with `unsafe` in it, and
//! only what the bridge macro requires (`unsafe extern "C++"` declarations and
//! the code the macro generates).
//!
//! - `Backend`: the QObject QML sees as `LughBackend` (logic in `backend.rs`).
//! - `host_run` / `host_quit`: the C++ host in `cpp/host.cpp`.
//! - `qt_log`: Qt's message handler forwards here (→ `tracing`).
#![allow(unsafe_code)]

#[cxx_qt::bridge]
pub(crate) mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        type Backend = super::BackendRust;

        /// `LughBackend.call(method, argsJson)`: never blocks; outcomes arrive
        /// as `event`s. `core.snapshot` is answered with one snapshot event.
        #[qinvokable]
        fn call(self: Pin<&mut Backend>, method: &QString, args_json: &QString);

        /// Host only: starts the signal watcher and (unless `mock`) the core.
        /// Returns 0 = running, 1 = another shell owns the bus name, 2 = error.
        #[qinvokable]
        fn start(self: Pin<&mut Backend>, mock: bool) -> i32;

        /// Host only: number of snapshot events emitted so far (`--check`).
        #[qinvokable]
        fn snapshots(self: &Backend) -> i32;

        /// One bridge event (docs/specs/shell-bridge.md), always on the Qt thread.
        #[qsignal]
        fn event(self: Pin<&mut Backend>, json: QString);
    }

    impl cxx_qt::Threading for Backend {}

    unsafe extern "C++" {
        include!("lugh-shell/cpp/host.h");

        /// Runs the whole Qt application; returns the process exit code.
        /// `args` (argv for Qt) and `import_paths` are newline-separated;
        /// `main_qml` is a file path or a `qrc:` URL.
        #[rust_name = "host_run"]
        fn lugh_host_run(
            args: &QString,
            main_qml: &QString,
            import_paths: &QString,
            icon_theme: &QString,
            mock: bool,
            check: bool,
        ) -> i32;

        /// `QCoreApplication::exit(code)`; Qt thread only.
        #[rust_name = "host_quit"]
        fn lugh_host_quit(code: i32);
    }

    extern "Rust" {
        /// Qt message handler target. `level`: 0 debug, 1 info, 2 warning,
        /// 3 critical/fatal.
        #[cxx_name = "lugh_qt_log"]
        fn qt_log(level: i32, category: &QString, message: &QString);
        /// Milliseconds since the process started.
        #[cxx_name = "lugh_uptime_ms"]
        fn uptime_ms() -> f64;
    }
}

pub(crate) use crate::backend::BackendRust;
use crate::backend::{qt_log, uptime_ms};
