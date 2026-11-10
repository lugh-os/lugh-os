//! A fast, forgiving parser for freedesktop `.desktop` files (Desktop Entry
//! Specification 1.5).
//!
//! Only the keys the shell uses are kept; everything else is skipped without
//! allocating. Malformed lines are ignored instead of failing the file, as
//! desktop environments do in practice. A file is rejected only when it has
//! no `[Desktop Entry]` group or no `Name`.

use std::io;
use std::path::{Path, PathBuf};

/// The user's message locale, used to pick `Name[xx_YY]` style keys.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Locale {
    lang: String,
    country: Option<String>,
    modifier: Option<String>,
}

impl Locale {
    /// Parses a POSIX locale name (`fr_FR.UTF-8@euro`). `C`, `POSIX` and empty
    /// strings give the untranslated locale.
    pub fn parse(name: &str) -> Self {
        let (rest, modifier) = match name.split_once('@') {
            Some((r, m)) if !m.is_empty() => (r, Some(m.to_owned())),
            Some((r, _)) => (r, None),
            None => (name, None),
        };
        let rest = rest.split_once('.').map_or(rest, |(r, _)| r);
        let (lang, country) = match rest.split_once('_') {
            Some((l, c)) if !c.is_empty() => (l, Some(c.to_owned())),
            Some((l, _)) => (l, None),
            None => (rest, None),
        };
        if lang.is_empty() || lang == "C" || lang == "POSIX" {
            return Self::default();
        }
        Self {
            lang: lang.to_owned(),
            country,
            modifier,
        }
    }

    /// The locale from `LC_ALL`, `LC_MESSAGES` or `LANG` (first non-empty).
    pub fn from_env() -> Self {
        ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .filter_map(|v| std::env::var(v).ok())
            .find(|v| !v.is_empty())
            .map(|v| Self::parse(&v))
            .unwrap_or_default()
    }

    /// The untranslated locale (only plain keys match).
    pub fn untranslated() -> Self {
        Self::default()
    }

    /// Match quality of a key's `[locale]` suffix: 0 is best
    /// (`lang_COUNTRY@MODIFIER`), 3 is `lang`; `None` when it does not apply.
    fn rank(&self, key_locale: &str) -> Option<u8> {
        if self.lang.is_empty() {
            return None;
        }
        let (rest, m) = match key_locale.split_once('@') {
            Some((r, m)) => (r, Some(m)),
            None => (key_locale, None),
        };
        let rest = rest.split_once('.').map_or(rest, |(r, _)| r);
        let (l, c) = match rest.split_once('_') {
            Some((l, c)) => (l, Some(c)),
            None => (rest, None),
        };
        if l != self.lang {
            return None;
        }
        if c.is_some() && c != self.country.as_deref() {
            return None;
        }
        if m.is_some() && m != self.modifier.as_deref() {
            return None;
        }
        Some(match (c.is_some(), m.is_some()) {
            (true, true) => 0,
            (true, false) => 1,
            (false, true) => 2,
            (false, false) => 3,
        })
    }
}

/// The `Type` key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryType {
    /// `Type=Application` (also assumed when `Type` is missing).
    Application,
    /// `Type=Link`.
    Link,
    /// `Type=Directory`.
    Directory,
    /// Anything else.
    Unknown,
}

/// A `[Desktop Action id]` group listed in `Actions=`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopAction {
    /// The action identifier (`new-window`).
    pub id: String,
    /// Localized `Name`.
    pub name: String,
    /// `Icon`, if any.
    pub icon: Option<String>,
    /// Raw `Exec` (field codes not expanded).
    pub exec: Option<String>,
}

