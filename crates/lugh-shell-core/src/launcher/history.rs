//! Launch history: per-app launch counts and last-used times, persisted as
//! JSON in `$XDG_STATE_HOME/lugh/launcher-history.json`. Used for ranking
//! (frequency × recency) and for the empty-query "recent apps" row.

use std::collections::HashMap;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// File name inside the state directory.
pub const HISTORY_FILE: &str = "launcher-history.json";

/// Half-life of the recency weight.
const HALF_LIFE_SECS: f64 = 7.0 * 24.0 * 3600.0;
/// Launch count at which the frequency weight saturates.
const FREQ_SATURATION: f64 = 30.0;

/// Usage of one app.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    /// Number of launches.
    pub count: u32,
    /// Last launch, seconds since the Unix epoch.
    pub last_used: u64,
}

impl Usage {
    /// Ranking weight in `[0, 1]`: log-scaled frequency (saturating at 30
    /// launches) times a recency factor that halves every 7 days and keeps a
    /// 30 % floor, so long-term favourites still count.
    pub fn weight(&self, now: u64) -> f64 {
        if self.count == 0 {
            return 0.0;
        }
        let freq = (f64::from(self.count).ln_1p() / FREQ_SATURATION.ln_1p()).min(1.0);
        let age = now.saturating_sub(self.last_used) as f64;
        let recency = 0.3 + 0.7 * (-age / HALF_LIFE_SECS * std::f64::consts::LN_2).exp();
        freq * recency
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct FileFormat {
    version: u32,
    apps: HashMap<String, Usage>,
}

/// Errors writing the history file.
#[derive(Debug, thiserror::Error)]
pub enum HistoryError {
    /// The state directory or file could not be written.
    #[error("cannot write launcher history {}: {source}", path.display())]
    Write {
        /// File that failed.
        path: PathBuf,
        /// Underlying error.
        #[source]
        source: io::Error,
    },
}

/// Launch history. Every change is written to disk at once (atomically:
/// temp file + rename); launches are rare, so this costs nothing noticeable.
#[derive(Debug, Default)]
pub struct History {
    path: Option<PathBuf>,
    apps: HashMap<String, Usage>,
    revision: u64,
}

impl History {
    /// History kept in memory only (tests, guest sessions).
    pub fn in_memory() -> Self {
        Self::default()
    }

    /// Loads `path`. A missing file gives an empty history. A corrupt file is
    /// copied to `<path>.bak` and the history starts empty (logged, never
    /// fatal).
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let apps = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<FileFormat>(&bytes) {
                Ok(f) => f.apps,
                Err(err) => {
                    let bak = backup_path(&path);
                    tracing::warn!(path = %path.display(), %err, bak = %bak.display(),
                        "corrupt launcher history; starting empty");
                    if let Err(e) = std::fs::rename(&path, &bak) {
                        tracing::warn!(%e, "cannot keep a backup of the corrupt history");
                    }
                    HashMap::new()
                }
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound => HashMap::new(),
            Err(err) => {
                tracing::warn!(path = %path.display(), %err, "cannot read launcher history");
                HashMap::new()
            }
        };
        Self {
            path: Some(path),
            apps,
            revision: 0,
        }
    }

    /// `$XDG_STATE_HOME/lugh/launcher-history.json` (default
    /// `~/.local/state/lugh/`), or in-memory when no home is known.
    pub fn from_env() -> Self {
        match super::state_dir() {
            Some(dir) => Self::load(dir.join(HISTORY_FILE)),
            None => Self::in_memory(),
        }
    }

    /// The backing file, if any.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Records a launch of `app_id` at `now` (Unix seconds) and saves.
    pub fn record(&mut self, app_id: &str, now: u64) -> Result<(), HistoryError> {
        let id = app_id.strip_suffix(".desktop").unwrap_or(app_id);
        let u = self.apps.entry(id.to_owned()).or_default();
        u.count = u.count.saturating_add(1);
        u.last_used = u.last_used.max(now);
        self.revision += 1;
        self.save()
    }

    /// Forgets one app and saves.
    pub fn forget(&mut self, app_id: &str) -> Result<(), HistoryError> {
        if self.apps.remove(app_id).is_some() {
            self.revision += 1;
            self.save()?;
        }
        Ok(())
    }

    /// Forgets everything and saves ("Clear history").
    pub fn clear(&mut self) -> Result<(), HistoryError> {
        self.apps.clear();
        self.revision += 1;
        self.save()
    }

    /// Usage of one app.
    pub fn usage(&self, app_id: &str) -> Option<Usage> {
        self.apps.get(app_id).copied()
    }

    /// The `n` most recently used app ids, newest first (ties: more launches
    /// first, then id).
    pub fn recent(&self, n: usize) -> Vec<&str> {
        let mut v: Vec<(&String, &Usage)> = self.apps.iter().collect();
        v.sort_by(|a, b| {
            b.1.last_used
                .cmp(&a.1.last_used)
                .then(b.1.count.cmp(&a.1.count))
                .then(a.0.cmp(b.0))
        });
        v.into_iter().take(n).map(|(id, _)| id.as_str()).collect()
    }

    /// All recorded apps.
    pub fn iter(&self) -> impl Iterator<Item = (&str, Usage)> {
        self.apps.iter().map(|(k, v)| (k.as_str(), *v))
    }

    /// Number of recorded apps.
    pub fn len(&self) -> usize {
        self.apps.len()
    }

    /// True when nothing is recorded.
    pub fn is_empty(&self) -> bool {
        self.apps.is_empty()
    }

    /// Bumped on every change (lets the launcher cache ranking boosts).
    pub(crate) fn revision(&self) -> u64 {
        self.revision
    }

    fn save(&self) -> Result<(), HistoryError> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let err = |source| HistoryError::Write {
            path: path.clone(),
            source,
        };
        let file = FileFormat {
            version: 1,
            apps: self.apps.clone(),
        };
        let json = serde_json::to_vec(&file).map_err(|e| err(io::Error::other(e)))?;
        write_atomic(path, &json).map_err(err)
    }
}

