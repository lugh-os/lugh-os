//! [`Launcher`]: answers a query with grouped, ranked results.
//!
//! Apps are scored with nucleo's fuzzy matcher over each entry's name
//! (highest weight), untranslated name, generic name, keywords and exec
//! program, plus tier bonuses for an exact name, a name prefix and a word
//! start. That match quality is multiplied by a usage factor from
//! [`History`] (frequency × recency, up to ×1.5), so habits reorder similar
//! matches without lifting a weak fuzzy match over an exact one. Ties go to
//! the alphabetically first name.
//!
//! Speed: haystacks are prepared once at index time; per keystroke there is no
//! haystack allocation, a 64-bit character mask rejects most entries before
//! the matcher runs, and when the query extends the previous one only the
//! previous matches are re-scored.

use std::path::Path;

use nucleo_matcher::{Config, Matcher, Utf32String};

use super::aliases::{AliasTable, AliasTarget};
use super::history::{History, HistoryError};
use super::index::{AppIndex, FieldKind, Haystack, char_mask};
use super::settings::SettingsProvider;
use super::{Provider, Query, ResultKind, SearchResult, calc, groups, unix_now};

/// Exact name match.
pub(crate) const TIER_EXACT: u32 = 1000;
/// Name starts with the query.
pub(crate) const TIER_PREFIX: u32 = 600;
/// A word of the name starts with the query.
pub(crate) const TIER_WORD: u32 = 300;
/// Exact word in a secondary field (generic name, keywords, exec).
const TIER_FIELD_EXACT: u32 = 250;
/// Prefix or word start in a secondary field.
const TIER_FIELD_WORD: u32 = 150;
/// Maximum extra weight from usage history (+50 %).
const USAGE_BOOST: f64 = 0.5;
/// How long cached usage boosts stay valid (recency changes slowly).
const BOOST_TTL_SECS: u64 = 600;

/// An app shown in the empty-query "recent" row (QML `launcher.recent`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct RecentApp {
    /// App id.
    pub app_id: String,
    /// Display name.
    pub name: String,
    /// Freedesktop icon name.
    pub icon: String,
}

/// An alias bound to the current index.
#[derive(Debug)]
struct ResolvedAlias {
    names: Vec<(Box<str>, Utf32String)>,
    target: Resolved,
}

#[derive(Debug)]
enum Resolved {
    App(usize),
    Other(SearchResult),
}

/// The previous query's matches, for narrowing while the user types.
#[derive(Debug, Default)]
struct Narrowing {
    generation: u64,
    folded: String,
    candidates: Vec<u32>,
    valid: bool,
}

/// One app match being ranked.
#[derive(Debug, Clone, Copy)]
struct Scored {
    score: i64,
    index: u32,
    /// `(alias, name) + 1` when an alias gave the best score, else 0.
    alias: u32,
}

/// Prepared query for app matching.
#[derive(Debug)]
struct Prep {
    folded: String,
    whole: Utf32String,
    mask: u64,
    words: Vec<(String, Utf32String, u64)>,
}

/// The launcher search engine. Not thread-safe by design: keep one per shell
/// and call it from the thread that owns it (it reuses buffers between
/// queries).
#[derive(Debug)]
pub struct Launcher {
    index: AppIndex,
    history: History,
    aliases: AliasTable,
    resolved: Vec<ResolvedAlias>,
    resolved_generation: u64,
    providers: Vec<Box<dyn Provider>>,
    matcher: Matcher,
    boosts: Vec<f32>,
    boost_key: Option<(u64, u64, u64)>,
    narrowing: Narrowing,
    scored: Vec<Scored>,
    next_candidates: Vec<u32>,
}

impl Launcher {
    /// A launcher over `index` and `history`, with the built-in alias table
    /// and no extra providers.
    pub fn new(index: AppIndex, history: History) -> Self {
        let mut config = Config::DEFAULT;
        config.prefer_prefix = true;
        Self {
            index,
            history,
            aliases: AliasTable::embedded(),
            resolved: Vec::new(),
            resolved_generation: 0,
            providers: Vec::new(),
            matcher: Matcher::new(config),
            boosts: Vec::new(),
            boost_key: None,
            narrowing: Narrowing::default(),
            scored: Vec::new(),
            next_candidates: Vec::new(),
        }
    }