/// A parsed desktop entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopEntry {
    /// App id: the desktop-file id without the `.desktop` suffix
    /// (`org.gnome.Nautilus`, `kde-dolphin` for `kde/dolphin.desktop`).
    pub id: String,
    /// The file this entry came from (empty when parsed from a string).
    pub path: PathBuf,
    /// `Type`.
    pub entry_type: EntryType,
    /// Localized `Name`.
    pub name: String,
    /// The plain `Name` when it differs from the localized one.
    pub untranslated_name: Option<String>,
    /// Localized `GenericName`.
    pub generic_name: Option<String>,
    /// Localized `Comment`.
    pub comment: Option<String>,
    /// Localized `Keywords`.
    pub keywords: Vec<String>,
    /// `Icon`: a theme icon name or an absolute path.
    pub icon: Option<String>,
    /// Raw `Exec` (field codes not expanded).
    pub exec: Option<String>,
    /// `TryExec`.
    pub try_exec: Option<String>,
    /// `Path` (working directory).
    pub working_dir: Option<String>,
    /// `Terminal`.
    pub terminal: bool,
    /// `NoDisplay`.
    pub no_display: bool,
    /// `Hidden` (the entry is deleted; it still shadows lower-precedence ones).
    pub hidden: bool,
    /// `OnlyShowIn`.
    pub only_show_in: Vec<String>,
    /// `NotShowIn`.
    pub not_show_in: Vec<String>,
    /// `DBusActivatable`.
    pub dbus_activatable: bool,
    /// `StartupWMClass`.
    pub startup_wm_class: Option<String>,
    /// `Categories`.
    pub categories: Vec<String>,
    /// `MimeType`.
    pub mime_types: Vec<String>,
    /// Actions listed in `Actions=` that have a group, in listed order.
    pub actions: Vec<DesktopAction>,
}

/// Why a desktop file was rejected.
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    /// No `[Desktop Entry]` group.
    #[error("no [Desktop Entry] group")]
    NoDesktopEntryGroup,
    /// `[Desktop Entry]` has no `Name`.
    #[error("[Desktop Entry] has no Name")]
    MissingName,
    /// The file could not be read.
    #[error("cannot read {}: {source}", path.display())]
    Io {
        /// File that failed.
        path: PathBuf,
        /// Underlying error.
        #[source]
        source: io::Error,
    },
}

/// A localized value being collected: the best-ranked candidate so far.
#[derive(Debug, Default)]
struct Loc<T> {
    value: Option<T>,
    rank: u8,
}

impl<T> Loc<T> {
    const PLAIN: u8 = 4;

    fn offer(&mut self, rank: u8, make: impl FnOnce() -> T) {
        if self.value.is_none() || rank < self.rank {
            self.value = Some(make());
            self.rank = rank;
        }
    }
}

