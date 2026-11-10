//! What the greeter remembers between boots: the last user and session.
//!
//! Stored as JSON in `/var/lib/lugh-greeter/state.json`, written atomically
//! (temp file + rename). A missing, unreadable or corrupt file is the same as
//! no state: the greeter must always start.

use std::fs;
use std::io::{self, Write as _};
use std::path::Path;

use serde::{Deserialize, Serialize};

/// Default location.
pub const STATE_FILE: &str = "/var/lib/lugh-greeter/state.json";

/// Persisted greeter state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// Login name of the last user who signed in.
    pub last_user: String,
    /// Id of the last session started.
    pub last_session: String,
}

impl State {
    /// Reads the state; anything wrong gives the default.
    #[must_use]
    pub fn load(path: &Path) -> Self {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// Writes the state atomically, creating the directory when needed.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let dir = path
            .parent()
            .ok_or_else(|| io::Error::other("state path has no directory"))?;
        fs::create_dir_all(dir)?;
        let tmp = path.with_extension(format!("tmp{}", std::process::id()));
        let result = (|| {
            let mut file = fs::File::create(&tmp)?;
            file.write_all(&serde_json::to_vec(self)?)?;
            file.sync_all()?;
            fs::rename(&tmp, path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_creates_the_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deep/er/state.json");
        assert_eq!(State::load(&path), State::default());
        let state = State {
            last_user: "amara".into(),
            last_session: "lugh".into(),
        };
        state.save(&path).unwrap();
        assert_eq!(State::load(&path), state);
        // Only the state file is left behind.
        let names: Vec<_> = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["state.json"]);
    }

    #[test]
    fn corruption_is_tolerated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        for junk in [
            &b""[..],
            b"{",
            b"\xff\xfe\0",
            b"[1,2]",
            b"{\"last_user\":7}",
        ] {
            fs::write(&path, junk).unwrap();
            assert_eq!(State::load(&path), State::default());
        }
        fs::write(&path, br#"{"last_user":"keza","future_field":1}"#).unwrap();
        assert_eq!(State::load(&path).last_user, "keza");
    }

    #[test]
    fn save_fails_cleanly_when_the_directory_is_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let blocker = dir.path().join("blocker");
        fs::write(&blocker, b"x").unwrap();
        assert!(State::default().save(&blocker.join("state.json")).is_err());
    }
}
