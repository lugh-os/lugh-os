//! Pure core of `Services.audio`: `pactl` JSON parsing, name and icon mapping,
//! volume math, the state the UI sees, its diff, and echo suppression. No I/O
//! and no clock of its own (callers pass `Instant`s), so all of it is unit
//! tested against output captured from a real PipeWire machine.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Map, Value, json};

/// PulseAudio's 100 % (`PA_VOLUME_NORM`).
const VOLUME_NORM: f64 = 65536.0;
/// Two volumes closer than this are the same step for the UI (pactl works in
/// whole percents).
const VOLUME_EPSILON: f64 = 0.005;
/// How long a value we just wrote is kept from being patched back.
pub(crate) const ECHO_HOLD: Duration = Duration::from_millis(250);

// ---- parsed entities ---------------------------------------------------------

/// One output (sink) or input (source).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Device {
    /// The pactl name; the UI's `devId`.
    pub(crate) id: String,
    /// Human name.
    pub(crate) name: String,
    /// Lucide icon name.
    pub(crate) icon: &'static str,
    /// 0..1.
    pub(crate) volume: f64,
    pub(crate) muted: bool,
}

/// One playback stream of an application (sink input).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Stream {
    pub(crate) id: i64,
    pub(crate) name: String,
    /// Freedesktop icon name.
    pub(crate) icon: String,
    pub(crate) volume: f64,
    pub(crate) muted: bool,
}

/// The server's default devices (pactl names; empty when unknown).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Defaults {
    pub(crate) sink: String,
    pub(crate) source: String,
}

/// What a `pactl subscribe` event invalidates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Class {
    Sinks,
    Sources,
    Streams,
    Server,
}

/// A set of [`Class`]es.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Dirty(u8);

impl Dirty {
    pub(crate) const ALL: Self = Self(0b1111);

    const fn bit(class: Class) -> u8 {
        match class {
            Class::Sinks => 1,
            Class::Sources => 2,
            Class::Streams => 4,
            Class::Server => 8,
        }
    }
    pub(crate) fn of(classes: &[Class]) -> Self {
        Self(classes.iter().fold(0, |acc, c| acc | Self::bit(*c)))
    }
    pub(crate) fn add(&mut self, other: Self) {
        self.0 |= other.0;
    }
    pub(crate) fn is_empty(self) -> bool {
        self.0 == 0
    }
    pub(crate) fn classes(self) -> impl Iterator<Item = Class> {
        [Class::Sinks, Class::Sources, Class::Streams, Class::Server]
            .into_iter()
            .filter(move |c| self.0 & Self::bit(*c) != 0)
    }
}

/// One freshly read class.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ClassData {
    Sinks(Vec<Device>),
    Sources(Vec<Device>),
    Streams(Vec<Stream>),
    Server(Defaults),
}

// ---- pactl JSON ----------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct RawChannel {
    #[serde(default)]
    value: Option<f64>,
    #[serde(default)]
    value_percent: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawPort {
    #[serde(default)]
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default, rename = "type")]
    kind: String,
}

#[derive(Debug, Deserialize)]
struct RawDevice {
    #[serde(default)]
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    mute: bool,
    #[serde(default)]
    volume: BTreeMap<String, RawChannel>,
    #[serde(default)]
    properties: BTreeMap<String, Value>,
    #[serde(default)]
    ports: Vec<RawPort>,
    #[serde(default)]
    active_port: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawStream {
    index: i64,
    #[serde(default)]
    mute: bool,
    #[serde(default)]
    volume: BTreeMap<String, RawChannel>,
    #[serde(default)]
    properties: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize)]
struct RawInfo {
    #[serde(default)]
    default_sink_name: String,
    #[serde(default)]
    default_source_name: String,
}

fn prop<'a>(props: &'a BTreeMap<String, Value>, key: &str) -> &'a str {
    props.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// Average channel volume as 0..1, in whole percents (150 % shows as 1).
fn average_volume(channels: &BTreeMap<String, RawChannel>) -> f64 {
    let values: Vec<f64> = channels
        .values()
        .filter_map(|c| {
            c.value.map(|v| v / VOLUME_NORM).or_else(|| {
                let pct = c.value_percent.as_deref()?.trim().trim_end_matches('%');
                pct.trim().parse::<f64>().ok().map(|p| p / 100.0)
            })
        })
        .collect();
    if values.is_empty() {
        return 0.0;
    }
    #[allow(clippy::cast_precision_loss)]
    let avg = values.iter().sum::<f64>() / values.len() as f64;
    round_percent(avg)
}

/// Clamps to 0..1 and rounds to a whole percent.
pub(crate) fn round_percent(v: f64) -> f64 {
    if v.is_nan() {
        return 0.0;
    }
    (v.clamp(0.0, 1.0) * 100.0).round() / 100.0
}

/// Whole percent for `pactl set-*-volume N%`.
pub(crate) fn percent(v: f64) -> u32 {
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let p = (round_percent(v) * 100.0).round() as u32;
    p
}