    /// The session launcher: [`AppIndex::from_env`], [`History::from_env`],
    /// built-in aliases merged with `/usr/share/lugh/launcher/aliases.toml`,
    /// and the settings provider when its index file exists.
    pub fn from_env() -> Self {
        let mut l = Self::new(AppIndex::from_env(), History::from_env());
        l.set_aliases(AliasTable::system());
        if let Some(p) = SettingsProvider::load(Path::new(super::settings::SETTINGS_INDEX)) {
            l.add_provider(Box::new(p));
        }
        l
    }

    /// Replaces the alias table.
    pub fn set_aliases(&mut self, aliases: AliasTable) {
        self.aliases = aliases;
        self.resolved_generation = 0;
        self.narrowing.valid = false;
    }

    /// Adds a provider (settings, open windows, files, …). Results appear in
    /// the provider's groups, in [`groups::ORDER`].
    pub fn add_provider(&mut self, provider: Box<dyn Provider>) {
        self.providers.push(provider);
    }

    /// The app index.
    pub fn index(&self) -> &AppIndex {
        &self.index
    }

    /// The launch history.
    pub fn history(&self) -> &History {
        &self.history
    }

    /// Re-scans the app index if its directories changed (see
    /// [`AppIndex::rescan`]). Returns whether anything changed.
    pub fn rescan(&mut self) -> bool {
        let changed = self.index.rescan();
        if changed {
            self.narrowing.valid = false;
        }
        changed
    }

    /// Records a launch now (call it whenever an app is started from the
    /// launcher, dock or Start).
    pub fn record_launch(&mut self, app_id: &str) -> Result<(), HistoryError> {
        self.history.record(app_id, unix_now())
    }

    /// Clears the launch history ("Clear history").
    pub fn clear_history(&mut self) -> Result<(), HistoryError> {
        self.history.clear()
    }

    /// Up to `n` recently launched apps that are still installed, newest
    /// first, for the empty-query view.
    pub fn recent(&self, n: usize) -> Vec<RecentApp> {
        self.history
            .recent(usize::MAX)
            .into_iter()
            .filter_map(|id| self.index.get(id))
            .take(n)
            .map(|e| RecentApp {
                app_id: e.id.clone(),
                name: e.name.clone(),
                icon: icon_or_default(e.icon.as_deref()),
            })
            .collect()
    }

    /// Results for `query`, at most `limit`, grouped in [`groups::ORDER`]
    /// and ranked within each group. An empty query gives no results (show
    /// [`Launcher::recent`] instead).
    pub fn search(&mut self, query: &str, limit: usize) -> Vec<SearchResult> {
        self.search_at(query, limit, unix_now())
    }

    /// [`Launcher::search`] with an explicit clock (Unix seconds).
    pub fn search_at(&mut self, query: &str, limit: usize, now: u64) -> Vec<SearchResult> {
        let q = Query::new(query, limit);
        if q.is_empty() || limit == 0 {
            return Vec::new();
        }
        if let Some(cmd) = q.text.strip_prefix('>') {
            let cmd = cmd.trim();
            if cmd.is_empty() {
                return Vec::new();
            }
            return vec![SearchResult {
                kind: ResultKind::Command,
                group: groups::RUN.into(),
                title: cmd.into(),
                subtitle: "Run in Terminal".into(),
                icon: "terminal".into(),
                target: cmd.into(),
                score: 0,
            }];
        }

        self.refresh(now);
        let mut out = Vec::new();
        self.search_apps(&q, &mut out);
        if let Some(a) = calc::answer(&q.text) {
            out.push(SearchResult {
                kind: ResultKind::Calc,
                group: groups::CALCULATOR.into(),
                title: a.display,
                subtitle: "Press Enter to copy".into(),
                icon: "calculator".into(),
                target: a.value,
                score: 0,
            });
        }
        for p in &self.providers {
            out.extend(p.search(&q).into_iter().take(limit));
        }
        arrange(&mut out, limit);
        out
    }