fn backup_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(".bak");
    PathBuf::from(s)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".tmp{}", std::process::id()));
    let tmp = PathBuf::from(tmp);
    let result = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 24 * 3600;

    #[test]
    fn record_persist_reload() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state/lugh").join(HISTORY_FILE);
        let mut h = History::load(&path);
        assert!(h.is_empty());
        h.record("firefox", 100).unwrap();
        h.record("firefox.desktop", 200).unwrap();
        h.record("vlc", 150).unwrap();
        let h2 = History::load(&path);
        assert_eq!(
            h2.usage("firefox"),
            Some(Usage {
                count: 2,
                last_used: 200
            })
        );
        assert_eq!(h2.recent(5), ["firefox", "vlc"]);
        assert_eq!(h2.recent(1), ["firefox"]);
        assert!(
            !dir.path().join("state/lugh").read_dir().unwrap().any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".tmp"))
        );
    }

    #[test]
    fn clear_and_forget() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(HISTORY_FILE);
        let mut h = History::load(&path);
        h.record("a", 1).unwrap();
        h.record("b", 2).unwrap();
        h.forget("a").unwrap();
        assert_eq!(History::load(&path).recent(9), ["b"]);
        h.clear().unwrap();
        assert!(History::load(&path).is_empty());
    }

    #[test]
    fn corrupt_file_recovers_with_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(HISTORY_FILE);
        std::fs::write(&path, b"{ not json").unwrap();
        let mut h = History::load(&path);
        assert!(h.is_empty());
        let bak = dir.path().join(format!("{HISTORY_FILE}.bak"));
        assert_eq!(std::fs::read(&bak).unwrap(), b"{ not json");
        h.record("x", 5).unwrap();
        assert_eq!(History::load(&path).usage("x").unwrap().count, 1);
    }

    #[test]
    fn wrong_shape_is_corrupt_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(HISTORY_FILE);
        std::fs::write(&path, br#"{"version":1,"apps":{"a":{"count":"many"}}}"#).unwrap();
        assert!(History::load(&path).is_empty());
    }

    #[test]
    fn weight_frequency_and_recency() {
        let now = 1000 * DAY;
        let w = |count, age| {
            Usage {
                count,
                last_used: now - age,
            }
            .weight(now)
        };
        assert_eq!(w(0, 0), 0.0);
        assert!(w(10, 0) > w(2, 0), "more launches weigh more");
        assert!(w(5, 0) > w(5, 7 * DAY), "recent weighs more");
        let half = w(5, 7 * DAY) / w(5, 0);
        assert!(
            (half - 0.65).abs() < 1e-9,
            "7-day half-life above the floor"
        );
        assert!(w(5, 365 * DAY) > 0.0, "old favourites keep a floor");
        assert!(w(1000, 0) <= 1.0);
    }

    #[test]
    fn in_memory_never_writes() {
        let mut h = History::in_memory();
        h.record("a", 1).unwrap();
        assert_eq!(h.len(), 1);
        assert!(h.path().is_none());
    }
}
