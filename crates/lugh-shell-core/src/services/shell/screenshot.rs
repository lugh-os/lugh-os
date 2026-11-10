//! `Screenshot(s mode)`: capture with `grim` (and `slurp` for an area) into
//! `~/Pictures/Screenshots/Screenshot-<timestamp>.png`, then copy the PNG to
//! the clipboard with `wl-copy` when it is installed.
//!
//! - `screen`: every output.
//! - `area`: `slurp` lets the user drag a rectangle; Escape cancels quietly.
//! - `window`: the active window's box from `hyprctl -j activewindow`; when
//!   that is not available the whole screen is captured instead.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::Command;

/// What to capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    Area,
    Screen,
    Window,
}

impl Mode {
    pub(crate) fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "area" | "region" => Some(Self::Area),
            "screen" | "output" | "full" | "" => Some(Self::Screen),
            "window" => Some(Self::Window),
            _ => None,
        }
    }
}

/// How a capture ended.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Written to `path`; `copied` says whether it is on the clipboard too.
    Saved { path: PathBuf, copied: bool },
    /// A required tool is not installed (`grim` or `slurp`).
    Missing(&'static str),
    /// The user cancelled the area selection.
    Cancelled,
    /// The tool ran and failed; the text is for the log.
    Failed(String),
}

/// Finds an executable in `$PATH` (no subprocess).
pub(crate) fn find_tool(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
}

/// `Screenshot-<stamp>.png` under `dir`, never an existing file.
pub(crate) fn target_path(dir: &Path, stamp: &str) -> PathBuf {
    let first = dir.join(format!("Screenshot-{stamp}.png"));
    if !first.exists() {
        return first;
    }
    (2..1000)
        .map(|i| dir.join(format!("Screenshot-{stamp}-{i}.png")))
        .find(|p| !p.exists())
        .unwrap_or(first)
}

/// grim's `-g` geometry (`"x,y wxh"`) from `hyprctl -j activewindow`.
pub(crate) fn window_geometry(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let n = |key: &str, i: usize| v.get(key)?.get(i)?.as_i64();
    let (x, y, w, h) = (n("at", 0)?, n("at", 1)?, n("size", 0)?, n("size", 1)?);
    (w > 0 && h > 0).then(|| format!("{x},{y} {w}x{h}"))
}

async fn output_of(cmd: &mut Command) -> Option<String> {
    let out = cmd
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
}

/// Local time for the file name; `date` knows the time zone, we do not.
async fn timestamp() -> String {
    match output_of(Command::new("date").arg("+%Y-%m-%d_%H-%M-%S")).await {
        Some(s) => s,
        None => std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or_else(|_| "0".to_owned(), |d| d.as_secs().to_string()),
    }
}

async fn copy_to_clipboard(file: &Path) -> bool {
    let (Some(tool), Ok(png)) = (find_tool("wl-copy"), std::fs::File::open(file)) else {
        return false;
    };
    // wl-copy forks to serve the selection and returns at once.
    Command::new(tool)
        .args(["--type", "image/png"])
        .stdin(Stdio::from(png))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

/// Takes the screenshot. Never panics, never blocks the caller's thread
/// (subprocesses run on the runtime).
pub(crate) async fn capture(mode: Mode) -> Outcome {
    let Some(grim) = find_tool("grim") else {
        return Outcome::Missing("grim");
    };
    let geometry = match mode {
        Mode::Screen => None,
        Mode::Area => {
            let Some(slurp) = find_tool("slurp") else {
                return Outcome::Missing("slurp");
            };
            match output_of(&mut Command::new(slurp)).await {
                Some(g) => Some(g),
                None => return Outcome::Cancelled,
            }
        }
        Mode::Window => match find_tool("hyprctl") {
            Some(hyprctl) => output_of(Command::new(hyprctl).args(["-j", "activewindow"]))
                .await
                .and_then(|json| window_geometry(&json)),
            None => None,
        },
    };
    let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty()) else {
        return Outcome::Failed("HOME is not set".to_owned());
    };
    let dir = PathBuf::from(home).join("Pictures").join("Screenshots");
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        return Outcome::Failed(format!("{}: {e}", dir.display()));
    }
    let path = target_path(&dir, &timestamp().await);
    let mut cmd = Command::new(grim);
    if let Some(g) = &geometry {
        cmd.args(["-g", g]);
    }
    let run = cmd
        .arg(&path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await;
    match run {
        Ok(out) if out.status.success() && path.is_file() => {
            let copied = copy_to_clipboard(&path).await;
            Outcome::Saved { path, copied }
        }
        Ok(out) => Outcome::Failed(String::from_utf8_lossy(&out.stderr).trim().to_owned()),
        Err(e) => Outcome::Failed(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes() {
        assert_eq!(Mode::parse("area"), Some(Mode::Area));
        assert_eq!(Mode::parse("screen"), Some(Mode::Screen));
        assert_eq!(Mode::parse(" Window "), Some(Mode::Window));
        assert_eq!(Mode::parse(""), Some(Mode::Screen));
        assert_eq!(Mode::parse("everything"), None);
    }

    #[test]
    fn geometry_from_hyprctl() {
        let json = r#"{"address":"0x1","at":[12,48],"size":[1280,720],"class":"foot"}"#;
        assert_eq!(window_geometry(json).as_deref(), Some("12,48 1280x720"));
        assert_eq!(window_geometry(r#"{"at":[0,0],"size":[0,0]}"#), None);
        assert_eq!(window_geometry("{}"), None);
        assert_eq!(window_geometry("Invalid"), None);
    }

    #[test]
    fn target_never_overwrites() {
        let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let a = target_path(dir.path(), "2026-11-10_04-30-00");
        assert_eq!(
            a.file_name().and_then(|n| n.to_str()),
            Some("Screenshot-2026-11-10_04-30-00.png")
        );
        std::fs::write(&a, b"x").unwrap_or_else(|e| panic!("write: {e}"));
        let b = target_path(dir.path(), "2026-11-10_04-30-00");
        assert_eq!(
            b.file_name().and_then(|n| n.to_str()),
            Some("Screenshot-2026-11-10_04-30-00-2.png")
        );
    }

    #[test]
    fn finds_tools_on_path() {
        assert!(find_tool("sh").is_some());
        assert!(find_tool("lugh-no-such-tool-xyz").is_none());
    }
}