#[derive(Debug, Default)]
struct RawAction {
    id: String,
    name: Loc<String>,
    icon: Option<String>,
    exec: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Section {
    None,
    Main,
    Action(usize),
    Other,
}

impl DesktopEntry {
    /// Parses desktop-file text. `id` is the app id (see [`DesktopEntry::id`]).
    pub fn parse(text: &str, id: &str, locale: &Locale) -> Result<Self, ParseError> {
        let mut section = Section::None;
        let mut seen_main = false;

        let mut name: Loc<String> = Loc::default();
        let mut plain_name: Option<String> = None;
        let mut generic: Loc<String> = Loc::default();
        let mut comment: Loc<String> = Loc::default();
        let mut keywords: Loc<Vec<String>> = Loc::default();
        let mut entry = Self::empty(id);
        let mut action_ids: Vec<String> = Vec::new();
        let mut raw_actions: Vec<RawAction> = Vec::new();

        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(group) = line.strip_prefix('[') {
                let group = group.strip_suffix(']').unwrap_or(group);
                section = if group == "Desktop Entry" {
                    if seen_main {
                        Section::Other // a second main group is ignored
                    } else {
                        seen_main = true;
                        Section::Main
                    }
                } else if let Some(aid) = group.strip_prefix("Desktop Action ") {
                    raw_actions.push(RawAction {
                        id: aid.trim().to_owned(),
                        ..RawAction::default()
                    });
                    Section::Action(raw_actions.len() - 1)
                } else {
                    Section::Other
                };
                continue;
            }
            if matches!(section, Section::None | Section::Other) {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key = key.trim_end();
            let value = value.trim_start();
            let (base, key_locale) = match key.split_once('[') {
                Some((b, rest)) => (b, Some(rest.strip_suffix(']').unwrap_or(rest))),
                None => (key, None),
            };
            let rank = match key_locale {
                None => Loc::<()>::PLAIN,
                Some(l) => match locale.rank(l) {
                    Some(r) => r,
                    None => continue, // another language
                },
            };

            if let Section::Action(i) = section {
                let a = &mut raw_actions[i];
                match base {
                    "Name" => a.name.offer(rank, || unescape(value)),
                    "Icon" if key_locale.is_none() => a.icon = non_empty(unescape(value)),
                    "Exec" if key_locale.is_none() => a.exec = non_empty(unescape(value)),
                    _ => {}
                }
                continue;
            }

            match base {
                "Name" => {
                    if key_locale.is_none() && plain_name.is_none() {
                        plain_name = Some(unescape(value));
                    }
                    name.offer(rank, || unescape(value));
                }
                "GenericName" => generic.offer(rank, || unescape(value)),
                "Comment" => comment.offer(rank, || unescape(value)),
                "Keywords" => keywords.offer(rank, || split_list(value)),
                _ if key_locale.is_some() => {}
                "Type" => {
                    entry.entry_type = match value {
                        "Application" => EntryType::Application,
                        "Link" => EntryType::Link,
                        "Directory" => EntryType::Directory,
                        _ => EntryType::Unknown,
                    }
                }
                "Icon" => set_once(&mut entry.icon, value),
                "Exec" => set_once(&mut entry.exec, value),
                "TryExec" => set_once(&mut entry.try_exec, value),
                "Path" => set_once(&mut entry.working_dir, value),
                "StartupWMClass" => set_once(&mut entry.startup_wm_class, value),
                "Terminal" => entry.terminal = parse_bool(value),
                "NoDisplay" => entry.no_display = parse_bool(value),
                "Hidden" => entry.hidden = parse_bool(value),
                "DBusActivatable" => entry.dbus_activatable = parse_bool(value),
                "OnlyShowIn" => entry.only_show_in = split_list(value),
                "NotShowIn" => entry.not_show_in = split_list(value),
                "Categories" => entry.categories = split_list(value),
                "MimeType" => entry.mime_types = split_list(value),
                "Actions" => action_ids = split_list(value),
                _ => {}
            }
        }

        if !seen_main {
            return Err(ParseError::NoDesktopEntryGroup);
        }
        entry.name = name
            .value
            .filter(|n| !n.is_empty())
            .ok_or(ParseError::MissingName)?;
        entry.untranslated_name = plain_name.filter(|p| *p != entry.name && !p.is_empty());
        entry.generic_name = generic.value.filter(|g| !g.is_empty());
        entry.comment = comment.value.filter(|c| !c.is_empty());
        entry.keywords = keywords.value.unwrap_or_default();
        entry.actions = action_ids
            .iter()
            .filter_map(|aid| {
                let pos = raw_actions.iter().position(|a| a.id == *aid)?;
                let a = raw_actions.swap_remove(pos);
                Some(DesktopAction {
                    id: a.id,
                    name: a.name.value?,
                    icon: a.icon,
                    exec: a.exec,
                })
            })
            .collect();
        Ok(entry)
    }

    /// Reads and parses a desktop file.
    pub fn parse_file(path: &Path, id: &str, locale: &Locale) -> Result<Self, ParseError> {
        let text = std::fs::read_to_string(path).map_err(|source| ParseError::Io {
            path: path.to_owned(),
            source,
        })?;
        let mut entry = Self::parse(&text, id, locale)?;
        entry.path = path.to_owned();
        Ok(entry)
    }

    fn empty(id: &str) -> Self {
        Self {
            id: id.to_owned(),
            path: PathBuf::new(),
            entry_type: EntryType::Application,
            name: String::new(),
            untranslated_name: None,
            generic_name: None,
            comment: None,
            keywords: Vec::new(),
            icon: None,
            exec: None,
            try_exec: None,
            working_dir: None,
            terminal: false,
            no_display: false,
            hidden: false,
            only_show_in: Vec::new(),
            not_show_in: Vec::new(),
            dbus_activatable: false,
            startup_wm_class: None,
            categories: Vec::new(),
            mime_types: Vec::new(),
            actions: Vec::new(),
        }
    }

    /// Whether the launcher should list this entry in a session whose desktop
    /// names are `desktops` (`["Lugh", …]` from `XDG_CURRENT_DESKTOP`).
    /// Does not check `TryExec` (see [`DesktopEntry::try_exec_ok`]).
    pub fn should_show(&self, desktops: &[String]) -> bool {
        let in_session = |list: &[String]| {
            list.iter()
                .any(|d| desktops.iter().any(|s| s.eq_ignore_ascii_case(d)))
        };
        !self.hidden
            && !self.no_display
            && self.entry_type == EntryType::Application
            && (self.exec.is_some() || self.dbus_activatable)
            && (self.only_show_in.is_empty() || in_session(&self.only_show_in))
            && !in_session(&self.not_show_in)
    }

