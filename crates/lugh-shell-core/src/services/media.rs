//! `Services.media` — the active MPRIS player on the session bus.
//!
//! Players are found with `ListNames` and followed with `NameOwnerChanged`;
//! their `PropertiesChanged` and `Seeked` signals drive everything, so nothing
//! runs while nothing changes. `position` is sent only when the track changes,
//! on a seek and when playback starts or pauses: never as a ticking patch.
//!
//! [`model`] is the pure, unit-tested core (player selection, state, diff);
//! this file is the D-Bus half.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use zbus::zvariant::{self, OwnedValue};
use zbus::{Connection, MatchRule, MessageStream};

use super::{CallError, Context, Service, Sink};
use model::{Track, Update, View};

mod model;

const NAME: &str = "media";
const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";
const ROOT_IFACE: &str = "org.mpris.MediaPlayer2";
const PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";
const PROPS_IFACE: &str = "org.freedesktop.DBus.Properties";
const DBUS: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";
/// A player that does not answer within this is left alone.
const CALL_TIMEOUT: Duration = Duration::from_secs(3);
/// How long the UI's own play/pause toggle is shown before the truth.
const TOGGLE_HOLD: Duration = Duration::from_millis(250);
/// When the player's status is read back after a toggle.
const TOGGLE_CONFIRM: Duration = Duration::from_millis(300);
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let inner = Arc::new(Inner {
        sink: ctx.sink.clone(),
        view: Mutex::default(),
        bus: Mutex::default(),
    });
    let task = ctx.runtime.spawn(watch(Arc::clone(&inner)));
    Box::new(MediaService {
        inner,
        runtime: ctx.runtime.clone(),
        task,
    })
}

/// The live connection and the way back into the watcher.
#[derive(Debug, Clone)]
struct Bus {
    conn: Connection,
    answers: mpsc::UnboundedSender<Answer>,
}

/// What a background D-Bus call found out about a player.
#[derive(Debug)]
struct Answer {
    bus: String,
    update: Update,
}

#[derive(Debug)]
struct Inner {
    sink: Sink,
    view: Mutex<View>,
    bus: Mutex<Option<Bus>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Inner {
    fn publish(&self) {
        let patch = lock(&self.view).reconcile(Instant::now());
        if !patch.is_empty() {
            self.sink.patch(NAME, Value::Object(patch));
        }
    }
}

#[derive(Debug)]
struct MediaService {
    inner: Arc<Inner>,
    runtime: tokio::runtime::Handle,
    task: JoinHandle<()>,
}

impl Drop for MediaService {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Service for MediaService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        lock(&self.inner.view).shown.to_json()
    }

    fn call(&self, method: &str, _args: &[Value]) -> Result<Value, CallError> {
        let member = match method {
            "playPause" => "PlayPause",
            "next" => "Next",
            "previous" => "Previous",
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        };
        let no_player = || CallError::Failed("no media player".to_owned());
        let bus = lock(&self.inner.bus).clone().ok_or_else(no_player)?;
        let player = {
            let mut view = lock(&self.inner.view);
            let player = view.players.active().ok_or_else(no_player)?.to_owned();
            if member == "PlayPause" {
                // The UI flipped its own `playing`; keep that until the
                // player had time to follow, then read the truth back.
                view.ui_toggled_playing(Instant::now() + TOGGLE_HOLD);
            }
            player
        };
        let inner = Arc::clone(&self.inner);
        self.runtime.spawn(async move {
            let done = call_player(&bus.conn, &player, PLAYER_IFACE, member, &()).await;
            if let Err(e) = done {
                tracing::debug!(%e, player, member, "media call failed");
            }
            if member == "PlayPause" {
                tokio::time::sleep(TOGGLE_CONFIRM).await;
                match get_property(&bus.conn, &player, "PlaybackStatus").await {
                    Some(status) => {
                        let update = Update {
                            playing: status_playing(&status),
                            ..Update::default()
                        };
                        let _ = bus.answers.send(Answer {
                            bus: player,
                            update,
                        });
                    }
                    None => inner.publish(),
                }
            }
        });
        Ok(Value::Null)
    }
}

// ---- D-Bus values --------------------------------------------------------------

fn text(v: &zvariant::Value<'_>) -> Option<String> {
    match v {
        zvariant::Value::Str(s) => Some(s.to_string()),
        zvariant::Value::ObjectPath(p) => Some(p.to_string()),
        zvariant::Value::Value(inner) => text(inner),
        _ => None,
    }
}

