//! The installed-apps index: desktop entries from the XDG data directories,
//! with desktop-file ids, first-wins shadowing and visibility filtering, plus
//! the precomputed match haystacks the search uses.

use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use nucleo_matcher::Utf32String;

use super::desktop_entry::{DesktopEntry, Locale, ParseError};
use super::fold;

/// Desktop name Lugh adds to `XDG_CURRENT_DESKTOP` for `OnlyShowIn`/`NotShowIn`.
const DESKTOP_NAME: &str = "Lugh";

/// Installed applications, in a stable order (by folded name, then id).
#[derive(Debug)]
pub struct AppIndex {
    dirs: Vec<PathBuf>,
    desktops: Vec<String>,
    locale: Locale,
    path_dirs: Vec<PathBuf>,
    entries: Vec<DesktopEntry>,
    hay: Vec<Haystack>,
    by_id: HashMap<String, usize>,
    stamps: Vec<(PathBuf, Option<SystemTime>)>,
    generation: u64,
}

/// Which part of an entry a haystack field comes from. The order is the
/// search weight order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FieldKind {
    Name,
    UntranslatedName,
    GenericName,
    Keywords,
    Exec,
}

impl FieldKind {
    /// Weight of a fuzzy match in this field, in tenths.
    pub(crate) const fn weight(self) -> u32 {
        match self {
            Self::Name => 10,
            Self::UntranslatedName => 9,
            Self::GenericName => 7,
            Self::Keywords | Self::Exec => 6,
        }
    }

    pub(crate) const fn is_name(self) -> bool {
        matches!(self, Self::Name | Self::UntranslatedName)
    }
}

/// One searchable string of an entry, prepared once at index time.
#[derive(Debug)]
pub(crate) struct Field {
    pub(crate) kind: FieldKind,
    /// Original text for nucleo (it folds case itself and keeps camelCase
    /// boundaries for its bonuses).
    pub(crate) text: Utf32String,
    /// Folded text for exact/prefix/word-start checks.
    pub(crate) fold: Box<str>,
    /// [`char_mask`] of `fold`.
    pub(crate) mask: u64,
}

/// All searchable fields of one entry.
#[derive(Debug)]
pub(crate) struct Haystack {
    pub(crate) fields: Vec<Field>,
    /// Union of the field masks.
    pub(crate) mask: u64,
}

impl Haystack {
    fn new(e: &DesktopEntry) -> Self {
        let mut fields = Vec::with_capacity(5);
        let mut push = |kind, text: &str| {
            let f = fold(text);
            if f.is_empty() {
                return;
            }
            fields.push(Field {
                kind,
                text: Utf32String::from(text),
                mask: char_mask(&f),
                fold: f.into_boxed_str(),
            });
        };
        push(FieldKind::Name, &e.name);
        if let Some(n) = &e.untranslated_name {
            push(FieldKind::UntranslatedName, n);
        }
        if let Some(g) = &e.generic_name {
            push(FieldKind::GenericName, g);
        }
        if !e.keywords.is_empty() {
            push(FieldKind::Keywords, &e.keywords.join(" "));
        }
        if let Some(p) = e.exec_program() {
            push(FieldKind::Exec, p);
        }
        let mask = fields.iter().fold(0, |m, f| m | f.mask);
        Self { fields, mask }
    }
}

/// A 64-bit set of the characters in a folded string, for rejecting entries
/// that cannot contain a query before running the matcher. Letters and digits
/// get a bit each, other ASCII shares 27 bits, all non-ASCII shares one.
/// Spaces are ignored.
pub(crate) fn char_mask(folded: &str) -> u64 {
    let mut m = 0u64;
    for b in folded.bytes() {
        m |= match b {
            b'a'..=b'z' => 1 << (b - b'a'),
            b'0'..=b'9' => 1 << (26 + b - b'0'),
            b' ' => 0,
            0..=0x7f => 1 << (36 + b % 27),
            _ => 1 << 63,
        };
    }
    m
}