    /// False when `TryExec` names a program that is not installed: an
    /// absolute path that is not an executable file, or a name found in none
    /// of `path_dirs`.
    pub fn try_exec_ok(&self, path_dirs: &[PathBuf]) -> bool {
        let Some(prog) = self.try_exec.as_deref() else {
            return true;
        };
        let p = Path::new(prog);
        if p.is_absolute() {
            return is_executable(p);
        }
        path_dirs.iter().any(|d| is_executable(&d.join(p)))
    }

    /// The program an `Exec` line runs, as a bare name: skips `env` and its
    /// assignments, and resolves `flatpak run` to `--command=` or the app id.
    pub fn exec_program(&self) -> Option<&str> {
        exec_program(self.exec.as_deref()?)
    }
}

fn exec_program(exec: &str) -> Option<&str> {
    let mut tokens = ExecTokens(exec);
    let mut prog = tokens.next()?;
    if base(prog) == "env" {
        prog = tokens
            .by_ref()
            .find(|t| !t.contains('=') && !t.starts_with('-'))?;
    }
    if base(prog) == "flatpak" {
        let mut app = None;
        for t in tokens {
            if let Some(cmd) = t.strip_prefix("--command=") {
                return Some(base(cmd));
            }
            if t != "run" && !t.starts_with('-') && !t.starts_with('@') && app.is_none() {
                app = Some(t);
            }
        }
        return app.map(|a| a.rsplit('.').next().unwrap_or(a));
    }
    Some(base(prog)).filter(|p| !p.is_empty())
}

/// Splits an `Exec` value into arguments: whitespace-separated, with
/// double-quoted arguments kept whole (quotes removed, inner escapes kept).
struct ExecTokens<'a>(&'a str);

impl<'a> Iterator for ExecTokens<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        let s = self.0.trim_start();
        if s.is_empty() {
            self.0 = s;
            return None;
        }
        if let Some(rest) = s.strip_prefix('"') {
            let end = rest.find('"').unwrap_or(rest.len());
            self.0 = rest.get(end + 1..).unwrap_or("");
            return Some(&rest[..end]);
        }
        let end = s.find(|c: char| c.is_ascii_whitespace()).unwrap_or(s.len());
        self.0 = &s[end..];
        Some(&s[..end])
    }
}

fn base(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or(s)
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn set_once(slot: &mut Option<String>, value: &str) {
    if slot.is_none() {
        *slot = non_empty(unescape(value));
    }
}

fn non_empty(s: String) -> Option<String> {
    Some(s).filter(|s| !s.is_empty())
}

fn parse_bool(v: &str) -> bool {
    matches!(v.trim(), "true" | "1")
}

/// Expands `\s \n \t \r \\` (and `\;`). Unknown escapes keep the character.
fn unescape(v: &str) -> String {
    let v = v.trim_end();
    if !v.contains('\\') {
        return v.to_owned();
    }
    let mut out = String::with_capacity(v.len());
    let mut chars = v.chars();
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

/// Splits a `;`-separated list (`\;` is a literal semicolon), unescaping each
/// element and dropping empty ones.
fn split_list(v: &str) -> Vec<String> {
    let v = v.trim_end();
    let mut items = Vec::new();
    let mut start = 0;
    let bytes = v.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b';' => {
                push_item(&mut items, &v[start..i]);
                i += 1;
                start = i;
            }
            _ => i += 1,
        }
    }
    if start < v.len() {
        push_item(&mut items, &v[start..]);
    }
    items
}

