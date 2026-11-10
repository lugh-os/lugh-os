//! Parsing of the `Notify` arguments that need interpretation: the hints
//! dictionary, the flat actions list, the icon and the image.

use std::collections::HashMap;

use zbus::zvariant::Value;

/// The hints the shell uses. Everything else (sound, category, x/y,
/// raw `image-data`, …) is ignored.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Hints {
    /// 0 low, 1 normal (default), 2 critical.
    pub(crate) urgency: u8,
    pub(crate) transient: bool,
    pub(crate) resident: bool,
    /// `desktop-entry`, without a `.desktop` suffix.
    pub(crate) desktop_entry: String,
    /// `image-path` / `image_path` as given.
    pub(crate) image_path: String,
}

fn as_u64(v: &Value<'_>) -> Option<u64> {
    match v {
        Value::U8(n) => Some(u64::from(*n)),
        Value::U16(n) => Some(u64::from(*n)),
        Value::U32(n) => Some(u64::from(*n)),
        Value::U64(n) => Some(*n),
        Value::I16(n) => u64::try_from(*n).ok(),
        Value::I32(n) => u64::try_from(*n).ok(),
        Value::I64(n) => u64::try_from(*n).ok(),
        Value::Bool(b) => Some(u64::from(*b)),
        Value::Value(inner) => as_u64(inner),
        _ => None,
    }
}

fn as_str<'a>(v: &'a Value<'_>) -> Option<&'a str> {
    match v {
        Value::Str(s) => Some(s.as_str()),
        Value::Value(inner) => as_str(inner),
        _ => None,
    }
}

/// Reads the hints. Clients are sloppy about types (urgency as `i`, booleans
/// as integers), so numbers are accepted in any integer type.
pub(crate) fn parse_hints(hints: &HashMap<&str, Value<'_>>) -> Hints {
    let flag = |key: &str| hints.get(key).and_then(as_u64).is_some_and(|n| n != 0);
    let text = |key: &str| hints.get(key).and_then(as_str).unwrap_or_default();
    let image = match text("image-path") {
        "" => text("image_path"),
        p => p,
    };
    Hints {
        urgency: hints
            .get("urgency")
            .and_then(as_u64)
            .map_or(1, |n| u8::try_from(n.min(2)).unwrap_or(2)),
        transient: flag("transient"),
        resident: flag("resident"),
        desktop_entry: text("desktop-entry")
            .trim_end_matches(".desktop")
            .to_owned(),
        image_path: image.to_owned(),
    }
}

/// `[key, label, key, label, …]` → pairs. A dangling key is dropped.
pub(crate) fn parse_actions(flat: &[&str]) -> Vec<(String, String)> {
    flat.as_chunks::<2>()
        .0
        .iter()
        .map(|[key, label]| ((*key).to_owned(), (*label).to_owned()))
        .collect()
}

/// The `appIcon` role: `app_icon` if set, else the `desktop-entry` hint, else
/// the lowercased application name. Paths and URLs pass through unchanged.
pub(crate) fn resolve_icon(app_icon: &str, desktop_entry: &str, app_name: &str) -> String {
    let icon = app_icon.trim();
    if !icon.is_empty() {
        return icon.to_owned();
    }
    if !desktop_entry.is_empty() {
        return desktop_entry.to_owned();
    }
    app_name.trim().to_lowercase()
}

/// The `image` role: a URL passes through, an absolute path becomes a
/// `file://` URL, anything else (an icon name, per spec) gives `""`.
pub(crate) fn resolve_image(image_path: &str) -> String {
    let p = image_path.trim();
    if p.starts_with('/') {
        let mut url = String::with_capacity(p.len() + 7);
        url.push_str("file://");
        for b in p.bytes() {
            if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
                url.push(char::from(b));
            } else {
                url.push_str(&format!("%{b:02X}"));
            }
        }
        url
    } else if p.contains("://") {
        p.to_owned()
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hints_defaults_and_loose_types() {
        assert_eq!(
            parse_hints(&HashMap::new()),
            Hints {
                urgency: 1,
                ..Hints::default()
            }
        );
        let mut h: HashMap<&str, Value<'_>> = HashMap::new();
        h.insert("urgency", Value::U8(2));
        h.insert("transient", Value::Bool(true));
        h.insert("resident", Value::I32(1));
        h.insert("desktop-entry", Value::from("org.mozilla.firefox.desktop"));
        h.insert("image_path", Value::from("/tmp/a.png"));
        h.insert("image-data", Value::U32(7));
        let p = parse_hints(&h);
        assert_eq!(
            p,
            Hints {
                urgency: 2,
                transient: true,
                resident: true,
                desktop_entry: "org.mozilla.firefox".into(),
                image_path: "/tmp/a.png".into(),
            }
        );
        h.insert("urgency", Value::I32(0));
        h.insert("transient", Value::Bool(false));
        h.insert("image-path", Value::from("file:///b.png"));
        let p = parse_hints(&h);
        assert_eq!((p.urgency, p.transient), (0, false));
        assert_eq!(p.image_path, "file:///b.png", "image-path wins");
        h.insert("urgency", Value::U32(77));
        assert_eq!(parse_hints(&h).urgency, 2);
        h.insert("urgency", Value::from("high"));
        assert_eq!(parse_hints(&h).urgency, 1);
    }

    #[test]
    fn actions_icon_image() {
        assert_eq!(
            parse_actions(&["default", "Open", "x", "Close", "dangling"]),
            [
                ("default".to_owned(), "Open".to_owned()),
                ("x".to_owned(), "Close".to_owned())
            ]
        );
        assert_eq!(resolve_icon("firefox", "ff", "Firefox"), "firefox");
        assert_eq!(
            resolve_icon("", "org.gnome.Nautilus", "Files"),
            "org.gnome.Nautilus"
        );
        assert_eq!(
            resolve_icon(" ", "", "Telegram Desktop"),
            "telegram desktop"
        );
        assert_eq!(
            resolve_icon("/usr/share/a.png", "x", "y"),
            "/usr/share/a.png"
        );
        assert_eq!(resolve_icon("file:///a.png", "x", "y"), "file:///a.png");

        assert_eq!(
            resolve_image("/tmp/My Shot#1.png"),
            "file:///tmp/My%20Shot%231.png"
        );
        assert_eq!(resolve_image("file:///tmp/a.png"), "file:///tmp/a.png");
        assert_eq!(resolve_image("https://x/y.png"), "https://x/y.png");
        assert_eq!(resolve_image("dialog-information"), "");
        assert_eq!(resolve_image(""), "");
    }
}
