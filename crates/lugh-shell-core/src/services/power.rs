//! `Services.power` — battery (UPower `DisplayDevice`) and power profile
//! (power-profiles-daemon, new and legacy bus names).
//!
//! State: `hasBattery`, `batteryPercent` (int), `charging`, `timeRemaining`
//! (`"3 h 40 min"`, `"25 min"`, `""`), `profile`, `profiles` (`[]` when the
//! daemon is absent). Method: `setProfile(name)`.
//!
//! Signal-driven: `PropertiesChanged` and `NameOwnerChanged` only. The time
//! text is refreshed at most once a minute (UPower re-estimates it far more
//! often than anyone reads it).

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zbus::Connection;

use super::{CallError, Context, Service, args};

pub(super) mod bus;

use bus::{Props, Published};

const NAME: &str = "power";
const UPOWER: &str = "org.freedesktop.UPower";
const DISPLAY_DEVICE: &str = "/org/freedesktop/UPower/devices/DisplayDevice";
const DEVICE_IFACE: &str = "org.freedesktop.UPower.Device";
/// Profiles in the order the UI shows them.
const KNOWN_PROFILES: [&str; 3] = ["power-saver", "balanced", "performance"];
const TIME_TEXT_INTERVAL: Duration = Duration::from_secs(60);

/// One power-profiles-daemon flavour: (bus name, object path, interface).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Daemon {
    name: &'static str,
    path: &'static str,
}

/// Tried in order; the interface name equals the bus name for both.
const DAEMONS: [Daemon; 2] = [
    Daemon {
        name: "org.freedesktop.UPower.PowerProfiles",
        path: "/org/freedesktop/UPower/PowerProfiles",
    },
    Daemon {
        name: "net.hadess.PowerProfiles",
        path: "/net/hadess/PowerProfiles",
    },
];

// ---- pure core -------------------------------------------------------------

/// The UPower properties we read.
#[derive(Debug, Clone, Default, PartialEq)]
struct Battery {
    present: bool,
    kind: i64,
    percentage: f64,
    state: i64,
    time_to_empty: i64,
    time_to_full: i64,
}

const TYPE_BATTERY: i64 = 2;
const STATE_CHARGING: i64 = 1;
const STATE_DISCHARGING: i64 = 2;
const STATE_FULLY_CHARGED: i64 = 4;
const STATE_PENDING_CHARGE: i64 = 5;

impl Battery {
    fn from_props(p: &Props) -> Self {
        let int = |k: &str| p.get(k).and_then(bus::Prop::as_i64).unwrap_or(0);
        Self {
            present: p
                .get("IsPresent")
                .and_then(bus::Prop::as_bool)
                .unwrap_or(false),
            kind: int("Type"),
            percentage: p
                .get("Percentage")
                .and_then(bus::Prop::as_f64)
                .unwrap_or(0.0),
            state: int("State"),
            time_to_empty: int("TimeToEmpty"),
            time_to_full: int("TimeToFull"),
        }
    }
}

/// What the UI shows of the battery.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct BatteryView {
    has_battery: bool,
    percent: i64,
    charging: bool,
    time: String,
}

/// `"3 h 40 min"`, `"2 h"`, `"25 min"`; `""` when unknown (≤ 0).
fn format_duration(secs: i64) -> String {
    if secs <= 0 {
        return String::new();
    }
    let minutes = ((secs + 30) / 60).max(1);
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

fn battery_view(b: &Battery) -> BatteryView {
    let has_battery = b.present && b.kind == TYPE_BATTERY;
    if !has_battery {
        return BatteryView::default();
    }
    let time = match b.state {
        STATE_CHARGING => format_duration(b.time_to_full),
        STATE_DISCHARGING => format_duration(b.time_to_empty),
        _ => String::new(),
    };
    #[allow(clippy::cast_possible_truncation)]
    let percent = b.percentage.clamp(0.0, 100.0).round() as i64;
    BatteryView {
        has_battery,
        percent,
        charging: matches!(
            b.state,
            STATE_CHARGING | STATE_FULLY_CHARGED | STATE_PENDING_CHARGE
        ),
        time,
    }
}

/// Lets the time text change at most once per [`TIME_TEXT_INTERVAL`], except
/// when it appears, disappears or the charging direction flips.
#[derive(Debug, Default)]
struct Throttle {
    shown: BatteryView,
    time_set_at: Option<Instant>,
}

impl Throttle {
    fn reduce(&mut self, mut new: BatteryView, now: Instant) -> BatteryView {
        let urgent = new.has_battery != self.shown.has_battery
            || new.charging != self.shown.charging
            || new.time.is_empty()
            || self.shown.time.is_empty();
        let due = self
            .time_set_at
            .is_none_or(|t| now.duration_since(t) >= TIME_TEXT_INTERVAL);
        if new.time != self.shown.time {
            if urgent || due {
                self.time_set_at = Some(now);
            } else {
                new.time.clone_from(&self.shown.time);
            }
        }
        self.shown = new.clone();
        new
    }
}

/// Active profile and the daemon's list.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Profiles {
    active: String,
    list: Vec<String>,
}