/// `xesam:artist` is a list of strings; some players send one string.
fn text_list(v: &zvariant::Value<'_>) -> Vec<String> {
    match v {
        zvariant::Value::Array(a) => a.inner().iter().filter_map(text).collect(),
        zvariant::Value::Value(inner) => text_list(inner),
        other => text(other).into_iter().collect(),
    }
}

/// `mpris:length` and `Position` are `x`, but players send every width.
fn integer(v: &zvariant::Value<'_>) -> Option<i64> {
    match v {
        zvariant::Value::I64(n) => Some(*n),
        zvariant::Value::U64(n) => i64::try_from(*n).ok(),
        zvariant::Value::I32(n) => Some(i64::from(*n)),
        zvariant::Value::U32(n) => Some(i64::from(*n)),
        zvariant::Value::I16(n) => Some(i64::from(*n)),
        zvariant::Value::U16(n) => Some(i64::from(*n)),
        zvariant::Value::U8(n) => Some(i64::from(*n)),
        #[allow(clippy::cast_possible_truncation)]
        zvariant::Value::F64(f) if f.is_finite() => Some(*f as i64),
        zvariant::Value::Value(inner) => integer(inner),
        _ => None,
    }
}

fn track(metadata: &zvariant::Value<'_>) -> Option<Track> {
    let dict = match metadata {
        zvariant::Value::Dict(d) => d,
        zvariant::Value::Value(inner) => return track(inner),
        _ => return None,
    };
    let mut t = Track::default();
    for (key, value) in dict.iter() {
        let zvariant::Value::Str(key) = key else {
            continue;
        };
        match key.as_str() {
            "mpris:trackid" => t.id = text(value).unwrap_or_default(),
            "xesam:title" => t.title = text(value).unwrap_or_default(),
            "xesam:artist" => t.artist = text_list(value).join(", "),
            "mpris:artUrl" => t.art_url = model::art_url(&text(value).unwrap_or_default()),
            "mpris:length" => t.length_us = integer(value).unwrap_or_default(),
            _ => {}
        }
    }
    Some(t)
}

fn status_playing(status: &zvariant::Value<'_>) -> Option<bool> {
    text(status).map(|s| s == "Playing")
}

/// The part of a `org.mpris.MediaPlayer2.Player` property map we use.
fn player_update(props: &HashMap<String, OwnedValue>) -> Update {
    Update {
        identity: None,
        playing: props.get("PlaybackStatus").and_then(|v| status_playing(v)),
        track: props.get("Metadata").and_then(|v| track(v)),
        position_us: props.get("Position").and_then(|v| integer(v)),
    }
}

// ---- D-Bus calls ---------------------------------------------------------------

async fn call_player<B>(
    conn: &Connection,
    dest: &str,
    iface: &str,
    member: &str,
    body: &B,
) -> zbus::Result<zbus::Message>
where
    B: serde::Serialize + zvariant::DynamicType + Sync,
{
    let call = conn.call_method(Some(dest), MPRIS_PATH, Some(iface), member, body);
    match tokio::time::timeout(CALL_TIMEOUT, call).await {
        Ok(reply) => reply,
        Err(_) => Err(zbus::Error::Failure(format!("{dest} did not answer"))),
    }
}

async fn get_property(conn: &Connection, dest: &str, property: &str) -> Option<OwnedValue> {
    let reply = call_player(conn, dest, PROPS_IFACE, "Get", &(PLAYER_IFACE, property))
        .await
        .ok()?;
    reply.body().deserialize::<OwnedValue>().ok()
}

/// Reads a player whole: identity, status, track and position.
async fn load(bus: Bus, player: String) {
    let props = match call_player(&bus.conn, &player, PROPS_IFACE, "GetAll", &(PLAYER_IFACE,)).await
    {
        Ok(reply) => reply
            .body()
            .deserialize::<HashMap<String, OwnedValue>>()
            .unwrap_or_default(),
        Err(e) => {
            tracing::debug!(%e, player, "media player did not answer");
            return;
        }
    };
    let mut update = player_update(&props);
    update.identity = call_player(
        &bus.conn,
        &player,
        PROPS_IFACE,
        "Get",
        &(ROOT_IFACE, "Identity"),
    )
    .await
    .ok()
    .and_then(|reply| reply.body().deserialize::<OwnedValue>().ok())
    .and_then(|v| text(&v));
    let _ = bus.answers.send(Answer {
        bus: player,
        update,
    });
}

