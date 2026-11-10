//! `Services.display` — backlight brightness and night light.
//!
//! State: `brightnessAvailable`, `brightness` (0..1), `nightLight`,
//! `nightLightAvailable`. Methods: `setBrightness(v)`, `setNightLight(on)`,
//! `refresh()`.
//!
//! Brightness is read from `/sys/class/backlight/*` and written through
//! logind (`Session.SetBrightness`), so no privileges or udev rules are
//! needed. A slider drag is coalesced to ≤ 60 writes/s, last value wins, and
//! our own writes are not echoed back while dragging. sysfs has no change
//! signal we could wait on without polling, so external changes (brightness
//! keys) are picked up on `refresh()`, which the OSD calls when the key is
//! pressed.
//!
//! Night light is `hyprsunset` (4000 K) run as a child we own and reap; when
//! the binary is not installed the toggle is hidden.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::time::Instant;

use super::power::bus::Published;
use super::{CallError, Context, Service, args};

const NAME: &str = "display";
/// Never go fully dark: the user must be able to see the slider.
const MIN_BRIGHTNESS: f64 = 0.05;
/// ≤ 60 writes per second.
const WRITE_INTERVAL: Duration = Duration::from_millis(16);
/// Quiet time after our last write before the real value is confirmed.
const CONFIRM_DELAY: Duration = Duration::from_millis(200);
const NIGHT_LIGHT_BIN: &str = "hyprsunset";
const NIGHT_LIGHT_KELVIN: &str = "4000";

// ---- pure core -------------------------------------------------------------

/// One `/sys/class/backlight` device.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Backlight {
    name: String,
    /// sysfs `type`: `firmware`, `platform` or `raw`.
    kind: String,
    max: u32,
}

/// The device to drive: firmware, else platform, else the first by name.
fn pick_backlight(mut all: Vec<Backlight>) -> Option<Backlight> {
    all.retain(|b| b.max > 0);
    all.sort_by(|a, b| a.name.cmp(&b.name));
    let rank = |b: &Backlight| match b.kind.as_str() {
        "firmware" => 0,
        "platform" => 1,
        _ => 2,
    };
    all.into_iter().min_by_key(rank)
}

/// `raw / max` as 0..1, rounded to 4 decimals (stable JSON, no float noise).
fn fraction(raw: u32, max: u32) -> f64 {
    if max == 0 {
        return 0.0;
    }
    let f = f64::from(raw.min(max)) / f64::from(max);
    (f * 10_000.0).round() / 10_000.0
}

/// The raw value for a 0..1 request, clamped to 5 %..100 %.
fn target_raw(v: f64, max: u32) -> u32 {
    let v = if v.is_finite() { v } else { 1.0 };
    let v = v.clamp(MIN_BRIGHTNESS, 1.0);
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let raw = (v * f64::from(max)).round() as u32;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let floor = (MIN_BRIGHTNESS * f64::from(max)).ceil() as u32;
    raw.clamp(floor.min(max), max)
}

/// First `name` in the `PATH`-style `path_var` that `is_exec` accepts.
fn find_in_path(path_var: &OsStr, name: &str, is_exec: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    std::env::split_paths(path_var)
        .filter(|dir| !dir.as_os_str().is_empty())
        .map(|dir| dir.join(name))
        .find(|p| is_exec(p))
}

// ---- I/O seam --------------------------------------------------------------

/// What the engine needs from the system.
trait DisplayIo {
    fn backlights(&mut self) -> Vec<Backlight>;
    fn read_raw(&mut self, name: &str) -> Option<u32>;
    async fn write_raw(&mut self, name: &str, raw: u32) -> Result<(), String>;
    fn night_light_available(&mut self) -> bool;
    async fn night_start(&mut self) -> Result<(), String>;
    /// Stops and reaps the night-light process, if any.
    async fn night_stop(&mut self);
    /// Resolves when the night-light process exits on its own (reaped);
    /// never resolves while there is none.
    async fn night_exited(&mut self);
}

#[derive(Debug)]
struct Engine<I> {
    io: I,
    published: Arc<Published>,
    backlight: Option<Backlight>,
    /// Latest requested brightness not yet written.
    pending: Option<f64>,
    next_write: Instant,
    confirm_at: Option<Instant>,
    night_on: bool,
}