    /// Re-resolves aliases and usage boosts when the index, the history or
    /// the clock moved on.
    fn refresh(&mut self, now: u64) {
        let generation = self.index.generation();
        if self.resolved_generation != generation {
            self.resolved = resolve_aliases(&self.aliases, &self.index);
            self.resolved_generation = generation;
        }
        let key = (generation, self.history.revision(), now / BOOST_TTL_SECS);
        if self.boost_key != Some(key) {
            self.boosts.clear();
            self.boosts.resize(self.index.len(), 0.0);
            for (id, usage) in self.history.iter() {
                if let Some(i) = self.index.position(id) {
                    self.boosts[i] = usage.weight(now) as f32;
                }
            }
            self.boost_key = Some(key);
        }
    }

    fn search_apps(&mut self, q: &Query, out: &mut Vec<SearchResult>) {
        let prep = Prep::new(&q.folded);
        let hay = self.index.haystacks();
        let generation = self.index.generation();
        self.scored.clear();
        self.next_candidates.clear();

        let narrow = self.narrowing.valid
            && self.narrowing.generation == generation
            && prep.folded.starts_with(&self.narrowing.folded);
        let mut consider = |i: u32, matcher: &mut Matcher| {
            let h = &hay[i as usize];
            if prep.mask & !h.mask != 0 {
                return;
            }
            if let Some(quality) = score_entry(matcher, h, &prep) {
                self.next_candidates.push(i);
                let boost = 1.0 + USAGE_BOOST * f64::from(self.boosts[i as usize]);
                self.scored.push(Scored {
                    score: (f64::from(quality) * boost).round() as i64,
                    index: i,
                    alias: 0,
                });
            }
        };
        if narrow {
            for &i in &self.narrowing.candidates {
                consider(i, &mut self.matcher);
            }
        } else {
            for i in 0..hay.len() as u32 {
                consider(i, &mut self.matcher);
            }
        }
        std::mem::swap(&mut self.narrowing.candidates, &mut self.next_candidates);
        self.narrowing.folded.clone_from(&prep.folded);
        self.narrowing.generation = generation;
        self.narrowing.valid = true;

        // Aliases: few, so always checked in full.
        for (ai, alias) in self.resolved.iter().enumerate() {
            let best = alias
                .names
                .iter()
                .enumerate()
                .filter_map(|(ni, (fold, text))| {
                    let tier = alias_tier(fold, &prep.folded)?;
                    let fuzzy = self
                        .matcher
                        .fuzzy_match(text.slice(..), prep.whole.slice(..))
                        .map_or(0, u32::from);
                    Some((tier + fuzzy, ni))
                })
                .max_by_key(|&(s, ni)| (s, std::cmp::Reverse(ni)));
            let Some((quality, ni)) = best else { continue };
            match &alias.target {
                Resolved::App(i) => {
                    let boost = 1.0 + USAGE_BOOST * f64::from(self.boosts[*i]);
                    let score = (f64::from(quality) * boost).round() as i64;
                    let tag = pack_alias(ai, ni);
                    match self.scored.iter_mut().find(|s| s.index as usize == *i) {
                        Some(s) if s.score < score => {
                            s.score = score;
                            s.alias = tag;
                        }
                        Some(_) => {}
                        None => self.scored.push(Scored {
                            score,
                            index: *i as u32,
                            alias: tag,
                        }),
                    }
                }
                Resolved::Other(r) => {
                    let mut r = r.clone();
                    r.score = i64::from(quality);
                    r.subtitle = if r.subtitle.is_empty() {
                        matches_text(&alias.names[ni].0)
                    } else {
                        format!("{} · {}", r.subtitle, matches_text(&alias.names[ni].0))
                    };
                    out.push(r);
                }
            }
        }

        // Top `limit` by score, ties by name (index order is name order).
        let cmp = |a: &Scored, b: &Scored| b.score.cmp(&a.score).then(a.index.cmp(&b.index));
        if self.scored.len() > q.limit {
            self.scored.select_nth_unstable_by(q.limit - 1, cmp);
            self.scored.truncate(q.limit);
        }
        self.scored.sort_unstable_by(cmp);

        let entries = self.index.entries();
        out.extend(self.scored.iter().map(|s| {
            let e = &entries[s.index as usize];
            let subtitle = match unpack_alias(s.alias) {
                Some((ai, ni)) => matches_text(&self.resolved[ai].names[ni].0),
                None => e
                    .generic_name
                    .clone()
                    .or_else(|| e.comment.clone())
                    .unwrap_or_else(|| "Application".into()),
            };
            SearchResult {
                kind: ResultKind::App,
                group: groups::APPS.into(),
                title: e.name.clone(),
                subtitle,
                icon: icon_or_default(e.icon.as_deref()),
                target: e.id.clone(),
                score: s.score,
            }
        }));
    }
}