/// Asks a player where it is in the track.
async fn load_position(bus: Bus, player: String) {
    if let Some(us) = get_property(&bus.conn, &player, "Position")
        .await
        .and_then(|v| integer(&v))
    {
        let update = Update {
            position_us: Some(us),
            ..Update::default()
        };
        let _ = bus.answers.send(Answer {
            bus: player,
            update,
        });
    }
}

async fn signals(conn: &Connection, rule: MatchRule<'_>) -> zbus::Result<MessageStream> {
    MessageStream::for_match_rule(rule, conn, Some(64)).await
}

fn signal_rule() -> zbus::match_rule::Builder<'static> {
    MatchRule::builder().msg_type(zbus::message::Type::Signal)
}

// ---- the watcher ---------------------------------------------------------------

/// Keeps a session-bus connection, forever.
async fn watch(inner: Arc<Inner>) {
    let mut backoff = BACKOFF_MIN;
    loop {
        let started = Instant::now();
        let e = connected(&inner).await;
        tracing::debug!(%e, "session bus unavailable for media; retrying");
        *lock(&inner.bus) = None;
        lock(&inner.view).players.clear();
        inner.publish();
        if started.elapsed() >= BACKOFF_MAX {
            backoff = BACKOFF_MIN;
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// One connection: finds the players, then follows their signals until the
/// bus goes away. Returns why it ended.
async fn connected(inner: &Inner) -> zbus::Error {
    match follow(inner).await {
        Ok(()) => zbus::Error::Failure("session bus closed".to_owned()),
        Err(e) => e,
    }
}

async fn follow(inner: &Inner) -> zbus::Result<()> {
    let conn = Connection::session().await?;
    // Subscribe before listing, so no player is missed in between.
    let mut owners = signals(
        &conn,
        signal_rule()
            .sender(DBUS)?
            .interface(DBUS)?
            .member("NameOwnerChanged")?
            .arg0ns(ROOT_IFACE)?
            .build(),
    )
    .await?;
    let mut changes = signals(
        &conn,
        signal_rule()
            .interface(PROPS_IFACE)?
            .member("PropertiesChanged")?
            .path(MPRIS_PATH)?
            .arg(0, PLAYER_IFACE)?
            .build(),
    )
    .await?;
    let mut seeks = signals(
        &conn,
        signal_rule()
            .interface(PLAYER_IFACE)?
            .member("Seeked")?
            .path(MPRIS_PATH)?
            .build(),
    )
    .await?;

    let (answers, mut answered) = mpsc::unbounded_channel();
    let bus = Bus {
        conn: conn.clone(),
        answers,
    };
    *lock(&inner.bus) = Some(bus.clone());

    let names: Vec<String> = conn
        .call_method(Some(DBUS), DBUS_PATH, Some(DBUS), "ListNames", &())
        .await?
        .body()
        .deserialize()?;
    for name in names.into_iter().filter(|n| model::is_player_name(n)) {
        let owner = conn
            .call_method(Some(DBUS), DBUS_PATH, Some(DBUS), "GetNameOwner", &(&name,))
            .await
            .and_then(|reply| reply.body().deserialize::<String>());
        if let Ok(owner) = owner {
            lock(&inner.view).players.add(&name, &owner);
            tokio::spawn(load(bus.clone(), name));
        }
    }

    loop {
        tokio::select! {
            msg = owners.next() => {
                let Some(msg) = msg else { return Ok(()) };
                let Ok((name, _old, new)) = msg?.body().deserialize::<(String, String, String)>()
                else { continue };
                if !model::is_player_name(&name) {
                    continue;
                }
                if new.is_empty() {
                    lock(&inner.view).players.remove(&name);
                    inner.publish();
                } else {
                    lock(&inner.view).players.add(&name, &new);
                    tokio::spawn(load(bus.clone(), name));
                }
            }
            msg = changes.next() => {
                let Some(msg) = msg else { return Ok(()) };
                let msg = msg?;
                let Some(player) = sender_player(inner, &msg) else { continue };
                type Changed = (String, HashMap<String, OwnedValue>, Vec<String>);
                let Ok((_iface, changed, invalidated)) = msg.body().deserialize::<Changed>()
                else { continue };
                if invalidated.iter().any(|p| p == "Metadata" || p == "PlaybackStatus") {
                    tokio::spawn(load(bus.clone(), player.clone()));
                }
                let mut update = player_update(&changed);
                // Only an answer to our own question, or `Seeked`, moves the
                // position: a player announcing it must not tick the UI.
                update.position_us = None;
                if update != Update::default() {
                    apply(inner, &bus, player, update);
                }
            }
            msg = seeks.next() => {
                let Some(msg) = msg else { return Ok(()) };
                let msg = msg?;
                let Some(player) = sender_player(inner, &msg) else { continue };
                if let Ok(us) = msg.body().deserialize::<i64>() {
                    let update = Update { position_us: Some(us), ..Update::default() };
                    apply(inner, &bus, player, update);
                }
            }
            answer = answered.recv() => {
                // Cannot be `None`: `bus` holds a sender.
                if let Some(Answer { bus: player, update }) = answer {
                    apply(inner, &bus, player, update);
                }
            }
        }
    }
}

/// The player a signal came from (signals carry the unique name).
fn sender_player(inner: &Inner, msg: &zbus::Message) -> Option<String> {
    let header = msg.header();
    let sender = header.sender()?;
    lock(&inner.view)
        .players
        .bus_of(sender.as_str())
        .map(str::to_owned)
}

fn apply(inner: &Inner, bus: &Bus, player: String, update: Update) {
    let ask_position = lock(&inner.view).players.update(&player, update);
    inner.publish();
    if ask_position {
        tokio::spawn(load_position(bus.clone(), player));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zvariant::{Array, Dict, ObjectPath, Signature, Value as V};

    fn metadata(artist: V<'static>, length: V<'static>) -> V<'static> {
        let mut d = Dict::new(&Signature::Str, &Signature::Variant);
        let mut put = |k: &'static str, v: V<'static>| {
            assert!(d.append(V::from(k), V::Value(Box::new(v))).is_ok());
        };
        let id = ObjectPath::try_from("/org/mpris/MediaPlayer2/Track/7");
        put("mpris:trackid", id.map(V::from).unwrap_or(V::from("")));
        put("xesam:title", V::from("Umuhanzi w'Ijuru"));
        put("xesam:artist", artist);
        put("mpris:artUrl", V::from("file:///tmp/cover.png"));
        put("mpris:length", length);
        put("xesam:album", V::from("ignored"));
        V::Dict(d)
    }

    #[test]
    fn metadata_becomes_a_track() {
        let artists = Array::from(vec!["Meddy", "The Ben"]);
        let t = track(&metadata(V::Array(artists), V::I64(200_000_000)));
        assert_eq!(
            t,
            Some(Track {
                id: "/org/mpris/MediaPlayer2/Track/7".into(),
                title: "Umuhanzi w'Ijuru".into(),
                artist: "Meddy, The Ben".into(),
                art_url: "file:///tmp/cover.png".into(),
                length_us: 200_000_000,
            })
        );
        // Players that bend the spec: one artist as a string, length as u64.
        let t = track(&metadata(V::from("Meddy"), V::U64(5))).unwrap_or_default();
        assert_eq!((t.artist.as_str(), t.length_us), ("Meddy", 5));
        assert_eq!(track(&V::from("not a dict")), None);
    }

    #[test]
    fn property_maps_become_updates() {
        let mut props: HashMap<String, OwnedValue> = HashMap::new();
        let mut put = |k: &str, v: V<'static>| {
            if let Ok(v) = OwnedValue::try_from(v) {
                props.insert(k.to_owned(), v);
            }
        };
        put("PlaybackStatus", V::from("Paused"));
        put("Position", V::I64(42));
        put("Volume", V::F64(1.0));
        let update = player_update(&props);
        assert_eq!(update.playing, Some(false));
        assert_eq!(update.position_us, Some(42));
        assert_eq!(update.track, None);

        assert_eq!(status_playing(&V::from("Playing")), Some(true));
        assert_eq!(status_playing(&V::from("Stopped")), Some(false));
        assert_eq!(status_playing(&V::I64(1)), None);
        assert_eq!(player_update(&HashMap::new()), Update::default());
    }

    #[test]
    fn calls_without_a_player_fail_quietly() {
        let Ok(rt) = tokio::runtime::Builder::new_current_thread().build() else {
            return;
        };
        let svc = MediaService {
            inner: Arc::new(Inner {
                sink: Sink::new(|_| {}),
                view: Mutex::default(),
                bus: Mutex::default(),
            }),
            runtime: rt.handle().clone(),
            task: rt.spawn(async {}),
        };
        assert_eq!(svc.state()["hasPlayer"], false);
        assert_eq!(svc.state()["position"], 0.0);
        assert!(matches!(
            svc.call("playPause", &[]),
            Err(CallError::Failed(_))
        ));
        assert!(matches!(
            svc.call("stop", &[]),
            Err(CallError::UnknownMethod(_))
        ));
    }
}