/// Parses `pactl --format=json list sinks`.
pub(crate) fn parse_sinks(json: &str) -> Result<Vec<Device>, serde_json::Error> {
    let raw: Vec<RawDevice> = serde_json::from_str(json)?;
    Ok(raw.iter().map(|d| device(d, false)).collect())
}

/// Parses `pactl --format=json list sources`, without monitor sources.
pub(crate) fn parse_sources(json: &str) -> Result<Vec<Device>, serde_json::Error> {
    let raw: Vec<RawDevice> = serde_json::from_str(json)?;
    Ok(raw
        .iter()
        .filter(|d| {
            prop(&d.properties, "device.class") != "monitor" && !d.name.ends_with(".monitor")
        })
        .map(|d| device(d, true))
        .collect())
}

/// Parses `pactl --format=json list sink-inputs`, without event sounds and
/// the speech-dispatcher keep-alive stream.
pub(crate) fn parse_streams(json: &str) -> Result<Vec<Stream>, serde_json::Error> {
    let raw: Vec<RawStream> = serde_json::from_str(json)?;
    Ok(raw.iter().filter_map(stream).collect())
}

/// Parses `pactl --format=json info`.
pub(crate) fn parse_info(json: &str) -> Result<Defaults, serde_json::Error> {
    let raw: RawInfo = serde_json::from_str(json)?;
    Ok(Defaults {
        sink: raw.default_sink_name,
        source: raw.default_source_name,
    })
}

fn device(d: &RawDevice, input: bool) -> Device {
    let port = d
        .active_port
        .as_deref()
        .and_then(|name| d.ports.iter().find(|p| p.name == name));
    Device {
        id: d.name.clone(),
        name: device_name(d, port, input),
        icon: device_icon(d, port, input),
        volume: average_volume(&d.volume),
        muted: d.mute,
    }
}

fn is_bluetooth(d: &RawDevice) -> bool {
    d.name.starts_with("bluez_")
        || prop(&d.properties, "device.api").starts_with("bluez")
        || prop(&d.properties, "device.bus") == "bluetooth"
}

fn device_icon(d: &RawDevice, port: Option<&RawPort>, input: bool) -> &'static str {
    let form = prop(&d.properties, "device.form_factor");
    if input {
        return if is_bluetooth(d) { "headphones" } else { "mic" };
    }
    let port_text = port
        .map(|p| format!("{} {}", p.kind, p.name).to_ascii_lowercase())
        .unwrap_or_default();
    let name = d.name.to_ascii_lowercase();
    let profile = prop(&d.properties, "device.profile.name").to_ascii_lowercase();
    if port_text.contains("headphone")
        || port_text.contains("headset")
        || matches!(form, "headset" | "headphone" | "hands-free")
    {
        "headphones"
    } else if matches!(form, "speaker" | "portable") {
        "speaker"
    } else if is_bluetooth(d) {
        "headphones"
    } else if ["hdmi", "displayport"]
        .iter()
        .any(|k| port_text.contains(k) || name.contains(k) || profile.contains(k))
    {
        "monitor"
    } else {
        "speaker"
    }
}

/// Profile words PulseAudio appends to a card name.
const PROFILE_SUFFIXES: [&str; 10] = [
    " Analog Stereo",
    " Analog Mono",
    " Digital Stereo (HDMI)",
    " Digital Stereo (IEC958)",
    " Digital Stereo",
    " Analog Surround 5.1",
    " Analog Surround 7.1",
    " Stereo",
    " Mono",
    " Pro",
];
/// Company boilerplate that says nothing about the device.
const VENDOR_NOISE: [&str; 9] = [
    " Co., Ltd.",
    ", Inc.",
    " Inc.",
    ", Ltd.",
    " Ltd.",
    " Corporation",
    " Corp.",
    "(R)",
    "(TM)",
];

fn clean_description(d: &RawDevice) -> String {
    let mut s = d.description.trim().to_owned();
    if s.is_empty() {
        s = prop(&d.properties, "device.description").trim().to_owned();
    }
    let profile = prop(&d.properties, "device.profile.description");
    if !profile.is_empty() && s.len() > profile.len() && s.ends_with(profile) {
        s.truncate(s.len() - profile.len());
    } else if let Some(suffix) = PROFILE_SUFFIXES
        .iter()
        .find(|x| s.len() > x.len() && s.ends_with(**x))
    {
        s.truncate(s.len() - suffix.len());
    }
    for noise in VENDOR_NOISE {
        s = s.replace(noise, "");
    }
    let s = s.replace('_', " ");
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.is_empty() { d.name.clone() } else { s }
}

fn device_name(d: &RawDevice, port: Option<&RawPort>, input: bool) -> String {
    let base = clean_description(d);
    let internal = prop(&d.properties, "device.form_factor") == "internal"
        || base.eq_ignore_ascii_case("Built-in Audio");
    match port {
        Some(p) if internal && !p.description.trim().is_empty() => {
            let desc = p.description.trim();
            let built_in_mic = input
                && (p.name.contains("internal-mic")
                    || desc.starts_with("Internal")
                    || desc.starts_with("Digital"));
            if built_in_mic {
                "Built-in microphone".to_owned()
            } else {
                desc.to_owned()
            }
        }
        _ => base,
    }
}