impl Prep {
    fn new(folded: &str) -> Self {
        let words = if folded.contains(' ') {
            folded
                .split(' ')
                .map(|w| (w.to_owned(), Utf32String::from(w), char_mask(w)))
                .collect()
        } else {
            Vec::new()
        };
        Self {
            folded: folded.to_owned(),
            whole: Utf32String::from(folded),
            mask: char_mask(folded),
            words,
        }
    }
}

/// Best field score of `needle` in `h`: nucleo score × field weight plus a
/// tier bonus. `None` when no field matches.
fn best_field(
    m: &mut Matcher,
    h: &Haystack,
    needle: &Utf32String,
    folded: &str,
    mask: u64,
) -> Option<u32> {
    let mut best = None;
    for f in &h.fields {
        if mask & !f.mask != 0 {
            continue;
        }
        if let Some(s) = m.fuzzy_match(f.text.slice(..), needle.slice(..)) {
            let v = u32::from(s) * f.kind.weight() / 10 + bonus(&f.fold, folded, f.kind);
            best = Some(best.map_or(v, |b: u32| b.max(v)));
        }
    }
    best
}

/// Match quality of an entry: the best single-field match of the whole
/// query, or for multi-word queries, each word in its best field (×0.9).
fn score_entry(m: &mut Matcher, h: &Haystack, p: &Prep) -> Option<u32> {
    let whole = best_field(m, h, &p.whole, &p.folded, p.mask);
    if p.words.is_empty() {
        return whole;
    }
    let mut total = 0u32;
    for (w, needle, mask) in &p.words {
        match best_field(m, h, needle, w, *mask) {
            Some(s) => total += s,
            None => return whole,
        }
    }
    Some(whole.map_or(total * 9 / 10, |s| s.max(total * 9 / 10)))
}

/// Tier bonus of a folded field for a folded query.
pub(crate) fn bonus(field: &str, q: &str, kind: FieldKind) -> u32 {
    if kind.is_name() {
        if field == q {
            TIER_EXACT
        } else if field.starts_with(q) {
            TIER_PREFIX
        } else if word_start(field, q).is_some() {
            TIER_WORD
        } else {
            0
        }
    } else {
        match word_start(field, q) {
            Some(true) => TIER_FIELD_EXACT,
            Some(false) => TIER_FIELD_WORD,
            None => 0,
        }
    }
}

/// Whether `q` starts a word of `field`; `Some(true)` when it is a whole word.
pub(crate) fn word_start(field: &str, q: &str) -> Option<bool> {
    if q.is_empty() {
        return None;
    }
    let bytes = field.as_bytes();
    let boundary = |b: u8| !b.is_ascii_alphanumeric() && b < 0x80;
    let mut found = None;
    for (i, _) in field.match_indices(q) {
        if i == 0 || boundary(bytes[i - 1]) {
            let end = i + q.len();
            let whole = end == bytes.len() || boundary(bytes[end]);
            if whole {
                return Some(true);
            }
            found = Some(false);
        }
    }
    found
}

/// Alias name match: exact, prefix from 3 characters, or a word start from 4.
fn alias_tier(name: &str, q: &str) -> Option<u32> {
    if name == q {
        Some(TIER_EXACT)
    } else if q.len() >= 3 && name.starts_with(q) {
        Some(TIER_PREFIX)
    } else if q.len() >= 4 && word_start(name, q).is_some() {
        Some(TIER_WORD)
    } else {
        None
    }
}

fn pack_alias(alias: usize, name: usize) -> u32 {
    ((alias as u32) << 8 | (name as u32 & 0xff)) + 1
}

fn unpack_alias(tag: u32) -> Option<(usize, usize)> {
    let t = tag.checked_sub(1)?;
    Some(((t >> 8) as usize, (t & 0xff) as usize))
}