impl Profiles {
    fn from_props(p: &Props) -> Self {
        Self {
            active: p
                .get("ActiveProfile")
                .and_then(bus::Prop::as_str)
                .unwrap_or_default()
                .to_owned(),
            list: match p.get("Profiles") {
                Some(bus::Prop::List(l)) => l.clone(),
                _ => Vec::new(),
            },
        }
    }
}

/// The daemon's profiles in UI order (unknown ones dropped).
fn ordered_profiles(list: &[String]) -> Vec<&'static str> {
    KNOWN_PROFILES
        .into_iter()
        .filter(|k| list.iter().any(|p| p == k))
        .collect()
}

fn profiles_view(p: Option<&Profiles>) -> Value {
    match p {
        Some(p) if !p.active.is_empty() => {
            json!({ "profile": p.active, "profiles": ordered_profiles(&p.list) })
        }
        _ => json!({ "profile": "balanced", "profiles": [] }),
    }
}

fn initial_state() -> Value {
    json!({
        "hasBattery": false,
        "batteryPercent": 0,
        "charging": false,
        "timeRemaining": "",
        "profile": "balanced",
        "profiles": [],
    })
}

// ---- I/O seam --------------------------------------------------------------

/// What the engine needs from the system. `None` = that daemon is absent.
trait PowerIo {
    async fn battery(&mut self) -> Option<Battery>;
    async fn profiles(&mut self) -> Option<Profiles>;
    async fn set_profile(&mut self, profile: &str) -> Result<(), String>;
}

#[derive(Debug)]
struct Engine<I> {
    io: I,
    throttle: Throttle,
    published: Arc<Published>,
}

impl<I: PowerIo> Engine<I> {
    fn new(io: I, published: Arc<Published>) -> Self {
        Self {
            io,
            throttle: Throttle::default(),
            published,
        }
    }

    async fn refresh_battery(&mut self, now: Instant) {
        let battery = self.io.battery().await.unwrap_or_default();
        let v = self.throttle.reduce(battery_view(&battery), now);
        self.published.publish(json!({
            "hasBattery": v.has_battery,
            "batteryPercent": v.percent,
            "charging": v.charging,
            "timeRemaining": v.time,
        }));
    }

    async fn refresh_profiles(&mut self) {
        let p = self.io.profiles().await;
        self.published.publish(profiles_view(p.as_ref()));
    }

    async fn set_profile(&mut self, profile: &str) {
        if let Err(e) = self.io.set_profile(profile).await {
            tracing::warn!(profile, %e, "could not set the power profile");
            // The UI switched optimistically: put it back.
            self.published.resend(&["profile"]);
        }
    }
}

#[derive(Debug)]
struct SysIo {
    conn: Connection,
    daemon: Option<Daemon>,
}

impl PowerIo for SysIo {
    async fn battery(&mut self) -> Option<Battery> {
        // UPower is bus-activated: asking starts it when installed.
        match bus::get_all(&self.conn, UPOWER, DISPLAY_DEVICE, DEVICE_IFACE).await {
            Ok(p) => Some(Battery::from_props(&p)),
            Err(e) => {
                tracing::debug!(%e, "UPower unavailable");
                None
            }
        }
    }

