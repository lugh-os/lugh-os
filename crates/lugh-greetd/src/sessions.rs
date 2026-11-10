//! Wayland sessions from `/usr/share/wayland-sessions/*.desktop`.

use std::fs;
use std::path::Path;

use serde::Serialize;

/// Session id that always sorts first.
pub const DEFAULT_SESSION: &str = "lugh";

/// One installed session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    /// File name without `.desktop`.
    pub id: String,
    /// `Name=`.
    pub name: String,
    /// `Comment=`, may be empty.
    pub comment: String,
    /// `Exec=`, the command handed to greetd.
    pub exec: String,
    /// `DesktopNames=`, for `XDG_CURRENT_DESKTOP`.
    #[serde(skip)]
    pub desktop_names: Vec<String>,
}

fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

/// Parses the text of a session `.desktop` file. `None` when it is hidden,
/// not an application entry, or has no `Name`/`Exec`.
#[must_use]
pub fn parse_session(id: &str, text: &str) -> Option<Session> {
    let (mut name, mut comment, mut exec, mut names) = (None, String::new(), None, Vec::new());
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key.trim() {
            "Name" => name = Some(unescape(value)),
            "Comment" => comment = unescape(value),
            "Exec" => exec = Some(unescape(value)),
            "DesktopNames" => {
                names = value
                    .split(';')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect();
            }
            "Hidden" | "NoDisplay" if value == "true" => return None,
            "Type" if value != "Application" => return None,
            _ => {}
        }
    }
    let (name, exec) = (name?, exec?);
    if id.is_empty() || name.is_empty() || split_exec(&exec).is_empty() {
        return None;
    }
    Some(Session {
        id: id.to_owned(),
        name,
        comment,
        exec,
        desktop_names: names,
    })
}

/// Orders sessions: [`DEFAULT_SESSION`] first, then by name.
pub fn sort_sessions(sessions: &mut [Session]) {
    sessions.sort_by(|a, b| {
        (a.id != DEFAULT_SESSION)
            .cmp(&(b.id != DEFAULT_SESSION))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.id.cmp(&b.id))
    });
}

/// Loads every session in `dir`. A missing directory gives an empty list.
#[must_use]
pub fn load(dir: &Path) -> Vec<Session> {
    let mut sessions: Vec<Session> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension()? != "desktop" {
                return None;
            }
            let id = path.file_stem()?.to_str()?.to_owned();
            parse_session(&id, &fs::read_to_string(&path).ok()?)
        })
        .collect();
    sort_sessions(&mut sessions);
    sessions
}

/// Splits an `Exec=` line into arguments, shell style (quotes, backslashes),
/// dropping desktop-entry field codes such as `%U`. `%%` becomes `%`.
#[must_use]
pub fn split_exec(exec: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut started = false;
    let mut quote: Option<char> = None;
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (None, c) if c.is_whitespace() => {
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            (None, '\'' | '"') => {
                quote = Some(c);
                started = true;
            }
            (Some(q), c) if c == q => quote = None,
            (None | Some('"'), '\\') => {
                if let Some(next) = chars.next() {
                    current.push(next);
                    started = true;
                }
            }
            (None, '%') => {
                if chars.next() == Some('%') {
                    current.push('%');
                    started = true;
                }
            }
            (_, c) => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        args.push(current);
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    const LUGH: &str = "\
[Desktop Entry]
Name=Lugh
Name[fr]=Lugh (fr)
Comment=The Lugh desktop
Exec=lugh-session
Type=Application
DesktopNames=Lugh;Hyprland;

[Other Group]
Name=Wrong
Exec=wrong
";

    #[test]
    fn parses_an_entry() {
        let session = parse_session("lugh", LUGH).unwrap();
        assert_eq!(session.name, "Lugh");
        assert_eq!(session.comment, "The Lugh desktop");
        assert_eq!(session.exec, "lugh-session");
        assert_eq!(session.desktop_names, ["Lugh", "Hyprland"]);
        let json = serde_json::to_string(&session).unwrap();
        assert_eq!(
            json,
            r#"{"id":"lugh","name":"Lugh","comment":"The Lugh desktop","exec":"lugh-session"}"#
        );
    }

    #[test]
    fn skips_hidden_and_incomplete() {
        assert!(parse_session("a", "[Desktop Entry]\nName=A\nExec=a\nHidden=true\n").is_none());
        assert!(parse_session("a", "[Desktop Entry]\nName=A\nExec=a\nNoDisplay=true\n").is_none());
        assert!(parse_session("a", "[Desktop Entry]\nName=A\n").is_none());
        assert!(parse_session("a", "[Desktop Entry]\nExec=a\n").is_none());
        assert!(parse_session("a", "[Desktop Entry]\nName=A\nExec=  \n").is_none());
        assert!(parse_session("a", "Name=A\nExec=a\n").is_none());
        assert!(parse_session("a", "\0\u{1}garbage[[[==\n=\n").is_none());
        assert!(parse_session("a", "[Desktop Entry]\nName=A\nExec=a\nNoDisplay=false\n").is_some());
    }

    #[test]
    fn lugh_sorts_first() {
        let dir = tempfile::tempdir().unwrap();
        let entry = |name: &str| format!("[Desktop Entry]\nName={name}\nExec={name}-bin\n");
        fs::write(dir.path().join("hyprland.desktop"), entry("Hyprland")).unwrap();
        fs::write(dir.path().join("lugh.desktop"), entry("Lugh")).unwrap();
        fs::write(dir.path().join("cosmic.desktop"), entry("COSMIC")).unwrap();
        fs::write(dir.path().join("notes.txt"), entry("Nope")).unwrap();
        let ids: Vec<String> = load(dir.path()).into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["lugh", "cosmic", "hyprland"]);
        assert!(load(Path::new("/nonexistent/lugh-greetd")).is_empty());
    }

    #[test]
    fn exec_splitting() {
        assert_eq!(split_exec("lugh-session"), ["lugh-session"]);
        assert_eq!(
            split_exec("  env A=b  'my session' --flag=\"x y\" %U a\\ b 100%% "),
            ["env", "A=b", "my session", "--flag=x y", "a b", "100%"]
        );
        assert_eq!(split_exec("sh -c ''"), ["sh", "-c", ""]);
        assert!(split_exec("   ").is_empty());
        assert_eq!(
            split_exec("unterminated 'quote here"),
            ["unterminated", "quote here"]
        );
    }
}