fn stream(s: &RawStream) -> Option<Stream> {
    let p = &s.properties;
    if prop(p, "media.role") == "event" {
        return None;
    }
    let binary = prop(p, "application.process.binary");
    let app = prop(p, "application.name");
    if binary == "sd_dummy" || app.starts_with("speech-dispatcher") {
        return None;
    }
    let name = [app, prop(p, "media.name"), binary, prop(p, "node.name")]
        .into_iter()
        .find(|s| !s.trim().is_empty())
        .unwrap_or("Application")
        .trim()
        .to_owned();
    Some(Stream {
        id: s.index,
        name,
        icon: stream_icon(p),
        volume: average_volume(&s.volume),
        muted: s.mute,
    })
}

/// Binaries whose icon name is not their lowercase name.
const ICON_ALIASES: [(&str, &str); 9] = [
    ("chrome", "google-chrome"),
    ("chromium-browser", "chromium"),
    ("telegram-desktop", "org.telegram.desktop"),
    ("totem", "org.gnome.Totem"),
    ("rhythmbox", "org.gnome.Rhythmbox"),
    ("code", "vscode"),
    ("pw-play", "audio-x-generic"),
    ("pw-cat", "audio-x-generic"),
    ("paplay", "audio-x-generic"),
];

fn stream_icon(p: &BTreeMap<String, Value>) -> String {
    let explicit = prop(p, "application.icon_name");
    if !explicit.is_empty() {
        return explicit.to_owned();
    }
    // A desktop id is the best guess for a themed icon.
    for key in ["application.id", "pipewire.access.portal.app_id"] {
        let id = prop(p, key);
        if !id.is_empty() {
            return id.trim_end_matches(".desktop").to_owned();
        }
    }
    let app = prop(p, "application.name").to_ascii_lowercase();
    let binary = prop(p, "application.process.binary").to_ascii_lowercase();
    // Chromium reports the binary `chrome`; trust its application name.
    if app == "chromium" {
        return app;
    }
    if let Some((_, icon)) = ICON_ALIASES.iter().find(|(b, _)| *b == binary) {
        return (*icon).to_owned();
    }
    let guess = if binary.is_empty() { app } else { binary };
    let guess: String = guess
        .chars()
        .map(|c| if c.is_whitespace() { '-' } else { c })
        .collect();
    if guess.is_empty() {
        "audio-x-generic".to_owned()
    } else {
        guess
    }
}

// ---- state ---------------------------------------------------------------------

/// A row of `outputs` / `inputs`.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DeviceRow {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) icon: &'static str,
    pub(crate) active: bool,
}

/// The state of `Services.audio`, as the UI holds it.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct AudioState {
    pub(crate) volume: f64,
    pub(crate) muted: bool,
    pub(crate) mic_volume: f64,
    pub(crate) mic_muted: bool,
    pub(crate) outputs: Vec<DeviceRow>,
    pub(crate) inputs: Vec<DeviceRow>,
    pub(crate) streams: Vec<Stream>,
}

fn same_volume(a: f64, b: f64) -> bool {
    (a - b).abs() < VOLUME_EPSILON
}

fn same_streams(a: &[Stream], b: &[Stream]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| {
            x.id == y.id
                && x.name == y.name
                && x.icon == y.icon
                && x.muted == y.muted
                && same_volume(x.volume, y.volume)
        })
}

fn rows_json(rows: &[DeviceRow]) -> Value {
    rows.iter()
        .map(|r| json!({ "devId": r.id, "name": r.name, "icon": r.icon, "active": r.active }))
        .collect()
}

fn streams_json(streams: &[Stream]) -> Value {
    streams
        .iter()
        .map(|s| {
            json!({
                "streamId": s.id, "name": s.name, "icon": s.icon,
                "volume": s.volume, "muted": s.muted,
            })
        })
        .collect()
}

impl AudioState {
    /// Full state with the QML property names.
    pub(crate) fn to_json(&self) -> Value {
        json!({
            "volume": self.volume,
            "muted": self.muted,
            "micVolume": self.mic_volume,
            "micMuted": self.mic_muted,
            "outputs": rows_json(&self.outputs),
            "inputs": rows_json(&self.inputs),
            "streams": streams_json(&self.streams),
        })
    }

    /// The keys of `new` that differ from `self` (arrays whole).
    pub(crate) fn diff(&self, new: &Self) -> Map<String, Value> {
        let mut d = Map::new();
        if !same_volume(self.volume, new.volume) {
            d.insert("volume".into(), json!(new.volume));
        }
        if self.muted != new.muted {
            d.insert("muted".into(), json!(new.muted));
        }
        if !same_volume(self.mic_volume, new.mic_volume) {
            d.insert("micVolume".into(), json!(new.mic_volume));
        }
        if self.mic_muted != new.mic_muted {
            d.insert("micMuted".into(), json!(new.mic_muted));
        }
        if self.outputs != new.outputs {
            d.insert("outputs".into(), rows_json(&new.outputs));
        }
        if self.inputs != new.inputs {
            d.insert("inputs".into(), rows_json(&new.inputs));
        }
        if !same_streams(&self.streams, &new.streams) {
            d.insert("streams".into(), streams_json(&new.streams));
        }
        d
    }
}

