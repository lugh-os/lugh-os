//! Pure core of `Services.media`: the known MPRIS players, which one is the
//! active one, and the state and patches the UI gets. No D-Bus here.

use std::time::Instant;

use serde_json::{Map, Value, json};

/// Bus name prefix of every MPRIS player.
pub(crate) const PREFIX: &str = "org.mpris.MediaPlayer2.";

/// Whether `name` is a player we show (playerctld only mirrors the others).
pub(crate) fn is_player_name(name: &str) -> bool {
    name.strip_prefix(PREFIX)
        .is_some_and(|rest| !rest.is_empty() && rest != "playerctld")
}

/// A readable name from a bus name, until the player tells its `Identity`:
/// `org.mpris.MediaPlayer2.firefox.instance_1_84` → `Firefox`.
fn name_from_bus(bus: &str) -> String {
    let short = bus.strip_prefix(PREFIX).unwrap_or(bus);
    let short = short.split('.').next().unwrap_or(short);
    let mut chars = short.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Cover art the UI can load: local files and web URLs; anything else
/// (inline `data:`, relative paths) is dropped.
pub(crate) fn art_url(raw: &str) -> String {
    let raw = raw.trim();
    if ["file://", "https://", "http://"]
        .iter()
        .any(|scheme| raw.starts_with(scheme))
    {
        raw.to_owned()
    } else {
        String::new()
    }
}

/// The track a player reports (`Metadata`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Track {
    /// `mpris:trackid`.
    pub(crate) id: String,
    pub(crate) title: String,
    /// `xesam:artist`, joined.
    pub(crate) artist: String,
    pub(crate) art_url: String,
    /// `mpris:length` in microseconds; ≤ 0 when unknown.
    pub(crate) length_us: i64,
}

impl Track {
    fn same_track(&self, other: &Self) -> bool {
        self.id == other.id && self.title == other.title && self.artist == other.artist
    }
}

/// What a player just told us; `None` = not mentioned.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Update {
    pub(crate) identity: Option<String>,
    /// `PlaybackStatus == "Playing"`.
    pub(crate) playing: Option<bool>,
    pub(crate) track: Option<Track>,
    /// `Position` in microseconds.
    pub(crate) position_us: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Player {
    bus: String,
    /// Unique name of the owner (signals come from it).
    owner: String,
    identity: String,
    playing: bool,
    track: Track,
    position_us: i64,
    /// False until the player answered or signalled once.
    known: bool,
    /// Order stamps: when it last started playing / last changed.
    played_at: u64,
    changed_at: u64,
}

/// All players on the bus.
#[derive(Debug, Default)]
pub(crate) struct Players {
    list: Vec<Player>,
    clock: u64,
}