fn matches_text(name: &str) -> String {
    format!("Matches ‘{name}’")
}

fn icon_or_default(icon: Option<&str>) -> String {
    icon.unwrap_or("application-x-executable").to_owned()
}

fn resolve_aliases(table: &AliasTable, index: &AppIndex) -> Vec<ResolvedAlias> {
    let names = |names: &[String]| -> Vec<(Box<str>, Utf32String)> {
        names
            .iter()
            .take(256)
            .map(|n| (n.clone().into_boxed_str(), Utf32String::from(n.as_str())))
            .collect()
    };
    let entries = index.entries();
    table
        .aliases()
        .iter()
        .filter(|a| a.requires.as_deref().is_none_or(|r| index.get(r).is_some()))
        .filter_map(|a| {
            let target = match &a.target {
                AliasTarget::App { apps, categories } => {
                    let by_id = apps.iter().find_map(|id| index.position(id));
                    let by_cat = || {
                        let in_cat = |i: &usize| {
                            entries[*i]
                                .categories
                                .iter()
                                .any(|c| categories.contains(c))
                        };
                        let all = 0..entries.len();
                        all.clone()
                            .filter(in_cat)
                            .find(|i| !entries[*i].terminal)
                            .or_else(|| all.clone().find(in_cat))
                    };
                    Resolved::App(by_id.or_else(by_cat)?)
                }
                AliasTarget::Setting { page, title, icon } => Resolved::Other(SearchResult {
                    kind: ResultKind::Setting,
                    group: groups::SETTINGS.into(),
                    title: title.clone(),
                    subtitle: "Settings".into(),
                    icon: icon.clone(),
                    target: page.clone(),
                    score: 0,
                }),
                AliasTarget::Help {
                    path,
                    title,
                    subtitle,
                    icon,
                } => Resolved::Other(SearchResult {
                    kind: ResultKind::File,
                    group: groups::FILES.into(),
                    title: title.clone(),
                    subtitle: subtitle.clone(),
                    icon: icon.clone(),
                    target: path.to_string_lossy().into_owned(),
                    score: 0,
                }),
            };
            Some(ResolvedAlias {
                names: names(&a.names),
                target,
            })
        })
        .collect()
}

/// Orders results by group, then score (stable for equal scores), and trims
/// to `limit` by shortening the largest groups first, so every group that
/// has results keeps some.
fn arrange(out: &mut Vec<SearchResult>, limit: usize) {
    out.sort_by(|a, b| {
        groups::rank(&a.group)
            .cmp(&groups::rank(&b.group))
            .then_with(|| a.group.cmp(&b.group))
            .then(b.score.cmp(&a.score))
    });
    if out.len() <= limit {
        return;
    }
    // Group runs: (start, len).
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for (i, r) in out.iter().enumerate() {
        match runs.last_mut() {
            Some((s, n)) if out[*s].group == r.group => *n += 1,
            _ => runs.push((i, 1)),
        }
    }
    let mut keep: Vec<usize> = runs.iter().map(|r| r.1).collect();
    let mut total: usize = keep.iter().sum();
    while total > limit {
        // Largest group loses one; ties: the later group.
        let (gi, _) = keep
            .iter()
            .enumerate()
            .max_by_key(|&(_, n)| *n)
            .unwrap_or((0, &0));
        keep[gi] -= 1;
        total -= 1;
    }
    let mut i = 0;
    out.retain(|_| {
        let gi = runs.partition_point(|(s, _)| *s <= i) - 1;
        let pos = i - runs[gi].0;
        i += 1;
        pos < keep[gi]
    });
}

#[cfg(test)]
mod tests {
    use super::super::desktop_entry::{DesktopEntry, Locale};
    use super::*;

    const DAY: u64 = 86_400;
    const NOW: u64 = 1_000 * DAY;

    fn entry(id: &str, name: &str, generic: &str, keywords: &str, cats: &str) -> DesktopEntry {
        let text = format!(
            "[Desktop Entry]\nType=Application\nName={name}\nGenericName={generic}\nKeywords={keywords}\nCategories={cats}\nExec={id} %U\nIcon={id}\n"
        );
        DesktopEntry::parse(&text, id, &Locale::untranslated()).unwrap()
    }

