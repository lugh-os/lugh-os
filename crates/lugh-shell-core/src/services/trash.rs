//! `Services.trash`: the XDG trash (`$XDG_DATA_HOME/Trash`).
//!
//! State: `full` (bool): `Trash/files` has entries. Checked at start, after
//! our own operations and on `refresh()` (the dock calls it on hover); there
//! is no polling.
//! Methods: `open()` (file manager on `trash:///`), `empty()` (DESTRUCTIVE:
//! deletes everything under `Trash/files` and `Trash/info`; only ever on
//! this explicit call), `refresh()`.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};

use super::{CallError, Context, Service, Sink};
use crate::launch::{self, LaunchRequest};

/// The user's trash directory: `$XDG_DATA_HOME/Trash`, falling back to
/// `~/.local/share/Trash`. `None` when neither gives an absolute path.
fn trash_dir(xdg_data_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let absolute = |v: OsString| Some(PathBuf::from(v)).filter(|p| p.is_absolute());
    xdg_data_home
        .and_then(absolute)
        .or_else(|| home.and_then(absolute).map(|h| h.join(".local/share")))
        .map(|base| base.join("Trash"))
}

/// Whether `<trash>/files` has at least one entry.
fn is_full(trash: &Path) -> bool {
    std::fs::read_dir(trash.join("files")).is_ok_and(|mut d| d.next().is_some())
}

/// Deletes everything under `<trash>/files` and `<trash>/info`, keeping the
/// two directories. Symlinks are removed, never followed. Returns how many
/// entries could not be removed.
fn empty_trash(trash: &Path) -> usize {
    // Refuse anything that is not a trash directory, whatever the caller did.
    if !trash.is_absolute() || trash.file_name().is_none_or(|n| n != "Trash") {
        tracing::error!(path = %trash.display(), "not a trash directory; nothing deleted");
        return 0;
    }
    let mut failed = 0;
    for sub in ["files", "info"] {
        let Ok(entries) = std::fs::read_dir(trash.join(sub)) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
            let removed = if is_dir {
                std::fs::remove_dir_all(&path)
            } else {
                std::fs::remove_file(&path)
            };
            if let Err(e) = removed {
                failed += 1;
                tracing::warn!(%e, path = %path.display(), "could not delete from the trash");
            }
        }
    }
    failed
}

#[derive(Debug)]
struct Shared {
    dir: Option<PathBuf>,
    full: AtomicBool,
    sink: Sink,
}

impl Shared {
    /// Re-checks the directory and patches `full` when it changed.
    fn refresh(&self) {
        let full = self.dir.as_deref().is_some_and(is_full);
        if self.full.swap(full, Ordering::SeqCst) != full {
            self.sink.patch("trash", json!({ "full": full }));
        }
    }
}

/// The `trash` service.
#[derive(Debug)]
pub struct TrashService {
    shared: Arc<Shared>,
    runtime: tokio::runtime::Handle,
}

impl TrashService {
    fn new(ctx: &Context, dir: Option<PathBuf>) -> Self {
        let full = dir.as_deref().is_some_and(is_full);
        Self {
            shared: Arc::new(Shared {
                dir,
                full: AtomicBool::new(full),
                sink: ctx.sink.clone(),
            }),
            runtime: ctx.runtime.clone(),
        }
    }
}