impl Players {
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }

    /// A player appeared, or its name changed hands.
    pub(crate) fn add(&mut self, bus: &str, owner: &str) {
        self.remove(bus);
        self.list.push(Player {
            bus: bus.to_owned(),
            owner: owner.to_owned(),
            identity: name_from_bus(bus),
            playing: false,
            track: Track::default(),
            position_us: 0,
            known: false,
            played_at: 0,
            changed_at: 0,
        });
    }

    pub(crate) fn remove(&mut self, bus: &str) {
        self.list.retain(|p| p.bus != bus);
    }

    pub(crate) fn clear(&mut self) {
        self.list.clear();
    }

    /// The bus name owned by the unique name `owner`.
    pub(crate) fn bus_of(&self, owner: &str) -> Option<&str> {
        self.list
            .iter()
            .find(|p| p.owner == owner)
            .map(|p| p.bus.as_str())
    }

    /// Applies what a player said. Returns true when its position must be
    /// asked for: the track changed or playback started or paused, and the
    /// update did not carry a position itself.
    pub(crate) fn update(&mut self, bus: &str, update: Update) -> bool {
        let stamp = self.tick();
        let Some(p) = self.list.iter_mut().find(|p| p.bus == bus) else {
            return false;
        };
        p.known = true;
        let mut moved = false;
        if let Some(identity) = update.identity.filter(|s| !s.trim().is_empty()) {
            p.identity = identity;
        }
        if let Some(playing) = update.playing
            && playing != p.playing
        {
            p.playing = playing;
            p.changed_at = stamp;
            if playing {
                p.played_at = stamp;
            }
            moved = true;
        }
        if let Some(track) = update.track {
            if !p.track.same_track(&track) {
                p.changed_at = stamp;
                p.position_us = 0;
                moved = true;
            }
            p.track = track;
        }
        match update.position_us {
            Some(us) => {
                p.position_us = us;
                false
            }
            None => moved,
        }
    }

    fn active_player(&self) -> Option<&Player> {
        // Playing beats paused; among playing the latest to start, among
        // paused the latest to change.
        self.list.iter().filter(|p| p.known).max_by_key(|p| {
            (
                p.playing,
                if p.playing { p.played_at } else { p.changed_at },
            )
        })
    }

    /// Bus name of the active player.
    pub(crate) fn active(&self) -> Option<&str> {
        self.active_player().map(|p| p.bus.as_str())
    }

    /// The state the players reduce to.
    pub(crate) fn state(&self) -> MediaState {
        let Some(p) = self.active_player() else {
            return MediaState::default();
        };
        #[allow(clippy::cast_precision_loss)]
        let position = if p.track.length_us > 0 {
            let ratio = p.position_us as f64 / p.track.length_us as f64;
            (ratio.clamp(0.0, 1.0) * 10_000.0).round() / 10_000.0
        } else {
            0.0
        };
        MediaState {
            has_player: true,
            player: p.identity.clone(),
            title: p.track.title.clone(),
            artist: p.track.artist.clone(),
            art_url: p.track.art_url.clone(),
            playing: p.playing,
            position,
        }
    }
}

/// The state of `Services.media`, as the UI holds it.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct MediaState {
    pub(crate) has_player: bool,
    pub(crate) player: String,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) art_url: String,
    pub(crate) playing: bool,
    /// 0..1.
    pub(crate) position: f64,
}

impl MediaState {
    /// Full state with the QML property names.
    pub(crate) fn to_json(&self) -> Value {
        json!({
            "hasPlayer": self.has_player,
            "player": self.player,
            "title": self.title,
            "artist": self.artist,
            "artUrl": self.art_url,
            "playing": self.playing,
            "position": self.position,
        })
    }

    /// The keys of `new` that differ from `self`.
    pub(crate) fn diff(&self, new: &Self) -> Map<String, Value> {
        let mut d = Map::new();
        if self.has_player != new.has_player {
            d.insert("hasPlayer".into(), json!(new.has_player));
        }
        if self.player != new.player {
            d.insert("player".into(), json!(new.player));
        }
        if self.title != new.title {
            d.insert("title".into(), json!(new.title));
        }
        if self.artist != new.artist {
            d.insert("artist".into(), json!(new.artist));
        }
        if self.art_url != new.art_url {
            d.insert("artUrl".into(), json!(new.art_url));
        }
        if self.playing != new.playing {
            d.insert("playing".into(), json!(new.playing));
        }
        if (self.position - new.position).abs() >= 0.000_05 {
            d.insert("position".into(), json!(new.position));
        }
        d
    }
}

/// The players, what the UI shows, and the short hold on `playing` after the
/// UI toggled it itself.
#[derive(Debug, Default)]
pub(crate) struct View {
    pub(crate) players: Players,
    pub(crate) shown: MediaState,
    playing_held_until: Option<Instant>,
}

impl View {
    /// Brings `shown` up to the players and returns the patch for the UI.
    pub(crate) fn reconcile(&mut self, now: Instant) -> Map<String, Value> {
        let mut next = self.players.state();
        if self.playing_held_until.is_some_and(|until| until > now) {
            next.playing = self.shown.playing;
        } else {
            self.playing_held_until = None;
        }
        let patch = self.shown.diff(&next);
        self.shown = next;
        patch
    }