fn push_item(items: &mut Vec<String>, raw: &str) {
    let s = unescape(raw.trim());
    if !s.is_empty() {
        items.push(s);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIREFOX: &str = "\
# comment
[Desktop Entry]
Version=1.5
Type=Application
Name=Firefox
Name[fr]=Firefox (fr)
Name[fr_FR]=Firefox France
Name[de]=Feuerfuchs
GenericName=Web Browser
GenericName[fr]=Navigateur Web
Comment=Browse the Web
Keywords=Internet;WWW;Browser;Web;Explorer;
Keywords[fr]=Internet;Navigateur;
Exec=/usr/lib/firefox/firefox %u
TryExec=firefox
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;
StartupWMClass=firefox
Actions=new-window;new-private-window;missing;

[Desktop Action new-private-window]
Name=New Private Window
Name[fr]=Nouvelle fenêtre privée
Exec=/usr/lib/firefox/firefox --private-window %u

[Desktop Action new-window]
Name=New Window
Exec=/usr/lib/firefox/firefox --new-window %u

[Desktop Action unlisted]
Name=Unlisted
";

    #[test]
    fn parses_core_keys() {
        let e = DesktopEntry::parse(FIREFOX, "firefox", &Locale::untranslated()).unwrap();
        assert_eq!(e.id, "firefox");
        assert_eq!(e.entry_type, EntryType::Application);
        assert_eq!(e.name, "Firefox");
        assert_eq!(e.untranslated_name, None);
        assert_eq!(e.generic_name.as_deref(), Some("Web Browser"));
        assert_eq!(e.comment.as_deref(), Some("Browse the Web"));
        assert_eq!(
            e.keywords,
            ["Internet", "WWW", "Browser", "Web", "Explorer"]
        );
        assert_eq!(e.exec.as_deref(), Some("/usr/lib/firefox/firefox %u"));
        assert_eq!(e.exec_program(), Some("firefox"));
        assert_eq!(e.try_exec.as_deref(), Some("firefox"));
        assert_eq!(e.icon.as_deref(), Some("firefox"));
        assert!(!e.terminal);
        assert_eq!(e.categories, ["Network", "WebBrowser"]);
        assert_eq!(e.mime_types.len(), 2);
        assert_eq!(e.startup_wm_class.as_deref(), Some("firefox"));
    }

    #[test]
    fn actions_follow_actions_key_order() {
        let e = DesktopEntry::parse(FIREFOX, "firefox", &Locale::untranslated()).unwrap();
        let ids: Vec<_> = e.actions.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["new-window", "new-private-window"]);
        assert_eq!(e.actions[1].name, "New Private Window");
        assert_eq!(
            e.actions[1].exec.as_deref(),
            Some("/usr/lib/firefox/firefox --private-window %u")
        );
    }

    #[test]
    fn locale_fallback_chain() {
        let fr_fr = DesktopEntry::parse(FIREFOX, "f", &Locale::parse("fr_FR.UTF-8")).unwrap();
        assert_eq!(fr_fr.name, "Firefox France");
        assert_eq!(fr_fr.untranslated_name.as_deref(), Some("Firefox"));
        assert_eq!(fr_fr.generic_name.as_deref(), Some("Navigateur Web"));
        assert_eq!(fr_fr.keywords, ["Internet", "Navigateur"]);
        assert_eq!(fr_fr.comment.as_deref(), Some("Browse the Web"));
        assert_eq!(fr_fr.actions[1].name, "Nouvelle fenêtre privée");

        let fr_be = DesktopEntry::parse(FIREFOX, "f", &Locale::parse("fr_BE")).unwrap();
        assert_eq!(fr_be.name, "Firefox (fr)");

        let de = DesktopEntry::parse(FIREFOX, "f", &Locale::parse("de_DE@euro")).unwrap();
        assert_eq!(de.name, "Feuerfuchs");

        let rw = DesktopEntry::parse(FIREFOX, "f", &Locale::parse("rw_RW")).unwrap();
        assert_eq!(rw.name, "Firefox");
    }

    #[test]
    fn locale_modifier_ranking() {
        let text = "[Desktop Entry]\nName=A\nName[sr@latin]=B\nName[sr_RS]=C\nName[sr]=D\n";
        let l = Locale::parse("sr_RS@latin");
        assert_eq!(DesktopEntry::parse(text, "x", &l).unwrap().name, "C");
        let text2 = "[Desktop Entry]\nName=A\nName[sr@latin]=B\nName[sr]=D\n";
        assert_eq!(DesktopEntry::parse(text2, "x", &l).unwrap().name, "B");
        assert_eq!(
            DesktopEntry::parse(text2, "x", &Locale::parse("sr"))
                .unwrap()
                .name,
            "D"
        );
        assert_eq!(Locale::parse("C"), Locale::untranslated());
        assert_eq!(Locale::parse("POSIX.UTF-8"), Locale::untranslated());
    }

    #[test]
    fn escapes_and_lists() {
        let text = "[Desktop Entry]\nName=Tab\\tName\\sX\\\\Y\nComment=Line1\\nLine2\nKeywords=a\\;b;c ; ;d\\\\;\nExec=foo\n";
        let e = DesktopEntry::parse(text, "x", &Locale::untranslated()).unwrap();
        assert_eq!(e.name, "Tab\tName X\\Y");
        assert_eq!(e.comment.as_deref(), Some("Line1\nLine2"));
        assert_eq!(e.keywords, ["a;b", "c", "d\\"]);
        assert_eq!(split_list("one"), ["one"]);
        assert!(split_list("").is_empty());
        assert_eq!(unescape("trailing\\"), "trailing\\");
    }

    #[test]
    fn forgiving_about_whitespace_and_junk() {
        let text = "\n  [Desktop Entry]\nName = Spaced \njunk line without equals\nNoDisplay=true\nExec=x\n[Other Group]\nName=Ignored\n";
        let e = DesktopEntry::parse(text, "x", &Locale::untranslated()).unwrap();
        assert_eq!(e.name, "Spaced");
        assert!(e.no_display);
    }

    #[test]
    fn duplicate_keys_keep_first() {
        let text = "[Desktop Entry]\nName=First\nName=Second\nIcon=a\nIcon=b\nExec=x\n";
        let e = DesktopEntry::parse(text, "x", &Locale::untranslated()).unwrap();
        assert_eq!(e.name, "First");
        assert_eq!(e.icon.as_deref(), Some("a"));
    }

    #[test]
    fn rejects_missing_group_or_name() {
        assert!(matches!(
            DesktopEntry::parse("Name=x\n", "x", &Locale::untranslated()),
            Err(ParseError::NoDesktopEntryGroup)
        ));
        assert!(matches!(
            DesktopEntry::parse("[Desktop Entry]\nExec=x\n", "x", &Locale::untranslated()),
            Err(ParseError::MissingName)
        ));
        assert!(matches!(
            DesktopEntry::parse("[Desktop Entry]\nName=\n", "x", &Locale::untranslated()),
            Err(ParseError::MissingName)
        ));
    }

    #[test]
    fn visibility_rules() {
        let base = "[Desktop Entry]\nName=A\nExec=a\n";
        let desk = vec!["Lugh".to_owned(), "Hyprland".to_owned()];
        let parse = |extra: &str| {
            DesktopEntry::parse(&format!("{base}{extra}"), "a", &Locale::untranslated()).unwrap()
        };
        assert!(parse("").should_show(&desk));
        assert!(!parse("Hidden=true\n").should_show(&desk));
        assert!(!parse("NoDisplay=true\n").should_show(&desk));
        assert!(!parse("Type=Link\n").should_show(&desk));
        assert!(parse("OnlyShowIn=GNOME;Lugh;\n").should_show(&desk));
        assert!(!parse("OnlyShowIn=GNOME;KDE;\n").should_show(&desk));
        assert!(!parse("NotShowIn=hyprland;\n").should_show(&desk));
        assert!(parse("NotShowIn=KDE;\n").should_show(&desk));
        let no_exec =
            DesktopEntry::parse("[Desktop Entry]\nName=A\n", "a", &Locale::untranslated()).unwrap();
        assert!(!no_exec.should_show(&desk));
        assert!(parse("DBusActivatable=true\n").dbus_activatable);
    }

    #[test]
    fn try_exec_checks_path() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("realprog");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let dirs = vec![dir.path().to_owned()];
        let mk = |t: &str| {
            DesktopEntry::parse(
                &format!("[Desktop Entry]\nName=A\nExec=a\nTryExec={t}\n"),
                "a",
                &Locale::untranslated(),
            )
            .unwrap()
        };
        assert!(mk("realprog").try_exec_ok(&dirs));
        assert!(!mk("nosuchprog-lugh").try_exec_ok(&dirs));
        assert!(mk(bin.to_str().unwrap()).try_exec_ok(&[]));
        assert!(!mk("/nonexistent/lugh/prog").try_exec_ok(&dirs));
    }

    #[test]
    fn exec_program_variants() {
        assert_eq!(exec_program("gimp-2.10 %U"), Some("gimp-2.10"));
        assert_eq!(
            exec_program("env FOO=1 BAR=2 /usr/bin/code --new"),
            Some("code")
        );
        assert_eq!(
            exec_program(
                "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=obs com.obsproject.Studio"
            ),
            Some("obs")
        );
        assert_eq!(
            exec_program("/usr/bin/flatpak run --branch=stable org.gnome.Maps"),
            Some("Maps")
        );
        assert_eq!(exec_program("\"/opt/My App/bin\""), Some("bin"));
        assert_eq!(exec_program(""), None);
    }
}