impl AppIndex {
    /// Scans `dirs` (each an `…/applications` directory, highest precedence
    /// first). `desktops` are the session's desktop names for
    /// `OnlyShowIn`/`NotShowIn`; `TryExec` is resolved against `$PATH`.
    pub fn new(dirs: Vec<PathBuf>, locale: Locale, desktops: Vec<String>) -> Self {
        let path_dirs = std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).collect())
            .unwrap_or_default();
        let mut index = Self {
            dirs,
            desktops,
            locale,
            path_dirs,
            entries: Vec::new(),
            hay: Vec::new(),
            by_id: HashMap::new(),
            stamps: Vec::new(),
            generation: 0,
        };
        index.scan();
        index
    }

    /// The session index: [`AppIndex::data_dirs_from_env`], the locale from
    /// `LC_ALL`/`LC_MESSAGES`/`LANG`, and the desktop names from
    /// `XDG_CURRENT_DESKTOP` plus `Lugh`.
    pub fn from_env() -> Self {
        Self::new(
            Self::data_dirs_from_env(),
            Locale::from_env(),
            desktops_from(std::env::var("XDG_CURRENT_DESKTOP").ok().as_deref()),
        )
    }

    /// An index over ready-made entries (synthetic data, tests). Duplicate
    /// ids keep the first; no visibility filtering is applied.
    pub fn from_entries(entries: Vec<DesktopEntry>) -> Self {
        let mut index = Self {
            dirs: Vec::new(),
            desktops: vec![DESKTOP_NAME.to_owned()],
            locale: Locale::untranslated(),
            path_dirs: Vec::new(),
            entries: Vec::new(),
            hay: Vec::new(),
            by_id: HashMap::new(),
            stamps: Vec::new(),
            generation: 0,
        };
        let mut seen = HashSet::new();
        let entries = entries
            .into_iter()
            .filter(|e| seen.insert(e.id.clone()))
            .collect();
        index.install(entries);
        index
    }

    /// The `applications` directories in XDG precedence order:
    /// `$XDG_DATA_HOME` (default `~/.local/share`), then each of
    /// `$XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`), then the
    /// Flatpak export dirs (user, system) if `XDG_DATA_DIRS` lacks them.
    pub fn data_dirs_from_env() -> Vec<PathBuf> {
        data_dirs(
            std::env::var_os("XDG_DATA_HOME"),
            std::env::var_os("XDG_DATA_DIRS"),
            std::env::var_os("HOME"),
        )
    }

    /// All visible entries.
    pub fn entries(&self) -> &[DesktopEntry] {
        &self.entries
    }

    /// The entry with this app id (`firefox`; a `.desktop` suffix is accepted).
    pub fn get(&self, id: &str) -> Option<&DesktopEntry> {
        self.position(id).map(|i| &self.entries[i])
    }

    /// Number of visible entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when no app is installed (or no dir was readable).
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The scanned directories, highest precedence first.
    pub fn dirs(&self) -> &[PathBuf] {
        &self.dirs
    }

    /// Bumped every time the entries change.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Re-scans when any scanned directory (or subdirectory) appeared,
    /// disappeared or changed its modification time, which covers package
    /// installs, removals and atomic replacements. Returns whether the index
    /// changed. Cheap when nothing changed (one `stat` per directory); call it
    /// when the launcher opens, or from a file-watcher in the shell.
    pub fn rescan(&mut self) -> bool {
        let fresh = self.stamps.iter().all(|(dir, stamp)| mtime(dir) == *stamp);
        if fresh && !self.stamps.is_empty() {
            return false;
        }
        if self.dirs.is_empty() {
            return false;
        }
        self.scan();
        true
    }

    pub(crate) fn position(&self, id: &str) -> Option<usize> {
        let id = id.strip_suffix(".desktop").unwrap_or(id);
        self.by_id.get(id).copied()
    }

    pub(crate) fn haystacks(&self) -> &[Haystack] {
        &self.hay
    }

    fn scan(&mut self) {
        let mut stamps = Vec::new();
        let mut files = Vec::new();
        for dir in &self.dirs {
            let start = files.len();
            collect_desktop_files(dir, dir, &mut files, &mut stamps);
            files[start..].sort_unstable();
        }
        let parsed = parse_all(&files, &self.locale);
        let mut seen: HashSet<&str> = HashSet::with_capacity(files.len());
        let mut entries = Vec::with_capacity(files.len());
        for ((id, path), result) in files.iter().zip(parsed) {
            if seen.contains(id.as_str()) {
                continue; // shadowed by a higher-precedence dir
            }
            match result {
                Ok(e) => {
                    seen.insert(id);
                    if e.should_show(&self.desktops) && e.try_exec_ok(&self.path_dirs) {
                        entries.push(e);
                    }
                }
                // A broken file does not shadow lower-precedence ones.
                Err(err) => tracing::debug!(path = %path.display(), %err, "skipping desktop file"),
            }
        }
        self.stamps = stamps;
        self.install(entries);
    }

    fn install(&mut self, mut entries: Vec<DesktopEntry>) {
        let mut keyed: Vec<(String, DesktopEntry)> =
            entries.drain(..).map(|e| (fold(&e.name), e)).collect();
        keyed.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
        self.entries = keyed.into_iter().map(|(_, e)| e).collect();
        self.hay = self.entries.iter().map(Haystack::new).collect();
        self.by_id = self
            .entries
            .iter()
            .enumerate()
            .map(|(i, e)| (e.id.clone(), i))
            .collect();
        self.generation += 1;
    }
}