/// What the sound server says, class by class.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Model {
    sinks: Vec<Device>,
    sources: Vec<Device>,
    streams: Vec<Stream>,
    defaults: Defaults,
}

impl Model {
    /// Replaces one class with a fresh read.
    pub(crate) fn apply(&mut self, data: ClassData) {
        match data {
            ClassData::Sinks(v) => self.sinks = v,
            ClassData::Sources(v) => self.sources = v,
            ClassData::Streams(v) => self.streams = v,
            ClassData::Server(v) => self.defaults = v,
        }
    }

    /// Forgets everything (server gone).
    pub(crate) fn clear(&mut self) {
        *self = Self::default();
    }

    pub(crate) fn has_sink(&self, id: &str) -> bool {
        self.sinks.iter().any(|d| d.id == id)
    }
    pub(crate) fn has_source(&self, id: &str) -> bool {
        self.sources.iter().any(|d| d.id == id)
    }
    pub(crate) fn has_stream(&self, id: i64) -> bool {
        self.streams.iter().any(|s| s.id == id)
    }

    /// The state this model reduces to.
    pub(crate) fn state(&self) -> AudioState {
        let rows = |devices: &[Device], default: &str| -> Vec<DeviceRow> {
            devices
                .iter()
                .map(|d| DeviceRow {
                    id: d.id.clone(),
                    name: d.name.clone(),
                    icon: d.icon,
                    active: d.id == default,
                })
                .collect()
        };
        let sink = self.sinks.iter().find(|d| d.id == self.defaults.sink);
        let source = self.sources.iter().find(|d| d.id == self.defaults.source);
        AudioState {
            volume: sink.map_or(0.0, |d| d.volume),
            muted: sink.is_some_and(|d| d.muted),
            mic_volume: source.map_or(0.0, |d| d.volume),
            mic_muted: source.is_some_and(|d| d.muted),
            outputs: rows(&self.sinks, &self.defaults.sink),
            inputs: rows(&self.sources, &self.defaults.source),
            streams: self.streams.clone(),
        }
    }
}

// ---- echo suppression ----------------------------------------------------------

/// A value the UI set itself and must not get patched back mid-drag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Held {
    Volume,
    Muted,
    MicVolume,
    MicMuted,
    StreamVolume(i64),
    StreamMuted(i64),
}

/// The values currently protected from echoes, each until its deadline.
#[derive(Debug, Clone, Default)]
pub(crate) struct Holds(Vec<(Held, Instant)>);

impl Holds {
    /// Protects `key` for [`ECHO_HOLD`] from `now` (restarts a running hold).
    pub(crate) fn hold(&mut self, key: Held, now: Instant) {
        let until = now + ECHO_HOLD;
        match self.0.iter_mut().find(|(k, _)| *k == key) {
            Some(entry) => entry.1 = until,
            None => self.0.push((key, until)),
        }
    }
    /// Drops expired holds.
    pub(crate) fn expire(&mut self, now: Instant) {
        self.0.retain(|(_, until)| *until > now);
    }
    pub(crate) fn is_held(&self, key: Held, now: Instant) -> bool {
        self.0.iter().any(|(k, until)| *k == key && *until > now)
    }
    /// When the next hold ends (the moment to confirm the real value).
    pub(crate) fn next_expiry(&self) -> Option<Instant> {
        self.0.iter().map(|(_, until)| *until).min()
    }
}

/// `actual` with every held value replaced by what the UI already shows.
pub(crate) fn overlay(
    mut actual: AudioState,
    shown: &AudioState,
    holds: &Holds,
    now: Instant,
) -> AudioState {
    if holds.is_held(Held::Volume, now) {
        actual.volume = shown.volume;
    }
    if holds.is_held(Held::Muted, now) {
        actual.muted = shown.muted;
    }
    if holds.is_held(Held::MicVolume, now) {
        actual.mic_volume = shown.mic_volume;
    }
    if holds.is_held(Held::MicMuted, now) {
        actual.mic_muted = shown.mic_muted;
    }
    for s in &mut actual.streams {
        let Some(old) = shown.streams.iter().find(|o| o.id == s.id) else {
            continue;
        };
        if holds.is_held(Held::StreamVolume(s.id), now) {
            s.volume = old.volume;
        }
        if holds.is_held(Held::StreamMuted(s.id), now) {
            s.muted = old.muted;
        }
    }
    actual
}

/// The UI-facing half of the service: the server model, what the UI shows,
/// and the holds between them.
#[derive(Debug, Default)]
pub(crate) struct View {
    pub(crate) model: Model,
    pub(crate) shown: AudioState,
    pub(crate) holds: Holds,
}

impl View {
    /// Brings `shown` up to the model (minus held values) and returns the
    /// patch for the UI; empty when nothing visible changed.
    pub(crate) fn reconcile(&mut self, now: Instant) -> Map<String, Value> {
        self.holds.expire(now);
        let next = overlay(self.model.state(), &self.shown, &self.holds, now);
        let patch = self.shown.diff(&next);
        self.shown = next;
        patch
    }

