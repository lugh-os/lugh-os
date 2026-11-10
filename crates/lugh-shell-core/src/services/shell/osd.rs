//! `ShowOSD(s kind, d value)` → `Services.osd.requested(kind, value)`.
//!
//! The compositor's media-key script (`ui/shell/hypr/scripts/media-key.sh`)
//! and other callers name kinds after the key; the QML OSD knows six kinds.
//!
//! | D-Bus kind (aliases)                          | QML kind     | value            |
//! |-----------------------------------------------|--------------|------------------|
//! | `volume`                                      | `volume`     | as sent (0–1.5)  |
//! | `volume-muted`, `mute`, `muted`               | `volume`     | `0`              |
//! | `microphone`, `mic`                           | `mic`        | as sent (1 live / 0 muted) |
//! | `microphone-muted`, `mic-muted`               | `mic`        | `0`              |
//! | `brightness`                                  | `brightness` | as sent (0–1)    |
//! | `kbd-brightness`, `keyboard-brightness`       | `brightness` | as sent (0–1)    |
//! | `caps-lock`, `caps`, `capslock`               | `caps`       | 1 on / 0 off     |
//! | `layout`, `keyboard-layout`                   | `layout`     | as sent (ignored by the UI) |
//! | `airplane`, `airplane-mode`                   | `airplane`   | 1 on / 0 off     |
//!
//! Kinds compare case-insensitively, `_` counts as `-`. An unknown kind is
//! dropped (logged), never an error: a key press must not fail. A value that
//! is not finite becomes `0`; values are clamped to `0..=1.5`.

/// Maps a D-Bus OSD request onto the QML kind and value.
pub(crate) fn map(kind: &str, value: f64) -> Option<(&'static str, f64)> {
    let value = if value.is_finite() {
        value.clamp(0.0, 1.5)
    } else {
        0.0
    };
    let kind = kind.trim().to_ascii_lowercase().replace('_', "-");
    Some(match kind.as_str() {
        "volume" => ("volume", value),
        "volume-muted" | "mute" | "muted" => ("volume", 0.0),
        "microphone" | "mic" => ("mic", value),
        "microphone-muted" | "mic-muted" => ("mic", 0.0),
        "brightness" | "kbd-brightness" | "keyboard-brightness" => ("brightness", value),
        "caps-lock" | "caps" | "capslock" => ("caps", value),
        "layout" | "keyboard-layout" => ("layout", value),
        "airplane" | "airplane-mode" => ("airplane", value),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::map;

    #[test]
    fn maps_the_kinds_the_media_keys_send() {
        assert_eq!(map("volume", 0.4), Some(("volume", 0.4)));
        assert_eq!(map("volume-muted", 0.4), Some(("volume", 0.0)));
        assert_eq!(map("microphone", 1.0), Some(("mic", 1.0)));
        assert_eq!(map("microphone", 0.0), Some(("mic", 0.0)));
        assert_eq!(map("brightness", 0.75), Some(("brightness", 0.75)));
        assert_eq!(map("kbd-brightness", 0.5), Some(("brightness", 0.5)));
        assert_eq!(map("caps-lock", 1.0), Some(("caps", 1.0)));
    }

    #[test]
    fn aliases_qml_kinds_and_bad_input() {
        for k in ["volume", "brightness", "mic", "caps", "layout", "airplane"] {
            assert_eq!(map(k, 1.0), Some((k, 1.0)), "QML kind {k} passes through");
        }
        assert_eq!(map(" Caps_Lock ", 1.0), Some(("caps", 1.0)));
        assert_eq!(map("mic-muted", 1.0), Some(("mic", 0.0)));
        assert_eq!(map("airplane-mode", 1.0), Some(("airplane", 1.0)));
        assert_eq!(map("volume", 9.0), Some(("volume", 1.5)));
        assert_eq!(map("volume", -1.0), Some(("volume", 0.0)));
        assert_eq!(map("volume", f64::NAN), Some(("volume", 0.0)));
        assert_eq!(map("disco", 1.0), None);
        assert_eq!(map("", 1.0), None);
    }
}