    async fn profiles(&mut self) -> Option<Profiles> {
        self.daemon = None;
        for d in DAEMONS {
            if !bus::has_owner(&self.conn, d.name).await {
                continue;
            }
            if let Ok(p) = bus::get_all(&self.conn, d.name, d.path, d.name).await {
                self.daemon = Some(d);
                return Some(Profiles::from_props(&p));
            }
        }
        None
    }

    async fn set_profile(&mut self, profile: &str) -> Result<(), String> {
        let d = self.daemon.ok_or("no power-profiles daemon")?;
        bus::set_prop(
            &self.conn,
            d.name,
            d.path,
            d.name,
            "ActiveProfile",
            profile.into(),
        )
        .await
        .map_err(|e| e.to_string())
    }
}

#[derive(Debug)]
enum Cmd {
    SetProfile(String),
}

/// One system-bus session. `Ok(())` = the service was dropped.
async fn session(
    rx: &mut mpsc::UnboundedReceiver<Cmd>,
    published: &Arc<Published>,
) -> zbus::Result<()> {
    let conn = Connection::system().await?;
    let mut rules = vec![
        bus::props_rule(UPOWER, DISPLAY_DEVICE, DEVICE_IFACE)?,
        bus::owner_rule(UPOWER)?,
    ];
    for d in DAEMONS {
        rules.push(bus::props_rule(d.name, d.path, d.name)?);
        rules.push(bus::owner_rule(d.name)?);
    }
    let mut stream = bus::signals(&conn, rules).await?;
    let mut engine = Engine::new(SysIo { conn, daemon: None }, Arc::clone(published));
    engine.refresh_battery(Instant::now()).await;
    engine.refresh_profiles().await;
    loop {
        tokio::select! {
            msg = stream.next() => {
                let Some(msg) = msg else {
                    return Err(zbus::Error::Failure("system bus closed".into()));
                };
                let msg = msg?;
                let about_battery = match bus::owner_change(&msg) {
                    Some((name, _, _)) => name == UPOWER,
                    None => msg.header().path().map(|p| p.as_str()) == Some(DISPLAY_DEVICE),
                };
                if about_battery {
                    engine.refresh_battery(Instant::now()).await;
                } else {
                    engine.refresh_profiles().await;
                }
            }
            cmd = rx.recv() => match cmd {
                Some(Cmd::SetProfile(p)) => engine.set_profile(&p).await,
                None => return Ok(()),
            },
        }
    }
}

async fn run(mut rx: mpsc::UnboundedReceiver<Cmd>, published: Arc<Published>) {
    let mut backoff = Duration::from_secs(1);
    loop {
        match session(&mut rx, &published).await {
            Ok(()) => return,
            Err(e) => tracing::warn!(%e, "power: system bus lost; retrying"),
        }
        published.publish(initial_state());
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(60));
        while let Ok(cmd) = rx.try_recv() {
            tracing::debug!(?cmd, "power: dropped while offline");
            published.resend(&["profile"]);
        }
    }
}

#[derive(Debug)]
struct Power {
    published: Arc<Published>,
    tx: mpsc::UnboundedSender<Cmd>,
}