    /// Records a value the UI set optimistically and protects it.
    pub(crate) fn ui_set(&mut self, key: Held, now: Instant, set: impl FnOnce(&mut AudioState)) {
        set(&mut self.shown);
        self.holds.hold(key, now);
    }
}

// ---- subscribe events and writes -------------------------------------------------

/// What a `pactl subscribe` line (`Event 'change' on sink #53`) invalidates.
/// Client events are ignored on purpose: every `pactl` we run is a client.
pub(crate) fn parse_event(line: &str) -> Dirty {
    let Some((_, rest)) = line.split_once(" on ") else {
        return Dirty::default();
    };
    let facility = rest.split('#').next().unwrap_or_default().trim();
    match facility {
        "sink" => Dirty::of(&[Class::Sinks]),
        "source" => Dirty::of(&[Class::Sources]),
        "sink-input" => Dirty::of(&[Class::Streams]),
        "server" => Dirty::of(&[Class::Server]),
        // Profile and port changes move devices around.
        "card" => Dirty::of(&[Class::Sinks, Class::Sources]),
        _ => Dirty::default(),
    }
}

/// A change to make on the sound server.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Write {
    Volume(f64),
    Muted(bool),
    MicVolume(f64),
    MicMuted(bool),
    Output(String),
    Input(String),
    StreamVolume(i64, f64),
    StreamMuted(i64, bool),
}

/// Writes with the same slot replace each other while they wait.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Slot {
    Volume,
    Muted,
    MicVolume,
    MicMuted,
    Output,
    Input,
    StreamVolume(i64),
    StreamMuted(i64),
}

impl Write {
    pub(crate) fn slot(&self) -> Slot {
        match self {
            Self::Volume(_) => Slot::Volume,
            Self::Muted(_) => Slot::Muted,
            Self::MicVolume(_) => Slot::MicVolume,
            Self::MicMuted(_) => Slot::MicMuted,
            Self::Output(_) => Slot::Output,
            Self::Input(_) => Slot::Input,
            Self::StreamVolume(id, _) => Slot::StreamVolume(*id),
            Self::StreamMuted(id, _) => Slot::StreamMuted(*id),
        }
    }

    /// The `pactl` arguments for this write.
    pub(crate) fn pactl_args(&self) -> Vec<String> {
        let flag = |on: bool| if on { "1" } else { "0" }.to_owned();
        let pct = |v: f64| format!("{}%", percent(v));
        let (verb, target, value) = match self {
            Self::Volume(v) => ("set-sink-volume", "@DEFAULT_SINK@".to_owned(), pct(*v)),
            Self::Muted(m) => ("set-sink-mute", "@DEFAULT_SINK@".to_owned(), flag(*m)),
            Self::MicVolume(v) => ("set-source-volume", "@DEFAULT_SOURCE@".to_owned(), pct(*v)),
            Self::MicMuted(m) => ("set-source-mute", "@DEFAULT_SOURCE@".to_owned(), flag(*m)),
            Self::Output(id) => return vec!["set-default-sink".to_owned(), id.clone()],
            Self::Input(id) => return vec!["set-default-source".to_owned(), id.clone()],
            Self::StreamVolume(id, v) => ("set-sink-input-volume", id.to_string(), pct(*v)),
            Self::StreamMuted(id, m) => ("set-sink-input-mute", id.to_string(), flag(*m)),
        };
        vec![verb.to_owned(), target, value]
    }
}

/// Writes waiting for the writer: one per slot, the last value wins, the
/// order of first arrival is kept.
#[derive(Debug, Default)]
pub(crate) struct Pending(Vec<Write>);