    /// The UI flipped `playing` itself: show that until `until`, then the
    /// truth.
    pub(crate) fn ui_toggled_playing(&mut self, until: Instant) {
        self.shown.playing = !self.shown.playing;
        self.playing_held_until = Some(until);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    const VLC: &str = "org.mpris.MediaPlayer2.vlc";
    const FIREFOX: &str = "org.mpris.MediaPlayer2.firefox.instance_1_84";

    fn track(id: &str, title: &str, length_us: i64) -> Track {
        Track {
            id: id.into(),
            title: title.into(),
            artist: "Meddy".into(),
            art_url: String::new(),
            length_us,
        }
    }

    fn playing(on: bool) -> Update {
        Update {
            playing: Some(on),
            ..Update::default()
        }
    }

    #[test]
    fn player_names() {
        assert!(is_player_name(VLC));
        assert!(is_player_name(FIREFOX));
        assert!(!is_player_name("org.mpris.MediaPlayer2.playerctld"));
        assert!(!is_player_name("org.mpris.MediaPlayer2."));
        assert!(!is_player_name("org.freedesktop.Notifications"));
        assert_eq!(name_from_bus(FIREFOX), "Firefox");
        assert_eq!(name_from_bus(VLC), "Vlc");
    }

    #[test]
    fn art_urls() {
        assert_eq!(art_url("file:///tmp/cover.png"), "file:///tmp/cover.png");
        assert_eq!(
            art_url(" https://i.scdn.co/image/ab67 "),
            "https://i.scdn.co/image/ab67"
        );
        assert_eq!(art_url("data:image/png;base64,AAAA"), "");
        assert_eq!(art_url("cover.png"), "");
        assert_eq!(art_url(""), "");
    }

    #[test]
    fn no_player_is_an_empty_state() {
        let mut players = Players::default();
        assert_eq!(players.state(), MediaState::default());
        assert_eq!(players.active(), None);
        // A name that has not answered yet does not count.
        players.add(VLC, ":1.50");
        assert!(!players.state().has_player);
        assert_eq!(players.state().to_json()["hasPlayer"], false);
    }

    #[test]
    fn the_latest_playing_player_wins_then_the_latest_changed() {
        let mut players = Players::default();
        players.add(VLC, ":1.50");
        players.add(FIREFOX, ":1.60");
        players.update(VLC, playing(true));
        assert_eq!(players.active(), Some(VLC));
        players.update(FIREFOX, playing(true));
        assert_eq!(players.active(), Some(FIREFOX));

        // Metadata churn in the older one does not steal the focus.
        players.update(
            VLC,
            Update {
                track: Some(track("/1", "Slowly", 1)),
                ..Update::default()
            },
        );
        assert_eq!(players.active(), Some(FIREFOX));

        // Firefox pauses: VLC is the only one playing.
        players.update(FIREFOX, playing(false));
        assert_eq!(players.active(), Some(VLC));

        // Both paused: the one paused last stays on screen.
        players.update(VLC, playing(false));
        assert_eq!(players.active(), Some(VLC));
        players.update(FIREFOX, playing(true));
        players.update(FIREFOX, playing(false));
        assert_eq!(players.active(), Some(FIREFOX));

        players.remove(FIREFOX);
        assert_eq!(players.active(), Some(VLC));
        assert_eq!(players.bus_of(":1.50"), Some(VLC));
        assert_eq!(players.bus_of(":1.60"), None);
        players.clear();
        assert!(!players.state().has_player);
    }

    #[test]
    fn position_is_asked_for_on_track_and_play_changes_only() {
        let mut players = Players::default();
        players.add(VLC, ":1.50");
        // First answer carries its own position: nothing more to ask.
        let loaded = Update {
            identity: Some("VLC media player".into()),
            playing: Some(true),
            track: Some(track("/1", "Umuhanzi w'Ijuru", 200_000_000)),
            position_us: Some(68_000_000),
        };
        assert!(!players.update(VLC, loaded));
        let s = players.state();
        assert_eq!(
            (s.player.as_str(), s.title.as_str(), s.playing),
            ("VLC media player", "Umuhanzi w'Ijuru", true)
        );
        assert!((s.position - 0.34).abs() < 1e-9);

        // Same track again (art arrived late): no question, no reset.
        let mut same = track("/1", "Umuhanzi w'Ijuru", 200_000_000);
        same.art_url = "file:///tmp/a.png".into();
        assert!(!players.update(
            VLC,
            Update {
                track: Some(same),
                ..Update::default()
            }
        ));
        assert!((players.state().position - 0.34).abs() < 1e-9);
        assert_eq!(players.state().art_url, "file:///tmp/a.png");

        // Pause, same status repeated, next track.
        assert!(players.update(VLC, playing(false)));
        assert!(!players.update(VLC, playing(false)));
        assert!(players.update(
            VLC,
            Update {
                track: Some(track("/2", "Slowly", 180_000_000)),
                ..Update::default()
            }
        ));
        assert!(players.state().position.abs() < 1e-9); // new track starts at 0

        // Seeked / answer to the question.
        assert!(!players.update(
            VLC,
            Update {
                position_us: Some(90_000_000),
                ..Update::default()
            }
        ));
        assert!((players.state().position - 0.5).abs() < 1e-9);

        // Unknown length or a position past the end stay inside 0..1.
        players.update(
            VLC,
            Update {
                position_us: Some(999_000_000),
                ..Update::default()
            },
        );
        assert!((players.state().position - 1.0).abs() < 1e-9);
        players.update(
            VLC,
            Update {
                track: Some(track("/3", "Stream", 0)),
                position_us: Some(5),
                ..Update::default()
            },
        );
        assert!(players.state().position.abs() < 1e-9);
        // An unknown player is ignored.
        assert!(!players.update("org.mpris.MediaPlayer2.nope", playing(true)));
    }

    #[test]
    fn patches_carry_only_changed_keys() {
        let mut view = View::default();
        let now = Instant::now();
        assert!(view.reconcile(now).is_empty());

        view.players.add(VLC, ":1.50");
        view.players.update(
            VLC,
            Update {
                identity: Some("VLC".into()),
                playing: Some(true),
                track: Some(track("/1", "Slowly", 100)),
                position_us: Some(25),
            },
        );
        let first = Value::Object(view.reconcile(now));
        assert_eq!(
            first,
            json!({
                "hasPlayer": true, "player": "VLC", "title": "Slowly",
                "artist": "Meddy", "playing": true, "position": 0.25,
            })
        );
        assert!(view.reconcile(now).is_empty());

        view.players.update(VLC, playing(false));
        assert_eq!(
            Value::Object(view.reconcile(now)),
            json!({ "playing": false })
        );

        view.players.remove(VLC);
        let gone = view.reconcile(now);
        assert_eq!(gone["hasPlayer"], false);
        assert_eq!(gone["title"], "");
        assert!(!gone.contains_key("playing")); // already false
        assert_eq!(view.shown, MediaState::default());
    }

    #[test]
    fn a_toggle_by_the_ui_is_held_then_corrected() {
        let t0 = Instant::now();
        let ms = Duration::from_millis;
        let mut view = View::default();
        view.players.add(VLC, ":1.50");
        view.players.update(VLC, playing(true));
        view.reconcile(t0);

        // The UI pauses; the player has not reacted when its art changes.
        view.ui_toggled_playing(t0 + ms(250));
        assert!(!view.shown.playing);
        assert!(view.reconcile(t0 + ms(40)).is_empty());

        // The player follows: nothing to patch.
        view.players.update(VLC, playing(false));
        assert!(view.reconcile(t0 + ms(80)).is_empty());

        // A player that ignores the toggle is corrected after the hold.
        view.ui_toggled_playing(t0 + ms(350));
        assert!(view.shown.playing);
        assert!(view.reconcile(t0 + ms(200)).is_empty());
        assert_eq!(
            Value::Object(view.reconcile(t0 + ms(350))),
            json!({ "playing": false })
        );
    }
}