impl Service for Power {
    fn name(&self) -> &'static str {
        NAME
    }
    fn state(&self) -> Value {
        self.published.state()
    }
    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        match method {
            "setProfile" => {
                let p = args::string(a, 0)?;
                if !KNOWN_PROFILES.contains(&p.as_str()) {
                    return Err(CallError::BadArgs(format!("unknown profile `{p}`")));
                }
                self.tx
                    .send(Cmd::SetProfile(p))
                    .map_err(|_| CallError::Failed("power service stopped".into()))?;
                Ok(Value::Null)
            }
            other => Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let published = Arc::new(Published::new(NAME, ctx.sink.clone(), initial_state()));
    let (tx, rx) = mpsc::unbounded_channel();
    ctx.runtime.spawn(run(rx, Arc::clone(&published)));
    Box::new(Power { published, tx })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::Sink;
    use std::sync::Mutex;

    fn battery(state: i64, pct: f64, tte: i64, ttf: i64) -> Battery {
        Battery {
            present: true,
            kind: TYPE_BATTERY,
            percentage: pct,
            state,
            time_to_empty: tte,
            time_to_full: ttf,
        }
    }

    #[test]
    fn formats_time_like_the_mock() {
        assert_eq!(format_duration(3 * 3600 + 40 * 60), "3 h 40 min");
        assert_eq!(format_duration(25 * 60), "25 min");
        assert_eq!(format_duration(2 * 3600), "2 h");
        assert_eq!(format_duration(3599), "1 h");
        assert_eq!(format_duration(20), "1 min");
        assert_eq!(format_duration(0), "");
        assert_eq!(format_duration(-5), "");
    }

    #[test]
    fn battery_view_maps_states() {
        let v = battery_view(&battery(STATE_DISCHARGING, 63.6, 13200, 0));
        assert_eq!(
            v,
            BatteryView {
                has_battery: true,
                percent: 64,
                charging: false,
                time: "3 h 40 min".into()
            }
        );
        let v = battery_view(&battery(STATE_CHARGING, 80.0, 0, 1500));
        assert!(v.charging);
        assert_eq!(v.time, "25 min");
        let v = battery_view(&battery(STATE_FULLY_CHARGED, 100.0, 0, 0));
        assert!(v.charging);
        assert_eq!(v.time, "");
        assert!(battery_view(&battery(STATE_PENDING_CHARGE, 79.0, 0, 0)).charging);
        // A line-powered desktop: UPower's DisplayDevice is not a battery.
        let mut desktop = battery(0, 0.0, 0, 0);
        desktop.present = false;
        assert_eq!(battery_view(&desktop), BatteryView::default());
        let mut ups = battery(STATE_DISCHARGING, 50.0, 600, 0);
        ups.kind = 3;
        assert!(!battery_view(&ups).has_battery);
    }

    #[test]
    fn reads_upower_properties() {
        let mut p = Props::new();
        p.insert("IsPresent".into(), bus::Prop::Bool(true));
        p.insert("Type".into(), bus::Prop::Int(2));
        p.insert("Percentage".into(), bus::Prop::Float(41.0));
        p.insert("State".into(), bus::Prop::Int(2));
        p.insert("TimeToEmpty".into(), bus::Prop::Int(600));
        assert_eq!(
            Battery::from_props(&p),
            battery(STATE_DISCHARGING, 41.0, 600, 0)
        );
        assert_eq!(Battery::from_props(&Props::new()), Battery::default());
    }

    #[test]
    fn time_text_changes_at_most_once_a_minute() {
        let t0 = Instant::now();
        let mut th = Throttle::default();
        let view = |pct: f64, tte: i64| battery_view(&battery(STATE_DISCHARGING, pct, tte, 0));
        assert_eq!(th.reduce(view(64.0, 13200), t0).time, "3 h 40 min");
        // 10 s later the estimate moved: percent passes, the text waits.
        let v = th.reduce(view(63.0, 13000), t0 + Duration::from_secs(10));
        assert_eq!((v.percent, v.time.as_str()), (63, "3 h 40 min"));
        let v = th.reduce(view(63.0, 12900), t0 + Duration::from_secs(61));
        assert_eq!(v.time, "3 h 35 min");
        // Plugging in is shown at once.
        let plugged = battery_view(&battery(STATE_CHARGING, 63.0, 0, 1800));
        let v = th.reduce(plugged, t0 + Duration::from_secs(62));
        assert_eq!((v.charging, v.time.as_str()), (true, "30 min"));
        // Unknown is shown at once too, and so is the first estimate after.
        let v = th.reduce(view(63.0, 0), t0 + Duration::from_secs(63));
        assert_eq!(v.time, "");
    }

    #[test]
    fn profiles_are_ordered_and_absent_daemon_is_empty() {
        let p = Profiles {
            active: "performance".into(),
            list: vec!["performance".into(), "weird".into(), "power-saver".into()],
        };
        assert_eq!(ordered_profiles(&p.list), ["power-saver", "performance"]);
        assert_eq!(
            profiles_view(Some(&p)),
            json!({ "profile": "performance", "profiles": ["power-saver", "performance"] })
        );
        assert_eq!(
            profiles_view(None),
            json!({ "profile": "balanced", "profiles": [] })
        );
        let mut props = Props::new();
        props.insert("ActiveProfile".into(), bus::Prop::Str("balanced".into()));
        props.insert(
            "Profiles".into(),
            bus::Prop::List(vec!["balanced".into(), "power-saver".into()]),
        );
        let p = Profiles::from_props(&props);
        assert_eq!(p.active, "balanced");
        assert_eq!(ordered_profiles(&p.list), ["power-saver", "balanced"]);
    }

    #[derive(Debug, Default)]
    struct FakeIo {
        battery: Option<Battery>,
        profiles: Option<Profiles>,
        set_fails: bool,
    }

    impl PowerIo for FakeIo {
        async fn battery(&mut self) -> Option<Battery> {
            self.battery.clone()
        }
        async fn profiles(&mut self) -> Option<Profiles> {
            self.profiles.clone()
        }
        async fn set_profile(&mut self, profile: &str) -> Result<(), String> {
            if self.set_fails {
                return Err("denied".into());
            }
            if let Some(p) = &mut self.profiles {
                p.active = profile.to_owned();
            }
            Ok(())
        }
    }

    type Patches = Arc<Mutex<Vec<Value>>>;

    fn engine(io: FakeIo) -> (Engine<FakeIo>, Patches) {
        let seen: Patches = Arc::default();
        let s2 = Arc::clone(&seen);
        let sink = Sink::new(move |e| {
            if let Ok(mut v) = s2.lock() {
                v.push(e.to_json()["d"].clone());
            }
        });
        let published = Arc::new(Published::new(NAME, sink, initial_state()));
        (Engine::new(io, published), seen)
    }

    fn take(p: &Patches) -> Vec<Value> {
        p.lock()
            .map(|mut v| std::mem::take(&mut *v))
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn engine_patches_only_changes() {
        let (mut e, seen) = engine(FakeIo {
            battery: Some(battery(STATE_DISCHARGING, 64.2, 13200, 0)),
            profiles: Some(Profiles {
                active: "balanced".into(),
                list: KNOWN_PROFILES.iter().map(|s| (*s).to_owned()).collect(),
            }),
            set_fails: false,
        });
        let t0 = Instant::now();
        e.refresh_battery(t0).await;
        e.refresh_profiles().await;
        assert_eq!(
            take(&seen),
            vec![
                json!({ "hasBattery": true, "batteryPercent": 64, "timeRemaining": "3 h 40 min" }),
                json!({ "profiles": ["power-saver", "balanced", "performance"] }),
            ]
        );
        // 64.2 → 64.4 is not a whole point: nothing is sent.
        e.io.battery = Some(battery(STATE_DISCHARGING, 64.4, 13150, 0));
        e.refresh_battery(t0 + Duration::from_secs(5)).await;
        assert!(take(&seen).is_empty());
        e.io.battery = Some(battery(STATE_DISCHARGING, 62.8, 13000, 0));
        e.refresh_battery(t0 + Duration::from_secs(9)).await;
        assert_eq!(take(&seen), vec![json!({ "batteryPercent": 63 })]);

        e.set_profile("performance").await;
        e.refresh_profiles().await;
        assert_eq!(take(&seen), vec![json!({ "profile": "performance" })]);
        // A refused switch re-sends the real profile to undo the optimistic UI.
        e.io.set_fails = true;
        e.set_profile("power-saver").await;
        assert_eq!(take(&seen), vec![json!({ "profile": "performance" })]);
        // Daemons gone: state, not errors.
        e.io.battery = None;
        e.io.profiles = None;
        e.refresh_battery(t0 + Duration::from_secs(10)).await;
        e.refresh_profiles().await;
        e.published.publish(initial_state());
        assert_eq!(e.published.state(), initial_state());
    }

    #[test]
    fn call_validates_arguments() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let svc = Power {
            published: Arc::new(Published::new(NAME, Sink::new(|_| {}), initial_state())),
            tx,
        };
        assert_eq!(svc.name(), "power");
        assert_eq!(svc.state()["profiles"], json!([]));
        assert!(svc.call("setProfile", &[json!("balanced")]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::SetProfile(p)) if p == "balanced"));
        assert!(matches!(
            svc.call("setProfile", &[json!("turbo")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("setProfile", &[]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("nope", &[]),
            Err(CallError::UnknownMethod(_))
        ));
    }
}
