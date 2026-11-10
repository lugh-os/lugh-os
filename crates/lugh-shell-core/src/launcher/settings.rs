//! Settings results from the page index exported by Lugh Settings
//! (`/usr/share/lugh/settings/search-index.json`).
//!
//! Expected JSON: an array of pages (or `{"pages": [...]}`), each
//! `{"id": "network/wifi", "title": "Wi-Fi", "section": "Network",
//! "keywords": ["wireless", "hotspot"], "icon": "wifi"}`; only `id` and
//! `title` are required. A missing file means no settings results.

use std::path::Path;
use std::sync::Mutex;

use nucleo_matcher::{Config, Matcher, Utf32String};
use serde::Deserialize;

use super::index::{FieldKind, char_mask};
use super::search::bonus;
use super::{Provider, Query, ResultKind, SearchResult, fold, groups};

/// Where Lugh Settings installs its page index.
pub const SETTINGS_INDEX: &str = "/usr/share/lugh/settings/search-index.json";

/// One searchable settings page or setting.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct SettingsPage {
    /// Page path the Settings app opens (`network/wifi`).
    pub id: String,
    /// Label (`Wi-Fi`).
    pub title: String,
    /// Parent page shown as the subtitle (`Network`).
    #[serde(default)]
    pub section: Option<String>,
    /// Synonyms and Windows terms.
    #[serde(default)]
    pub keywords: Vec<String>,
    /// Symbolic icon name.
    #[serde(default)]
    pub icon: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum IndexFile {
    List(Vec<SettingsPage>),
    Wrapped { pages: Vec<SettingsPage> },
}

#[derive(Debug)]
struct Prepared {
    title: Utf32String,
    title_fold: Box<str>,
    keywords: Utf32String,
    keywords_fold: Box<str>,
    mask: u64,
}

/// A [`Provider`] over a static settings index.
#[derive(Debug)]
pub struct SettingsProvider {
    pages: Vec<SettingsPage>,
    prepared: Vec<Prepared>,
    matcher: Mutex<Matcher>,
}

impl SettingsProvider {
    /// A provider over `pages`.
    pub fn new(pages: Vec<SettingsPage>) -> Self {
        let prepared = pages
            .iter()
            .map(|p| {
                let kw = p.keywords.join(" ");
                let title_fold = fold(&p.title);
                let keywords_fold = fold(&kw);
                Prepared {
                    title: Utf32String::from(p.title.as_str()),
                    keywords: Utf32String::from(kw.as_str()),
                    mask: char_mask(&title_fold) | char_mask(&keywords_fold),
                    title_fold: title_fold.into_boxed_str(),
                    keywords_fold: keywords_fold.into_boxed_str(),
                }
            })
            .collect();
        let mut config = Config::DEFAULT;
        config.prefer_prefix = true;
        Self {
            pages,
            prepared,
            matcher: Mutex::new(Matcher::new(config)),
        }
    }

    /// Parses an index file's JSON.
    pub fn parse(json: &str) -> Result<Self, serde_json::Error> {
        let pages = match serde_json::from_str::<IndexFile>(json)? {
            IndexFile::List(p) | IndexFile::Wrapped { pages: p } => p,
        };
        Ok(Self::new(pages))
    }

    /// Loads an index file; `None` (logged unless missing) when it is absent
    /// or invalid.
    pub fn load(path: &Path) -> Option<Self> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            Err(e) => {
                tracing::warn!(path = %path.display(), %e, "cannot read settings index");
                return None;
            }
        };
        Self::parse(&text)
            .inspect_err(|e| tracing::warn!(path = %path.display(), %e, "invalid settings index"))
            .ok()
    }

    /// The pages.
    pub fn pages(&self) -> &[SettingsPage] {
        &self.pages
    }
}

impl Provider for SettingsProvider {
    fn search(&self, q: &Query) -> Vec<SearchResult> {
        if q.is_empty() || self.pages.is_empty() {
            return Vec::new();
        }
        let needle = Utf32String::from(q.folded.as_str());
        let mask = char_mask(&q.folded);
        let Ok(mut m) = self.matcher.lock() else {
            return Vec::new();
        };
        let mut scored: Vec<(u32, usize)> = self
            .prepared
            .iter()
            .enumerate()
            .filter(|(_, p)| mask & !p.mask == 0)
            .filter_map(|(i, p)| {
                let title = m
                    .fuzzy_match(p.title.slice(..), needle.slice(..))
                    .map(|s| u32::from(s) + bonus(&p.title_fold, &q.folded, FieldKind::Name));
                let kw = m
                    .fuzzy_match(p.keywords.slice(..), needle.slice(..))
                    .map(|s| {
                        u32::from(s) * FieldKind::Keywords.weight() / 10
                            + bonus(&p.keywords_fold, &q.folded, FieldKind::Keywords)
                    });
                Some((title.max(kw)?, i))
            })
            .collect();
        drop(m);
        scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        scored.truncate(q.limit);
        scored
            .into_iter()
            .map(|(score, i)| {
                let p = &self.pages[i];
                SearchResult {
                    kind: ResultKind::Setting,
                    group: groups::SETTINGS.into(),
                    title: p.title.clone(),
                    subtitle: p.section.clone().unwrap_or_else(|| "Settings".into()),
                    icon: p.icon.clone().unwrap_or_else(|| "settings".into()),
                    target: p.id.clone(),
                    score: i64::from(score),
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INDEX: &str = r#"[
        {"id": "network/wifi", "title": "Wi-Fi", "section": "Network", "keywords": ["wireless", "hotspot", "wifi password"], "icon": "wifi"},
        {"id": "bluetooth", "title": "Bluetooth", "keywords": ["pair", "headphones"]},
        {"id": "appearance/theme", "title": "Dark mode", "section": "Appearance", "icon": "moon"},
        {"id": "display", "title": "Display", "keywords": ["screen", "resolution", "monitor"]}
    ]"#;

    #[test]
    fn searches_titles_and_keywords() {
        let p = SettingsProvider::parse(INDEX).unwrap();
        let r = p.search(&Query::new("wi", 10));
        assert_eq!(r[0].target, "network/wifi");
        assert_eq!(r[0].subtitle, "Network");
        assert_eq!(r[0].kind, ResultKind::Setting);
        assert_eq!(r[0].group, "Settings");

        let r = p.search(&Query::new("headphones", 10));
        assert_eq!(r[0].target, "bluetooth");
        assert_eq!(r[0].icon, "settings");

        let r = p.search(&Query::new("dark", 10));
        assert_eq!(r[0].title, "Dark mode");

        let r = p.search(&Query::new("resolution", 1));
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].target, "display");

        assert!(p.search(&Query::new("zzzq", 10)).is_empty());
        assert!(p.search(&Query::new("", 10)).is_empty());
    }

    #[test]
    fn accepts_wrapped_form_and_rejects_garbage() {
        let p = SettingsProvider::parse(r#"{"pages": [{"id": "a", "title": "A"}]}"#).unwrap();
        assert_eq!(p.pages().len(), 1);
        assert!(SettingsProvider::parse("{").is_err());
        assert!(SettingsProvider::load(Path::new("/nonexistent/lugh/index.json")).is_none());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.json");
        std::fs::write(&path, INDEX).unwrap();
        assert_eq!(SettingsProvider::load(&path).unwrap().pages().len(), 4);
        std::fs::write(&path, "not json").unwrap();
        assert!(SettingsProvider::load(&path).is_none());
    }
}