impl<I: DisplayIo> Engine<I> {
    fn new(io: I, published: Arc<Published>) -> Self {
        Self {
            io,
            published,
            backlight: None,
            pending: None,
            next_write: Instant::now(),
            confirm_at: None,
            night_on: false,
        }
    }

    /// Full state read from the system.
    fn read_state(&mut self) -> Value {
        self.backlight = pick_backlight(self.io.backlights());
        let raw = self
            .backlight
            .as_ref()
            .and_then(|b| self.io.read_raw(&b.name).map(|raw| fraction(raw, b.max)));
        let mut state = json!({
            "brightnessAvailable": raw.is_some(),
            "nightLight": self.night_on,
            "nightLightAvailable": self.io.night_light_available(),
        });
        // An unreadable backlight keeps the last known value.
        if let (Some(v), Some(map)) = (raw, state.as_object_mut()) {
            map.insert("brightness".into(), json!(v));
        }
        state
    }

    fn refresh(&mut self) {
        let mut state = self.read_state();
        // While our own writes are in flight the UI is ahead of sysfs: the
        // confirmation that follows them reports the brightness.
        if (self.pending.is_some() || self.confirm_at.is_some())
            && let Some(map) = state.as_object_mut()
        {
            map.remove("brightness");
        }
        self.published.publish(state);
    }

    fn set_brightness(&mut self, v: f64) {
        if self.backlight.is_none() {
            self.published.resend(&["brightness"]);
            return;
        }
        self.pending = Some(v);
    }

    /// Writes the latest requested value.
    async fn write(&mut self) {
        let (Some(v), Some(b)) = (self.pending.take(), self.backlight.clone()) else {
            return;
        };
        let raw = target_raw(v, b.max);
        let result = self.io.write_raw(&b.name, raw).await;
        let now = Instant::now();
        self.next_write = now + WRITE_INTERVAL;
        match result {
            Ok(()) => {
                // The UI already shows it (optimistic slider): no echo.
                self.published
                    .set_silent("brightness", json!(fraction(raw, b.max)));
                self.confirm_at = Some(now + CONFIRM_DELAY);
            }
            Err(e) => {
                tracing::warn!(%e, device = %b.name, "could not set the brightness");
                // The UI moved optimistically: report the real value.
                self.confirm_at = None;
                self.refresh();
                self.published.resend(&["brightness"]);
            }
        }
    }

    /// Reports what the backlight really is after our writes settled.
    fn confirm(&mut self) {
        self.confirm_at = None;
        self.refresh();
    }

    async fn set_night_light(&mut self, on: bool) {
        if on && !self.night_on {
            if !self.io.night_light_available() {
                tracing::debug!("night light requested but {NIGHT_LIGHT_BIN} is not installed");
            } else if let Err(e) = self.io.night_start().await {
                tracing::warn!(%e, "could not start {NIGHT_LIGHT_BIN}");
            } else {
                self.night_on = true;
            }
        } else if !on && self.night_on {
            self.io.night_stop().await;
            self.night_on = false;
        }
        if self.night_on == on {
            self.refresh();
        } else {
            // The UI switched optimistically: put it back.
            self.refresh();
            self.published.resend(&["nightLight"]);
        }
    }

    fn night_gone(&mut self) {
        tracing::info!("{NIGHT_LIGHT_BIN} exited");
        self.night_on = false;
        self.refresh();
    }
}