impl Service for TrashService {
    fn name(&self) -> &'static str {
        "trash"
    }

    fn state(&self) -> Value {
        json!({ "full": self.shared.full.load(Ordering::SeqCst) })
    }

    fn call(&self, method: &str, _args: &[Value]) -> Result<Value, CallError> {
        let shared = Arc::clone(&self.shared);
        match method {
            "refresh" => shared.refresh(),
            "open" => {
                self.runtime.spawn_blocking(move || {
                    let argv = vec!["xdg-open".to_owned(), "trash:///".to_owned()];
                    if let Err(e) = launch::launch(&LaunchRequest::new("xdg-open", argv)) {
                        tracing::warn!(%e, "could not open the trash");
                    }
                    shared.refresh();
                });
            }
            "empty" => {
                let dir = shared
                    .dir
                    .clone()
                    .ok_or_else(|| CallError::Failed("no trash directory".into()))?;
                self.runtime.spawn_blocking(move || {
                    let failed = empty_trash(&dir);
                    if failed > 0 {
                        tracing::warn!(failed, "some trash entries could not be deleted");
                    }
                    shared.refresh();
                });
            }
            other => return Err(CallError::UnknownMethod(format!("trash.{other}"))),
        }
        Ok(Value::Null)
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let dir = trash_dir(std::env::var_os("XDG_DATA_HOME"), std::env::var_os("HOME"));
    Box::new(TrashService::new(ctx, dir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, RwLock};
    use std::time::{Duration, Instant};

    #[test]
    fn trash_dir_resolution() {
        assert_eq!(
            trash_dir(Some("/x/data".into()), Some("/home/a".into())),
            Some(PathBuf::from("/x/data/Trash"))
        );
        assert_eq!(
            trash_dir(Some("relative".into()), Some("/home/a".into())),
            Some(PathBuf::from("/home/a/.local/share/Trash"))
        );
        assert_eq!(trash_dir(None, None), None);
    }

    /// A temporary XDG_DATA_HOME with a filled trash and a bystander file.
    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let data_home = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let trash = data_home.path().join("Trash");
        let w = |p: PathBuf| {
            if let Some(d) = p.parent() {
                std::fs::create_dir_all(d).unwrap_or_else(|e| panic!("{e}"));
            }
            std::fs::write(p, b"x").unwrap_or_else(|e| panic!("{e}"));
        };
        w(trash.join("files/report.pdf"));
        w(trash.join("files/folder/nested/deep.txt"));
        w(trash.join("info/report.pdf.trashinfo"));
        w(trash.join("info/folder.trashinfo"));
        w(data_home.path().join("keep/precious.txt"));
        // A symlink in the trash pointing outside it must not be followed.
        std::os::unix::fs::symlink(data_home.path().join("keep"), trash.join("files/link"))
            .unwrap_or_else(|e| panic!("{e}"));
        (data_home, trash)
    }

    #[test]
    fn emptying_deletes_only_the_trash_contents() {
        let (data_home, trash) = fixture();
        assert!(is_full(&trash));
        assert_eq!(empty_trash(&trash), 0);
        assert!(!is_full(&trash));
        assert!(trash.join("files").is_dir() && trash.join("info").is_dir());
        let left = |sub: &str| {
            std::fs::read_dir(trash.join(sub))
                .map(Iterator::count)
                .unwrap_or(99)
        };
        assert_eq!((left("files"), left("info")), (0, 0));
        assert!(data_home.path().join("keep/precious.txt").is_file());
        // Again on an empty trash, and on one that does not exist: no-ops.
        assert_eq!(empty_trash(&trash), 0);
        assert_eq!(empty_trash(&data_home.path().join("missing/Trash")), 0);
    }

    #[test]
    fn refuses_paths_that_are_not_a_trash() {
        let (data_home, _trash) = fixture();
        let not_trash = data_home.path().join("keep");
        std::fs::create_dir_all(not_trash.join("files")).unwrap_or_else(|e| panic!("{e}"));
        std::fs::write(not_trash.join("files/a"), b"x").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(empty_trash(&not_trash), 0);
        assert!(not_trash.join("files/a").is_file());
        assert_eq!(empty_trash(Path::new("Trash")), 0);
        assert!(!is_full(Path::new("/nonexistent/Trash")));
    }

    #[test]
    fn service_reports_and_empties() {
        let (_data_home, trash) = fixture();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .build()
            .unwrap_or_else(|e| panic!("{e}"));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s2 = Arc::clone(&seen);
        let ctx = Context {
            sink: Sink::new(move |e| {
                if let Ok(mut v) = s2.lock() {
                    v.push(e.to_json());
                }
            }),
            runtime: runtime.handle().clone(),
            config: Arc::new(RwLock::new(crate::config::DesktopConfig::default())),
        };
        let svc = TrashService::new(&ctx, Some(trash.clone()));
        assert_eq!(svc.state(), json!({ "full": true }));
        // Nothing changed: refresh sends nothing.
        assert_eq!(svc.call("refresh", &[]), Ok(Value::Null));
        assert!(seen.lock().is_ok_and(|v| v.is_empty()));
        assert!(matches!(
            svc.call("shred", &[]),
            Err(CallError::UnknownMethod(_))
        ));

        assert_eq!(svc.call("empty", &[]), Ok(Value::Null));
        let deadline = Instant::now() + Duration::from_secs(5);
        while seen.lock().is_ok_and(|v| v.is_empty()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let events = seen.lock().map(|v| v.clone()).unwrap_or_default();
        assert_eq!(
            events,
            [json!({ "t": "patch", "s": "trash", "d": { "full": false } })]
        );
        assert_eq!(svc.state(), json!({ "full": false }));
        assert!(!is_full(&trash));

        // Something lands in the trash: the next refresh says so.
        std::fs::write(trash.join("files/new.txt"), b"x").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(svc.call("refresh", &[]), Ok(Value::Null));
        assert_eq!(svc.state(), json!({ "full": true }));
    }
}