    fn sample() -> AppIndex {
        AppIndex::from_entries(vec![
            entry(
                "firefox",
                "Firefox",
                "Web Browser",
                "internet;web;browser;",
                "Network;WebBrowser;",
            ),
            entry(
                "lugh-files",
                "Files",
                "File Manager",
                "folder;explorer;",
                "System;FileManager;",
            ),
            entry(
                "org.codeberg.dnkl.foot",
                "Foot",
                "Terminal",
                "shell;console;",
                "System;TerminalEmulator;",
            ),
            entry(
                "vlc",
                "VLC",
                "Media Player",
                "video;music;movie;",
                "AudioVideo;Player;",
            ),
            entry(
                "lugh-settings",
                "Settings",
                "System Settings",
                "preferences;",
                "Settings;",
            ),
            entry(
                "lugh-store",
                "Store",
                "App Store",
                "install;apps;",
                "PackageManager;",
            ),
            entry(
                "featherpad",
                "FeatherPad",
                "Text Editor",
                "txt;",
                "Utility;TextEditor;",
            ),
            entry("vim", "Vim", "Text Editor", "", "Utility;TextEditor;"),
            entry(
                "lugh-tasks",
                "Tasks",
                "Task Manager",
                "processes;",
                "System;Monitor;",
            ),
            entry(
                "fileroller",
                "File Roller",
                "Archive Manager",
                "zip;",
                "Archiving;",
            ),
            entry("filezilla", "FileZilla", "FTP Client", "ftp;", "Network;"),
            entry("profile", "Profile Settings", "", "", "Settings;"),
            entry("firewall", "Firewall", "Firewall Settings", "", "Settings;"),
        ])
    }

    fn launcher() -> Launcher {
        Launcher::new(sample(), History::in_memory())
    }

    fn titles(r: &[SearchResult]) -> Vec<&str> {
        r.iter().map(|r| r.title.as_str()).collect()
    }

    fn app_ids(r: &[SearchResult]) -> Vec<&str> {
        r.iter()
            .filter(|r| r.kind == ResultKind::App)
            .map(|r| r.target.as_str())
            .collect()
    }

    #[test]
    fn exact_beats_prefix_beats_fuzzy() {
        let mut l = launcher();
        let r = l.search_at("files", 10, NOW);
        assert_eq!(
            r[0].target,
            "lugh-files",
            "exact name first: {:?}",
            titles(&r)
        );
        let r = l.search_at("file", 10, NOW);
        let ids = app_ids(&r);
        let pos = |id| ids.iter().position(|x| *x == id).unwrap();
        assert!(
            pos("fileroller") < pos("profile"),
            "word-start prefix above fuzzy: {ids:?}"
        );
        assert!(pos("filezilla") < pos("profile"), "{ids:?}");

        let r = l.search_at("fire", 10, NOW);
        assert_eq!(app_ids(&r)[..2], ["firefox", "firewall"]);

        let r = l.search_at("ffx", 10, NOW);
        assert_eq!(app_ids(&r)[0], "firefox", "fuzzy still finds it");
    }

    #[test]
    fn secondary_fields_match() {
        let mut l = launcher();
        assert_eq!(app_ids(&l.search_at("browser", 5, NOW))[0], "firefox");
        assert_eq!(app_ids(&l.search_at("movie", 5, NOW))[0], "vlc");
        assert_eq!(
            app_ids(&l.search_at("terminal", 5, NOW))[0],
            "org.codeberg.dnkl.foot"
        );
        let r = l.search_at("vlc", 5, NOW);
        assert_eq!(r[0].subtitle, "Media Player");
        assert_eq!(r[0].icon, "vlc");
        assert_eq!(r[0].group, "Apps");
    }

    #[test]
    fn multi_word_across_fields() {
        let mut l = launcher();
        assert_eq!(
            app_ids(&l.search_at("firefox browser", 5, NOW)),
            ["firefox"]
        );
        assert_eq!(app_ids(&l.search_at("web brow", 5, NOW))[0], "firefox");
    }