#[derive(Debug)]
enum Cmd {
    SetBrightness(f64),
    SetNightLight(bool),
    Refresh,
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

async fn run<I: DisplayIo>(mut engine: Engine<I>, mut rx: mpsc::UnboundedReceiver<Cmd>) {
    loop {
        let write_at = engine.pending.map(|_| engine.next_write);
        let confirm_at = engine.confirm_at.filter(|_| engine.pending.is_none());
        let night_on = engine.night_on;
        tokio::select! {
            // Commands first: a burst collapses into its last value before
            // anything is written.
            biased;
            cmd = rx.recv() => match cmd {
                Some(Cmd::SetBrightness(v)) => engine.set_brightness(v),
                Some(Cmd::SetNightLight(on)) => engine.set_night_light(on).await,
                Some(Cmd::Refresh) => engine.refresh(),
                None => {
                    engine.io.night_stop().await;
                    return;
                }
            },
            () = sleep_until(write_at), if write_at.is_some() => engine.write().await,
            () = sleep_until(confirm_at), if confirm_at.is_some() => engine.confirm(),
            () = engine.io.night_exited(), if night_on => engine.night_gone(),
        }
    }
}

// ---- the real system -------------------------------------------------------

const LOGIND: &str = "org.freedesktop.login1";

#[derive(Debug)]
struct SysIo {
    sysfs: PathBuf,
    /// System bus + our logind session object, opened on the first write.
    logind: Option<(zbus::Connection, String)>,
    night_bin: Option<PathBuf>,
    child: Option<tokio::process::Child>,
}

impl SysIo {
    fn new() -> Self {
        Self {
            sysfs: PathBuf::from("/sys/class/backlight"),
            logind: None,
            night_bin: None,
            child: None,
        }
    }

    fn read_u32(path: &Path) -> Option<u32> {
        std::fs::read_to_string(path).ok()?.trim().parse().ok()
    }

    async fn logind(&mut self) -> Result<(zbus::Connection, String), String> {
        if let Some(l) = &self.logind {
            return Ok(l.clone());
        }
        let conn = zbus::Connection::system()
            .await
            .map_err(|e| e.to_string())?;
        let by_pid = conn
            .call_method(
                Some(LOGIND),
                "/org/freedesktop/login1",
                Some("org.freedesktop.login1.Manager"),
                "GetSessionByPID",
                &(std::process::id(),),
            )
            .await;
        // A shell started by `systemd --user` is in no session scope: `auto`
        // is then the user's graphical session.
        let session = by_pid
            .ok()
            .and_then(|m| {
                m.body()
                    .deserialize::<zbus::zvariant::OwnedObjectPath>()
                    .ok()
            })
            .map_or_else(
                || "/org/freedesktop/login1/session/auto".to_owned(),
                |p| p.to_string(),
            );
        self.logind = Some((conn, session));
        self.logind.clone().ok_or_else(String::new)
    }
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    p.metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

impl DisplayIo for SysIo {
    fn backlights(&mut self) -> Vec<Backlight> {
        let Ok(dir) = std::fs::read_dir(&self.sysfs) else {
            return Vec::new();
        };
        dir.flatten()
            .filter_map(|entry| {
                let path = entry.path();
                Some(Backlight {
                    name: entry.file_name().into_string().ok()?,
                    kind: std::fs::read_to_string(path.join("type"))
                        .unwrap_or_default()
                        .trim()
                        .to_owned(),
                    max: Self::read_u32(&path.join("max_brightness"))?,
                })
            })
            .collect()
    }

    fn read_raw(&mut self, name: &str) -> Option<u32> {
        Self::read_u32(&self.sysfs.join(name).join("brightness"))
    }

    async fn write_raw(&mut self, name: &str, raw: u32) -> Result<(), String> {
        let (conn, session) = self.logind().await?;
        let result = conn
            .call_method(
                Some(LOGIND),
                session.as_str(),
                Some("org.freedesktop.login1.Session"),
                "SetBrightness",
                &("backlight", name, raw),
            )
            .await;
        if result.is_err() {
            // logind restarted or the session changed: look it up again.
            self.logind = None;
        }
        result.map(drop).map_err(|e| e.to_string())
    }

    fn night_light_available(&mut self) -> bool {
        self.night_bin = std::env::var_os("PATH")
            .and_then(|path| find_in_path(&path, NIGHT_LIGHT_BIN, is_executable));
        self.night_bin.is_some()
    }

    async fn night_start(&mut self) -> Result<(), String> {
        let bin = self.night_bin.clone().ok_or("not installed")?;
        let child = tokio::process::Command::new(bin)
            .args(["-t", NIGHT_LIGHT_KELVIN])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| e.to_string())?;
        self.child = Some(child);
        Ok(())
    }

    async fn night_stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // Kills and waits: no zombie.
            if let Err(e) = child.kill().await {
                tracing::debug!(%e, "{NIGHT_LIGHT_BIN} was already gone");
            }
        }
    }

    async fn night_exited(&mut self) {
        match &mut self.child {
            Some(child) => {
                let status = child.wait().await;
                tracing::debug!(?status, "{NIGHT_LIGHT_BIN} exit status");
                self.child = None;
            }
            None => std::future::pending().await,
        }
    }
}