/// Session desktop names: `XDG_CURRENT_DESKTOP` (colon-separated) plus `Lugh`.
fn desktops_from(current: Option<&str>) -> Vec<String> {
    let mut v: Vec<String> = current
        .unwrap_or("")
        .split(':')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if !v.iter().any(|d| d.eq_ignore_ascii_case(DESKTOP_NAME)) {
        v.push(DESKTOP_NAME.to_owned());
    }
    v
}

fn data_dirs(
    data_home: Option<OsString>,
    data_dirs: Option<OsString>,
    home: Option<OsString>,
) -> Vec<PathBuf> {
    let absolute = |p: PathBuf| p.is_absolute().then_some(p);
    let home = home.map(PathBuf::from).and_then(absolute);
    let mut bases: Vec<PathBuf> = Vec::new();
    if let Some(h) = data_home
        .map(PathBuf::from)
        .and_then(absolute)
        .or_else(|| home.as_ref().map(|h| h.join(".local/share")))
    {
        bases.push(h);
    }
    let system: Vec<PathBuf> = data_dirs
        .filter(|d| !d.is_empty())
        .map(|d| std::env::split_paths(&d).filter_map(absolute).collect())
        .unwrap_or_else(|| vec!["/usr/local/share".into(), "/usr/share".into()]);
    bases.extend(system);
    if let Some(h) = &home {
        bases.push(h.join(".local/share/flatpak/exports/share"));
    }
    bases.push("/var/lib/flatpak/exports/share".into());

    let mut seen = HashSet::new();
    bases
        .into_iter()
        .map(|b| b.join("applications"))
        .filter(|d| seen.insert(d.clone()))
        .collect()
}

/// Parses `files` in order, on several threads when there are many (reading
/// and parsing is I/O- and allocation-bound and fully independent per file).
fn parse_all(
    files: &[(String, PathBuf)],
    locale: &Locale,
) -> Vec<Result<DesktopEntry, ParseError>> {
    let parse = |(id, path): &(String, PathBuf)| DesktopEntry::parse_file(path, id, locale);
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get().min(8));
    if files.len() < 256 || threads < 2 {
        return files.iter().map(parse).collect();
    }
    let chunk = files.len().div_ceil(threads);
    std::thread::scope(|s| {
        let handles: Vec<_> = files
            .chunks(chunk)
            .map(|c| s.spawn(move || c.iter().map(parse).collect::<Vec<_>>()))
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect()
    })
}

fn mtime(dir: &Path) -> Option<SystemTime> {
    std::fs::metadata(dir).and_then(|m| m.modified()).ok()
}