    #[test]
    fn frequency_and_recency_reorder() {
        let mut l = launcher();
        // "fi": Files, FileZilla, File Roller, Firefox, Firewall all prefix-match.
        let before = app_ids(&l.search_at("fi", 10, NOW))[0].to_owned();
        assert_eq!(before, "fileroller", "alphabetical among equals");
        for _ in 0..10 {
            l.history.record("firewall", NOW - DAY).unwrap();
        }
        assert_eq!(app_ids(&l.search_at("fi", 10, NOW))[0], "firewall");

        // Same count, different age: the recent one wins.
        let mut l = launcher();
        for _ in 0..5 {
            l.history.record("filezilla", NOW - 60 * DAY).unwrap();
            l.history.record("firefox", NOW - DAY).unwrap();
        }
        let ids = app_ids(&l.search_at("fi", 10, NOW)).join(",");
        assert!(ids.starts_with("firefox,filezilla"), "{ids}");
    }

    #[test]
    fn usage_does_not_beat_exact_name() {
        let mut l = launcher();
        for _ in 0..100 {
            l.history.record("filezilla", NOW).unwrap();
        }
        assert_eq!(app_ids(&l.search_at("files", 5, NOW))[0], "lugh-files");
    }

    #[test]
    fn narrowing_matches_full_search() {
        let mut typed = launcher();
        let mut fresh = launcher();
        for q in [
            "f", "fi", "fil", "file", "file ", "file m", "file ma", "fi", "x", "xz",
        ] {
            let a = typed.search_at(q, 50, NOW);
            fresh.narrowing.valid = false;
            let b = fresh.search_at(q, 50, NOW);
            assert_eq!(a, b, "query {q:?}");
        }
    }

    #[test]
    fn aliases() {
        let mut l = launcher();
        let r = l.search_at("control panel", 5, NOW);
        assert_eq!(r[0].target, "lugh-settings");
        assert_eq!(r[0].subtitle, "Matches ‘control panel’");

        let r = l.search_at("task man", 5, NOW);
        assert_eq!(r[0].target, "lugh-tasks");

        let r = l.search_at("cmd", 5, NOW);
        assert_eq!(r[0].target, "org.codeberg.dnkl.foot");
        assert_eq!(r[0].subtitle, "Matches ‘cmd’");

        let r = l.search_at("powershell", 5, NOW);
        assert_eq!(r[0].target, "org.codeberg.dnkl.foot");

        let r = l.search_at("add or remove", 5, NOW);
        assert_eq!(r[0].target, "lugh-store");

        let r = l.search_at("notepad", 5, NOW);
        assert_eq!(r[0].target, "featherpad", "non-terminal editor preferred");

        let r = l.search_at("file explorer", 5, NOW);
        assert_eq!(r[0].target, "lugh-files");

        let r = l.search_at("device manager", 5, NOW);
        let dev = r.iter().find(|r| r.kind == ResultKind::Setting).unwrap();
        assert_eq!(dev.target, "devices");
        assert_eq!(dev.group, "Settings");
        assert!(dev.subtitle.contains("Matches ‘device manager’"));

        let r = l.search_at("regedit", 5, NOW);
        let help = r.iter().find(|r| r.kind == ResultKind::File).unwrap();
        assert!(help.target.ends_with(".config/lugh/desktop.toml"));
        assert_eq!(help.group, "Files");

        assert!(
            l.search_at("cm", 5, NOW)
                .iter()
                .all(|r| !r.subtitle.starts_with("Matches")),
            "2-char prefixes do not trigger aliases"
        );
    }

    #[test]
    fn alias_does_not_relabel_a_better_own_match() {
        let mut l = launcher();
        let r = l.search_at("files", 5, NOW);
        assert_eq!(r[0].subtitle, "File Manager");
    }