impl Pending {
    pub(crate) fn push(&mut self, write: Write) {
        let slot = write.slot();
        match self.0.iter_mut().find(|w| w.slot() == slot) {
            Some(w) => *w = write,
            None => self.0.push(write),
        }
    }
    pub(crate) fn take(&mut self) -> Vec<Write> {
        std::mem::take(&mut self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SINKS: &str = include_str!("fixtures/sinks.json");
    const SOURCES: &str = include_str!("fixtures/sources.json");
    const STREAMS: &str = include_str!("fixtures/sink-inputs.json");
    const INFO: &str = include_str!("fixtures/info.json");

    const BT_SINK: &str = "bluez_output.AA_BB_CC_DD_EE_FF.1";
    const BT_SOURCE: &str = "bluez_input.AA_BB_CC_DD_EE_FF";
    const ALSA_SINK: &str = "alsa_output.pci-0000_00_1f.3.analog-stereo";

    fn model() -> Model {
        let mut m = Model::default();
        m.apply(ClassData::Sinks(parse_sinks(SINKS).unwrap_or_default()));
        m.apply(ClassData::Sources(
            parse_sources(SOURCES).unwrap_or_default(),
        ));
        m.apply(ClassData::Streams(
            parse_streams(STREAMS).unwrap_or_default(),
        ));
        m.apply(ClassData::Server(parse_info(INFO).unwrap_or_default()));
        m
    }

    #[test]
    fn sinks_from_a_real_machine() {
        let sinks = parse_sinks(SINKS).unwrap_or_default();
        let brief: Vec<_> = sinks
            .iter()
            .map(|d| (d.id.as_str(), d.name.as_str(), d.icon, d.volume, d.muted))
            .collect();
        assert_eq!(
            brief,
            vec![
                ("phone_mic", "Phone Mic", "speaker", 1.0, false),
                (ALSA_SINK, "Speakers", "speaker", 0.0, true),
                (BT_SINK, "BT", "headphones", 0.42, false),
            ]
        );
    }

    #[test]
    fn sources_skip_monitors() {
        let sources = parse_sources(SOURCES).unwrap_or_default();
        let brief: Vec<_> = sources
            .iter()
            .map(|d| (d.id.as_str(), d.name.as_str(), d.icon))
            .collect();
        assert_eq!(
            brief,
            vec![
                (
                    "alsa_input.pci-0000_00_1f.3.analog-stereo",
                    "Built-in microphone",
                    "mic"
                ),
                (BT_SOURCE, "BT", "headphones"),
            ]
        );
    }

    #[test]
    fn streams_skip_event_sounds_and_speech_dispatcher() {
        let streams = parse_streams(STREAMS).unwrap_or_default();
        assert_eq!(
            streams,
            vec![
                Stream {
                    id: 57,
                    name: "Firefox".into(),
                    icon: "firefox".into(),
                    volume: 0.8,
                    muted: false
                },
                Stream {
                    id: 63,
                    name: "Chromium".into(),
                    icon: "chromium".into(),
                    volume: 1.0,
                    muted: true
                },
            ]
        );
    }

    #[test]
    fn bad_json_is_an_error_not_a_panic() {
        assert!(parse_sinks("Connection failure: Connection refused").is_err());
        assert!(parse_streams("[{\"mute\":true}]").is_err());
        assert_eq!(parse_sinks("[]").unwrap_or_default(), vec![]);
        assert_eq!(parse_info("{}").unwrap_or_default(), Defaults::default());
    }

    fn raw_device(json: Value) -> RawDevice {
        serde_json::from_value(json).unwrap_or_else(|e| panic!("fixture: {e}"))
    }

    fn named(json: Value, input: bool) -> (String, &'static str) {
        let d = raw_device(json);
        let dev = device(&d, input);
        (dev.name, dev.icon)
    }

    #[test]
    fn names_and_icons() {
        assert_eq!(
            named(
                json!({
                    "name": "alsa_output.pci-0000_00_1f.3.hdmi-stereo",
                    "description": "Built-in Audio Digital Stereo (HDMI)",
                    "properties": { "device.form_factor": "internal",
                        "device.profile.description": "Digital Stereo (HDMI)" },
                    "ports": [{ "name": "hdmi-output-0", "description": "HDMI / DisplayPort", "type": "HDMI" }],
                    "active_port": "hdmi-output-0",
                }),
                false
            ),
            ("HDMI / DisplayPort".to_owned(), "monitor")
        );
        assert_eq!(
            named(
                json!({
                    "name": "alsa_output.pci-0000_00_1f.3.analog-stereo",
                    "description": "Built-in Audio Analog Stereo",
                    "properties": { "device.form_factor": "internal" },
                    "ports": [{ "name": "analog-output-headphones", "description": "Headphones", "type": "Headphones" }],
                    "active_port": "analog-output-headphones",
                }),
                false
            ),
            ("Headphones".to_owned(), "headphones")
        );
        assert_eq!(
            named(
                json!({
                    "name": "alsa_output.usb-Logitech_Inc._Z407-00.analog-stereo",
                    "description": "Logitech, Inc. Z407 Analog Stereo",
                    "properties": { "device.bus": "usb" },
                    "ports": [{ "name": "analog-output", "description": "Analog Output", "type": "Analog" }],
                    "active_port": "analog-output",
                }),
                false
            ),
            ("Logitech Z407".to_owned(), "speaker")
        );
        assert_eq!(
            named(
                json!({
                    "name": "bluez_output.11_22.1", "description": "JBL Flip 6",
                    "properties": { "device.form_factor": "speaker" },
                }),
                false
            ),
            ("JBL Flip 6".to_owned(), "speaker")
        );
        assert_eq!(
            named(
                json!({
                    "name": "alsa_input.usb-Blue_Yeti-00.analog-stereo",
                    "description": "Blue Yeti Analog Stereo",
                    "properties": { "device.bus": "usb" },
                }),
                true
            ),
            ("Blue Yeti".to_owned(), "mic")
        );
        // Nothing left after cleaning: fall back to the pactl name.
        assert_eq!(
            named(json!({ "name": "null", "description": "" }), false).0,
            "null"
        );
    }

    #[test]
    fn stream_icon_guesses() {
        let icon = |props: Value| {
            let map: BTreeMap<String, Value> = serde_json::from_value(props).unwrap_or_default();
            stream_icon(&map)
        };
        assert_eq!(
            icon(json!({ "application.icon_name": "vlc", "application.process.binary": "x" })),
            "vlc"
        );
        assert_eq!(
            icon(
                json!({ "application.name": "Google Chrome", "application.process.binary": "chrome" })
            ),
            "google-chrome"
        );
        assert_eq!(
            icon(json!({ "application.name": "Spotify", "application.process.binary": "spotify" })),
            "spotify"
        );
        assert_eq!(
            icon(json!({ "application.id": "org.gnome.Music.desktop" })),
            "org.gnome.Music"
        );
        assert_eq!(
            icon(json!({ "application.name": "My Player" })),
            "my-player"
        );
        assert_eq!(icon(json!({})), "audio-x-generic");
    }

    #[test]
    fn volume_math() {
        let vol = |json: Value| {
            let ch: BTreeMap<String, RawChannel> = serde_json::from_value(json).unwrap_or_default();
            average_volume(&ch)
        };
        assert!(same_volume(
            vol(json!({ "l": { "value": 27525 }, "r": { "value": 27525 } })),
            0.42
        ));
        // Unbalanced channels average; over-amplification shows as full.
        assert!(same_volume(
            vol(json!({ "l": { "value": 65536 }, "r": { "value": 32768 } })),
            0.75
        ));
        assert!(same_volume(
            vol(json!({ "l": { "value": 98304 }, "r": { "value": 98304 } })),
            1.0
        ));
        assert!(same_volume(
            vol(json!({ "mono": { "value_percent": " 37% " } })),
            0.37
        ));
        assert!(same_volume(vol(json!({})), 0.0));
        assert_eq!(percent(0.404), 40);
        assert_eq!(percent(1.7), 100);
        assert_eq!(percent(-1.0), 0);
        assert_eq!(percent(f64::NAN), 0);
    }

    #[test]
    fn state_follows_the_default_devices() {
        let s = model().state();
        assert!(same_volume(s.volume, 0.42));
        assert!(!s.muted);
        assert!(same_volume(s.mic_volume, 1.0));
        let active: Vec<_> = s
            .outputs
            .iter()
            .filter(|r| r.active)
            .map(|r| &r.id)
            .collect();
        assert_eq!(active, vec![BT_SINK]);
        assert!(s.inputs.iter().any(|r| r.active && r.id == BT_SOURCE));

        let json = s.to_json();
        assert_eq!(json["outputs"][2]["devId"], BT_SINK);
        assert_eq!(json["outputs"][2]["active"], true);
        assert!(json["streams"][0]["streamId"].is_i64());
        assert_eq!(
            json.as_object()
                .map(|o| o.keys().cloned().collect::<Vec<_>>()),
            Some(
                [
                    "inputs",
                    "micMuted",
                    "micVolume",
                    "muted",
                    "outputs",
                    "streams",
                    "volume"
                ]
                .map(String::from)
                .to_vec()
            )
        );
    }

    #[test]
    fn switching_the_default_patches_only_what_changed() {
        let mut m = model();
        let before = m.state();
        m.apply(ClassData::Server(Defaults {
            sink: ALSA_SINK.into(),
            source: BT_SOURCE.into(),
        }));
        let patch = before.diff(&m.state());
        let mut keys: Vec<_> = patch.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, vec!["muted", "outputs", "volume"]);
        assert_eq!(patch["volume"], 0.0);
        assert_eq!(patch["muted"], true);
        assert!(before.diff(&before).is_empty());
    }

    #[test]
    fn a_dead_server_reduces_to_empty() {
        let mut m = model();
        m.clear();
        let s = m.state();
        assert_eq!(s, AudioState::default());
        assert_eq!(s.to_json()["outputs"], json!([]));
        assert_eq!(s.to_json()["volume"], 0.0);
    }

    fn set_sink_volume(view: &mut View, id: &str, volume: f64) {
        let mut sinks = view.model.sinks.clone();
        for d in &mut sinks {
            if d.id == id {
                d.volume = volume;
            }
        }
        view.model.apply(ClassData::Sinks(sinks));
    }

    #[test]
    fn own_volume_change_is_not_echoed_during_a_drag() {
        let t0 = Instant::now();
        let ms = Duration::from_millis;
        let mut view = View {
            model: model(),
            ..View::default()
        };
        assert!(!view.reconcile(t0).is_empty()); // first state

        // The UI drags to 0.437; the server reports the lagging 0.43, 0.44.
        view.ui_set(Held::Volume, t0, |s| s.volume = 0.437);
        set_sink_volume(&mut view, BT_SINK, 0.43);
        assert!(view.reconcile(t0 + ms(60)).is_empty());
        view.ui_set(Held::Volume, t0 + ms(100), |s| s.volume = 0.5);
        set_sink_volume(&mut view, BT_SINK, 0.44);
        assert!(view.reconcile(t0 + ms(300)).is_empty()); // hold restarted at 100
        assert_eq!(view.holds.next_expiry(), Some(t0 + ms(100) + ECHO_HOLD));

        // Hold over, the write landed: nothing to say.
        set_sink_volume(&mut view, BT_SINK, 0.5);
        assert!(view.reconcile(t0 + ms(351)).is_empty());
        assert_eq!(view.holds.next_expiry(), None);

        // Somebody else changes it: patched at once.
        set_sink_volume(&mut view, BT_SINK, 0.3);
        let patch = view.reconcile(t0 + ms(400));
        assert_eq!(Value::Object(patch), json!({ "volume": 0.3 }));
    }

    #[test]
    fn a_write_that_did_not_land_is_corrected_after_the_hold() {
        let t0 = Instant::now();
        let mut view = View {
            model: model(),
            ..View::default()
        };
        view.reconcile(t0);
        view.ui_set(Held::Muted, t0, |s| s.muted = true);
        view.ui_set(Held::Volume, t0, |s| s.volume = 0.9);
        assert!(view.reconcile(t0 + Duration::from_millis(249)).is_empty());
        let patch = view.reconcile(t0 + ECHO_HOLD);
        assert_eq!(
            Value::Object(patch),
            json!({ "volume": 0.42, "muted": false })
        );
    }

    #[test]
    fn stream_holds_cover_one_stream_only() {
        let t0 = Instant::now();
        let mut view = View {
            model: model(),
            ..View::default()
        };
        view.reconcile(t0);
        view.ui_set(Held::StreamVolume(57), t0, |s| s.streams[0].volume = 0.2);
        let mut streams = view.model.streams.clone();
        streams[0].volume = 0.25; // echo of our own write, still moving
        view.model.apply(ClassData::Streams(streams.clone()));
        assert!(view.reconcile(t0 + Duration::from_millis(50)).is_empty());

        streams[1].muted = false; // the other stream changes meanwhile
        view.model.apply(ClassData::Streams(streams));
        let patch = view.reconcile(t0 + Duration::from_millis(80));
        assert_eq!(patch["streams"][0]["volume"], 0.2);
        assert_eq!(patch["streams"][1]["muted"], false);

        // A stream that ended drops out even while held.
        view.model.apply(ClassData::Streams(vec![]));
        let patch = view.reconcile(t0 + Duration::from_millis(90));
        assert_eq!(patch["streams"], json!([]));
    }

    #[test]
    fn subscribe_lines() {
        assert_eq!(
            parse_event("Event 'change' on sink #19478"),
            Dirty::of(&[Class::Sinks])
        );
        assert_eq!(
            parse_event("Event 'new' on sink-input #412"),
            Dirty::of(&[Class::Streams])
        );
        assert_eq!(
            parse_event("Event 'change' on source #7"),
            Dirty::of(&[Class::Sources])
        );
        assert_eq!(
            parse_event("Event 'change' on server #4294967295"),
            Dirty::of(&[Class::Server])
        );
        assert_eq!(
            parse_event("Event 'change' on card #43"),
            Dirty::of(&[Class::Sinks, Class::Sources])
        );
        // Our own pactl runs show up as clients: they must not wake a re-read.
        assert!(parse_event("Event 'new' on client #20125").is_empty());
        assert!(parse_event("Event 'remove' on source-output #3").is_empty());
        assert!(parse_event("Got SIGINT, exiting.").is_empty());

        let mut dirty = Dirty::default();
        dirty.add(parse_event("Event 'change' on sink #1"));
        dirty.add(parse_event("Event 'change' on server #1"));
        assert_eq!(
            dirty.classes().collect::<Vec<_>>(),
            vec![Class::Sinks, Class::Server]
        );
        assert_eq!(Dirty::ALL.classes().count(), 4);
    }

    #[test]
    fn writes_become_pactl_arguments() {
        let args = |w: Write| w.pactl_args().join(" ");
        assert_eq!(
            args(Write::Volume(0.404)),
            "set-sink-volume @DEFAULT_SINK@ 40%"
        );
        assert_eq!(
            args(Write::Volume(3.0)),
            "set-sink-volume @DEFAULT_SINK@ 100%"
        );
        assert_eq!(args(Write::Muted(true)), "set-sink-mute @DEFAULT_SINK@ 1");
        assert_eq!(
            args(Write::MicVolume(0.0)),
            "set-source-volume @DEFAULT_SOURCE@ 0%"
        );
        assert_eq!(
            args(Write::MicMuted(false)),
            "set-source-mute @DEFAULT_SOURCE@ 0"
        );
        assert_eq!(args(Write::Output("a.b".into())), "set-default-sink a.b");
        assert_eq!(args(Write::Input("c".into())), "set-default-source c");
        assert_eq!(
            args(Write::StreamVolume(57, 0.5)),
            "set-sink-input-volume 57 50%"
        );
        assert_eq!(
            args(Write::StreamMuted(57, true)),
            "set-sink-input-mute 57 1"
        );
    }

    #[test]
    fn pending_writes_coalesce_per_slot() {
        let mut p = Pending::default();
        p.push(Write::Volume(0.1));
        p.push(Write::StreamVolume(57, 0.3));
        p.push(Write::Volume(0.2));
        p.push(Write::StreamVolume(63, 0.9));
        p.push(Write::Volume(0.3));
        assert_eq!(
            p.take(),
            vec![
                Write::Volume(0.3),
                Write::StreamVolume(57, 0.3),
                Write::StreamVolume(63, 0.9)
            ]
        );
        assert!(p.take().is_empty());
    }
}