/// Walks `dir` recursively, collecting `(desktop-file id, path)` and each
/// directory's mtime stamp (missing dirs are stamped `None`).
fn collect_desktop_files(
    root: &Path,
    dir: &Path,
    out: &mut Vec<(String, PathBuf)>,
    stamps: &mut Vec<(PathBuf, Option<SystemTime>)>,
) {
    stamps.push((dir.to_owned(), mtime(dir)));
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for ent in rd.flatten() {
        let path = ent.path();
        let is_dir = match ent.file_type() {
            Ok(t) if t.is_symlink() => path.is_dir(),
            Ok(t) => t.is_dir(),
            Err(_) => continue,
        };
        if is_dir {
            collect_desktop_files(root, &path, out, stamps);
            continue;
        }
        let Some(rel) = path.strip_prefix(root).ok().and_then(Path::to_str) else {
            continue;
        };
        if let Some(stem) = rel.strip_suffix(".desktop") {
            out.push((stem.replace('/', "-"), path.clone()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write(dir: &Path, rel: &str, body: &str) {
        let p = dir.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }

    fn app(name: &str) -> String {
        format!("[Desktop Entry]\nType=Application\nName={name}\nExec={name}\n")
    }

    fn index(dirs: &[&Path]) -> AppIndex {
        AppIndex::new(
            dirs.iter().map(|d| d.to_path_buf()).collect(),
            Locale::untranslated(),
            vec!["Lugh".into()],
        )
    }

    #[test]
    fn ids_from_subdirs_and_shadowing() {
        let user = tempfile::tempdir().unwrap();
        let sys = tempfile::tempdir().unwrap();
        write(sys.path(), "firefox.desktop", &app("Firefox"));
        write(sys.path(), "kde/dolphin.desktop", &app("Dolphin"));
        write(sys.path(), "gone.desktop", &app("Gone"));
        write(sys.path(), "readme.txt", "not a desktop file");
        write(user.path(), "firefox.desktop", &app("My Firefox"));
        write(
            user.path(),
            "gone.desktop",
            "[Desktop Entry]\nName=Gone\nHidden=true\n",
        );

        let idx = index(&[user.path(), sys.path()]);
        let ids: Vec<_> = idx.entries().iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, ["kde-dolphin", "firefox"]);
        assert_eq!(idx.get("firefox").unwrap().name, "My Firefox");
        assert_eq!(idx.get("firefox.desktop").unwrap().name, "My Firefox");
        assert!(
            idx.get("gone").is_none(),
            "Hidden=true masks the system entry"
        );
        assert_eq!(idx.len(), 2);
    }

    #[test]
    fn filters_nodisplay_onlyshowin_tryexec() {
        let d = tempfile::tempdir().unwrap();
        write(d.path(), "a.desktop", &app("A"));
        write(
            d.path(),
            "b.desktop",
            &format!("{}NoDisplay=true\n", app("B")),
        );
        write(
            d.path(),
            "c.desktop",
            &format!("{}OnlyShowIn=KDE;\n", app("C")),
        );
        write(
            d.path(),
            "d.desktop",
            &format!("{}TryExec=/nonexistent/lugh-x\n", app("D")),
        );
        write(
            d.path(),
            "e.desktop",
            &format!("{}OnlyShowIn=Lugh;\n", app("E")),
        );
        write(d.path(), "broken.desktop", "garbage");
        let idx = index(&[d.path()]);
        let ids: Vec<_> = idx.entries().iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, ["a", "e"]);
    }

    #[test]
    fn broken_high_precedence_file_does_not_shadow() {
        let user = tempfile::tempdir().unwrap();
        let sys = tempfile::tempdir().unwrap();
        write(user.path(), "x.desktop", "not valid");
        write(sys.path(), "x.desktop", &app("X"));
        assert_eq!(index(&[user.path(), sys.path()]).len(), 1);
    }

    #[test]
    fn rescan_detects_changes() {
        let d = tempfile::tempdir().unwrap();
        write(d.path(), "a.desktop", &app("A"));
        let other = tempfile::tempdir().unwrap();
        let missing = other.path().join("later");
        let mut idx = index(&[d.path(), &missing]);
        assert_eq!(idx.len(), 1);
        let generation = idx.generation();
        assert!(!idx.rescan());
        write(&missing, "b.desktop", &app("B"));
        assert!(idx.rescan());
        assert_eq!(idx.len(), 2);
        assert!(idx.generation() > generation);
        assert!(!idx.rescan());
    }

    #[test]
    fn data_dir_precedence() {
        let dirs = data_dirs(
            Some("/home/u/.local/share".into()),
            Some("/usr/share:relative:/usr/local/share:/usr/share".into()),
            Some("/home/u".into()),
        );
        let s: Vec<_> = dirs.iter().map(|d| d.to_str().unwrap()).collect();
        assert_eq!(
            s,
            [
                "/home/u/.local/share/applications",
                "/usr/share/applications",
                "/usr/local/share/applications",
                "/home/u/.local/share/flatpak/exports/share/applications",
                "/var/lib/flatpak/exports/share/applications",
            ]
        );
        let defaults = data_dirs(None, None, Some("/h".into()));
        assert_eq!(defaults[0], PathBuf::from("/h/.local/share/applications"));
        assert_eq!(defaults[1], PathBuf::from("/usr/local/share/applications"));
        assert_eq!(defaults[2], PathBuf::from("/usr/share/applications"));
    }

    #[test]
    fn desktop_names() {
        assert_eq!(
            desktops_from(Some("Hyprland:GNOME")),
            ["Hyprland", "GNOME", "Lugh"]
        );
        assert_eq!(desktops_from(Some("lugh")), ["lugh"]);
        assert_eq!(desktops_from(None), ["Lugh"]);
    }

    #[test]
    fn masks() {
        assert_eq!(char_mask("ab"), 0b11);
        assert_eq!(char_mask("a b"), char_mask("ab"));
        assert_ne!(char_mask("é") & (1 << 63), 0);
        assert_eq!(char_mask("abc") & !char_mask("cab"), 0);
    }

    #[test]
    fn haystack_fields() {
        let e = DesktopEntry::parse(
            "[Desktop Entry]\nName=Text Editor\nGenericName=Editor\nKeywords=notepad;txt;\nExec=featherpad %f\n",
            "featherpad",
            &Locale::untranslated(),
        )
        .unwrap();
        let idx = AppIndex::from_entries(vec![e.clone(), e]);
        assert_eq!(idx.len(), 1);
        let h = &idx.haystacks()[0];
        let kinds: Vec<_> = h.fields.iter().map(|f| f.kind).collect();
        assert_eq!(
            kinds,
            [
                FieldKind::Name,
                FieldKind::GenericName,
                FieldKind::Keywords,
                FieldKind::Exec
            ]
        );
        assert_eq!(&*h.fields[2].fold, "notepad txt");
    }
}