#[derive(Debug)]
struct Display {
    published: Arc<Published>,
    tx: mpsc::UnboundedSender<Cmd>,
}

impl Service for Display {
    fn name(&self) -> &'static str {
        NAME
    }
    fn state(&self) -> Value {
        self.published.state()
    }
    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let cmd = match method {
            "setBrightness" => {
                let v = args::f64(a, 0)?;
                if !v.is_finite() {
                    return Err(CallError::BadArgs("brightness must be a number".into()));
                }
                Cmd::SetBrightness(v)
            }
            "setNightLight" => Cmd::SetNightLight(args::bool(a, 0)?),
            "refresh" => Cmd::Refresh,
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        };
        self.tx
            .send(cmd)
            .map_err(|_| CallError::Failed("display service stopped".into()))?;
        Ok(Value::Null)
    }
}

fn initial_state() -> Value {
    json!({
        "brightnessAvailable": false,
        "brightness": 1.0,
        "nightLight": false,
        "nightLightAvailable": false,
    })
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let published = Arc::new(Published::new(NAME, ctx.sink.clone(), initial_state()));
    let mut engine = Engine::new(SysIo::new(), Arc::clone(&published));
    // Two tiny sysfs reads and a PATH lookup: the first snapshot is right.
    let first = engine.read_state();
    if let Some(map) = first.as_object() {
        for (k, v) in map {
            published.set_silent(k, v.clone());
        }
    }
    let (tx, rx) = mpsc::unbounded_channel();
    ctx.runtime.spawn(run(engine, rx));
    Box::new(Display { published, tx })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::Sink;
    use std::sync::Mutex;

    fn bl(name: &str, kind: &str, max: u32) -> Backlight {
        Backlight {
            name: name.into(),
            kind: kind.into(),
            max,
        }
    }

    #[test]
    fn picks_firmware_then_platform_then_first() {
        let pick = |v: Vec<Backlight>| pick_backlight(v).map(|b| b.name);
        assert_eq!(pick(vec![]), None);
        assert_eq!(
            pick(vec![bl("intel_backlight", "raw", 60000)]).as_deref(),
            Some("intel_backlight")
        );
        assert_eq!(
            pick(vec![
                bl("nvidia_0", "raw", 100),
                bl("intel_backlight", "raw", 60000),
                bl("thinkpad_screen", "platform", 15),
                bl("acpi_video0", "firmware", 10),
            ])
            .as_deref(),
            Some("acpi_video0")
        );
        assert_eq!(
            pick(vec![
                bl("z_raw", "raw", 100),
                bl("ideapad", "platform", 15),
                bl("a_raw", "raw", 100)
            ])
            .as_deref(),
            Some("ideapad")
        );
        assert_eq!(
            pick(vec![bl("b", "raw", 100), bl("a", "raw", 100)]).as_deref(),
            Some("a")
        );
        // A device that cannot be driven is skipped.
        assert_eq!(
            pick(vec![bl("broken", "firmware", 0), bl("ok", "raw", 255)]).as_deref(),
            Some("ok")
        );
    }

    #[test]
    fn converts_between_fraction_and_raw() {
        assert!((fraction(10801, 60000) - 0.18).abs() < 1e-9);
        assert!((fraction(255, 255) - 1.0).abs() < f64::EPSILON);
        assert!((fraction(300, 255) - 1.0).abs() < f64::EPSILON);
        assert!(fraction(5, 0).abs() < f64::EPSILON);
        assert_eq!(target_raw(0.7, 60000), 42000);
        assert_eq!(target_raw(1.7, 60000), 60000);
        // Never below 5 %, even on coarse devices.
        assert_eq!(target_raw(0.0, 60000), 3000);
        assert_eq!(target_raw(-1.0, 255), 13);
        assert_eq!(target_raw(0.01, 10), 1);
        assert_eq!(target_raw(0.0, 1), 1);
        assert_eq!(target_raw(f64::NAN, 100), 100);
    }

    #[test]
    fn finds_a_binary_on_the_path() {
        let exists = |p: &Path| p == Path::new("/usr/bin/hyprsunset");
        assert_eq!(
            find_in_path(OsStr::new("/bin::/usr/bin:/opt"), "hyprsunset", exists),
            Some(PathBuf::from("/usr/bin/hyprsunset"))
        );
        assert_eq!(
            find_in_path(OsStr::new("/bin:/opt"), "hyprsunset", exists),
            None
        );
        assert_eq!(find_in_path(OsStr::new(""), "hyprsunset", |_| true), None);
    }

    #[derive(Debug)]
    struct Fake {
        devices: Vec<Backlight>,
        raw: u32,
        writes: Vec<u32>,
        write_fails: bool,
        night_available: bool,
        night_running: bool,
        night_starts: u32,
    }

    #[derive(Debug, Clone)]
    struct FakeIo {
        s: Arc<Mutex<Fake>>,
        exited: Arc<tokio::sync::Notify>,
    }

    impl FakeIo {
        fn new(devices: Vec<Backlight>, raw: u32) -> Self {
            Self {
                s: Arc::new(Mutex::new(Fake {
                    devices,
                    raw,
                    writes: Vec::new(),
                    write_fails: false,
                    night_available: false,
                    night_running: false,
                    night_starts: 0,
                })),
                exited: Arc::default(),
            }
        }
        fn with<T>(&self, f: impl FnOnce(&mut Fake) -> T) -> T {
            let mut guard = self
                .s
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            f(&mut guard)
        }
    }

    impl DisplayIo for FakeIo {
        fn backlights(&mut self) -> Vec<Backlight> {
            self.with(|s| s.devices.clone())
        }
        fn read_raw(&mut self, _name: &str) -> Option<u32> {
            self.with(|s| Some(s.raw))
        }
        async fn write_raw(&mut self, _name: &str, raw: u32) -> Result<(), String> {
            self.with(|s| {
                if s.write_fails {
                    return Err("denied".to_owned());
                }
                s.raw = raw;
                s.writes.push(raw);
                Ok(())
            })
        }
        fn night_light_available(&mut self) -> bool {
            self.with(|s| s.night_available)
        }
        async fn night_start(&mut self) -> Result<(), String> {
            self.with(|s| {
                s.night_running = true;
                s.night_starts += 1;
            });
            Ok(())
        }
        async fn night_stop(&mut self) {
            self.with(|s| s.night_running = false);
        }
        async fn night_exited(&mut self) {
            self.exited.notified().await;
            self.with(|s| s.night_running = false);
        }
    }

    type Patches = Arc<Mutex<Vec<Value>>>;

    struct Rig {
        io: FakeIo,
        tx: mpsc::UnboundedSender<Cmd>,
        published: Arc<Published>,
        patches: Patches,
    }

    impl Rig {
        fn start(io: FakeIo) -> Self {
            let patches: Patches = Arc::default();
            let p2 = Arc::clone(&patches);
            let sink = Sink::new(move |e| {
                if let Ok(mut v) = p2.lock() {
                    v.push(e.to_json()["d"].clone());
                }
            });
            let published = Arc::new(Published::new(NAME, sink, initial_state()));
            let mut engine = Engine::new(io.clone(), Arc::clone(&published));
            engine.refresh();
            let (tx, rx) = mpsc::unbounded_channel();
            tokio::spawn(run(engine, rx));
            let rig = Self {
                io,
                tx,
                published,
                patches,
            };
            rig.take();
            rig
        }
        fn send(&self, cmd: Cmd) {
            assert!(self.tx.send(cmd).is_ok());
        }
        fn take(&self) -> Vec<Value> {
            self.patches
                .lock()
                .map(|mut v| std::mem::take(&mut *v))
                .unwrap_or_default()
        }
        async fn settle(&self) {
            tokio::time::sleep(CONFIRM_DELAY + Duration::from_millis(150)).await;
        }
    }

    fn laptop() -> FakeIo {
        FakeIo::new(vec![bl("intel_backlight", "raw", 1000)], 700)
    }

    #[tokio::test]
    async fn first_state_reads_the_backlight() {
        let rig = Rig::start(laptop());
        assert_eq!(
            rig.published.state(),
            json!({
                "brightnessAvailable": true,
                "brightness": 0.7,
                "nightLight": false,
                "nightLightAvailable": false,
            })
        );
        let none = Rig::start(FakeIo::new(vec![], 0));
        assert_eq!(none.published.state(), initial_state());
        // Without a backlight a request only restores the UI.
        none.send(Cmd::SetBrightness(0.3));
        none.settle().await;
        assert_eq!(none.take(), vec![json!({ "brightness": 1.0 })]);
        assert!(none.io.with(|s| s.writes.is_empty()));
    }

    #[tokio::test]
    async fn a_drag_burst_is_one_write_and_is_not_echoed() {
        let rig = Rig::start(laptop());
        for i in 0..40 {
            rig.send(Cmd::SetBrightness(0.30 + f64::from(i) * 0.01));
        }
        rig.settle().await;
        assert_eq!(rig.io.with(|s| s.writes.clone()), [690]);
        // The UI already shows 0.69: nothing to tell it.
        assert!(rig.take().is_empty());
        assert_eq!(rig.published.state()["brightness"], json!(0.69));

        // Spaced requests are all written, never faster than 60/s, and the
        // 5 % floor applies.
        let t0 = Instant::now();
        rig.send(Cmd::SetBrightness(0.5));
        tokio::time::sleep(Duration::from_millis(3)).await;
        rig.send(Cmd::SetBrightness(0.0));
        rig.settle().await;
        assert_eq!(rig.io.with(|s| s.writes.clone()), [690, 500, 50]);
        assert!(t0.elapsed() >= WRITE_INTERVAL);
        assert!(rig.take().is_empty());
        assert_eq!(rig.published.state()["brightness"], json!(0.05));
    }

    #[tokio::test]
    async fn refresh_reports_external_changes_and_failed_writes_restore_the_ui() {
        let rig = Rig::start(laptop());
        rig.io.with(|s| s.raw = 400);
        rig.send(Cmd::Refresh);
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "brightness": 0.4 })]);
        rig.send(Cmd::Refresh);
        rig.settle().await;
        assert!(rig.take().is_empty());

        rig.io.with(|s| s.write_fails = true);
        rig.send(Cmd::SetBrightness(0.9));
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "brightness": 0.4 })]);

        // The panel disappears (e.g. dock-only): state, not an error.
        rig.io.with(|s| s.devices.clear());
        rig.send(Cmd::Refresh);
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "brightnessAvailable": false })]);
    }

    #[tokio::test]
    async fn night_light_follows_the_child_process() {
        let rig = Rig::start(laptop());
        // Not installed: the request is refused and the UI is put back.
        rig.send(Cmd::SetNightLight(true));
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "nightLight": false })]);
        assert_eq!(rig.io.with(|s| s.night_starts), 0);

        rig.io.with(|s| s.night_available = true);
        rig.send(Cmd::Refresh);
        rig.send(Cmd::SetNightLight(true));
        rig.send(Cmd::SetNightLight(true));
        rig.settle().await;
        assert_eq!(
            rig.take(),
            vec![
                json!({ "nightLightAvailable": true }),
                json!({ "nightLight": true })
            ]
        );
        assert_eq!(
            rig.io.with(|s| (s.night_starts, s.night_running)),
            (1, true)
        );

        rig.send(Cmd::SetNightLight(false));
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "nightLight": false })]);
        assert!(!rig.io.with(|s| s.night_running));

        // The process dies on its own: the toggle goes off.
        rig.send(Cmd::SetNightLight(true));
        rig.settle().await;
        rig.take();
        rig.io.exited.notify_one();
        rig.settle().await;
        assert_eq!(rig.take(), vec![json!({ "nightLight": false })]);
    }

    #[test]
    fn call_validates_arguments() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let svc = Display {
            published: Arc::new(Published::new(NAME, Sink::new(|_| {}), initial_state())),
            tx,
        };
        assert_eq!(svc.name(), "display");
        assert!(svc.call("setBrightness", &[json!(0.4)]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::SetBrightness(v)) if (v - 0.4).abs() < 1e-9));
        assert!(svc.call("setNightLight", &[json!(true)]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::SetNightLight(true))));
        assert!(svc.call("refresh", &[]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::Refresh)));
        assert!(matches!(
            svc.call("setBrightness", &[json!("bright")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("zoom", &[]),
            Err(CallError::UnknownMethod(_))
        ));
    }
}