    #[test]
    fn calculator_and_commands() {
        let mut l = launcher();
        let r = l.search_at("2+2*3", 10, NOW);
        let c = r.iter().find(|r| r.kind == ResultKind::Calc).unwrap();
        assert_eq!(
            (c.title.as_str(), c.target.as_str(), c.group.as_str()),
            ("8", "8", "Calculator")
        );

        let r = l.search_at("5 km in mi", 10, NOW);
        assert_eq!(
            r.iter().find(|r| r.kind == ResultKind::Calc).unwrap().title,
            "3.106855961 mi"
        );

        let r = l.search_at("> htop -d 5", 10, NOW);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].kind, ResultKind::Command);
        assert_eq!(r[0].target, "htop -d 5");
        assert_eq!(r[0].group, "Run");
        assert!(l.search_at(">", 10, NOW).is_empty());
    }

    #[test]
    fn empty_and_limit() {
        let mut l = launcher();
        assert!(l.search_at("", 10, NOW).is_empty());
        assert!(l.search_at("   ", 10, NOW).is_empty());
        assert!(l.search_at("f", 0, NOW).is_empty());
        assert_eq!(l.search_at("e", 3, NOW).len(), 3);
        assert!(l.search_at("qqqqzz", 10, NOW).is_empty());
    }

    #[derive(Debug)]
    struct Fixed(Vec<SearchResult>);
    impl Provider for Fixed {
        fn search(&self, _: &Query) -> Vec<SearchResult> {
            self.0.clone()
        }
    }

    fn res(kind: ResultKind, group: &str, title: &str, score: i64) -> SearchResult {
        SearchResult {
            kind,
            group: group.into(),
            title: title.into(),
            subtitle: String::new(),
            icon: String::new(),
            target: title.into(),
            score,
        }
    }

    #[test]
    fn providers_are_grouped_in_display_order() {
        let mut l = launcher();
        l.add_provider(Box::new(Fixed(vec![
            res(ResultKind::File, groups::FILES, "firefox-notes.txt", 5),
            res(ResultKind::Window, groups::WINDOWS, "Firefox — Lugh", 9),
            res(ResultKind::Setting, groups::SETTINGS, "Default browser", 1),
            res(ResultKind::Setting, groups::SETTINGS, "Firewall", 3),
        ])));
        let r = l.search_at("fire", 50, NOW);
        let g: Vec<_> = r.iter().map(|r| r.group.as_str()).collect();
        let mut sorted = g.clone();
        sorted.sort_by_key(|g| groups::rank(g));
        assert_eq!(g, sorted);
        let settings: Vec<_> = r
            .iter()
            .filter(|r| r.group == "Settings")
            .map(|r| r.title.as_str())
            .collect();
        assert_eq!(settings, ["Firewall", "Default browser"]);
    }

    #[test]
    fn trimming_keeps_every_group() {
        let mut v: Vec<SearchResult> = (0..10)
            .map(|i| res(ResultKind::App, groups::APPS, &format!("a{i}"), 100 - i))
            .collect();
        v.push(res(ResultKind::Setting, groups::SETTINGS, "s", 1));
        v.push(res(ResultKind::File, groups::FILES, "f1", 2));
        v.push(res(ResultKind::File, groups::FILES, "f2", 1));
        arrange(&mut v, 6);
        assert_eq!(titles(&v), ["a0", "a1", "a2", "s", "f1", "f2"]);
        let mut w = vec![res(ResultKind::App, groups::APPS, "a", 1)];
        arrange(&mut w, 5);
        assert_eq!(w.len(), 1);
    }

    #[test]
    fn recent_apps() {
        let mut l = launcher();
        l.history.record("vlc", NOW - 10).unwrap();
        l.history.record("uninstalled-app", NOW - 5).unwrap();
        l.history.record("firefox", NOW).unwrap();
        let r = l.recent(5);
        let ids: Vec<_> = r.iter().map(|r| r.app_id.as_str()).collect();
        assert_eq!(ids, ["firefox", "vlc"]);
        assert_eq!(r[0].name, "Firefox");
        assert_eq!(r[0].icon, "firefox");
        assert_eq!(l.recent(1).len(), 1);
    }

    #[test]
    fn word_start_helper() {
        assert_eq!(word_start("file manager", "man"), Some(false));
        assert_eq!(word_start("file manager", "manager"), Some(true));
        assert_eq!(word_start("firefox", "fox"), None);
        assert_eq!(word_start("gnome-disks", "disks"), Some(true));
        assert_eq!(word_start("x", ""), None);
    }

    #[test]
    fn alias_packing() {
        assert_eq!(unpack_alias(0), None);
        assert_eq!(unpack_alias(pack_alias(3, 7)), Some((3, 7)));
    }
}
