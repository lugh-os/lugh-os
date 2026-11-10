//! `Services.bluetooth` — BlueZ over the system bus.
//!
//! State: `available` (an adapter exists), `enabled` (`Adapter1.Powered`),
//! `devices` (paired or connected only; connected first, then by name) with
//! roles `address`, `name`, `icon` (Lucide), `paired`, `connected`, `battery`
//! (−1 unknown), `busy`. Methods: `setEnabled(on)`, `toggleDevice(address)`.
//!
//! Signal-driven (`InterfacesAdded/Removed`, `PropertiesChanged`,
//! `NameOwnerChanged`); BlueZ absent or restarting is `available: false`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;
use std::time::Duration;

use futures_util::future::BoxFuture;
use futures_util::stream::FuturesUnordered;
use futures_util::{FutureExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zbus::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

use super::power::bus::{self, Prop, Props, Published};
use super::{CallError, Context, Service, args};

const NAME: &str = "bluetooth";
const BLUEZ: &str = "org.bluez";
const ADAPTER: &str = "org.bluez.Adapter1";
const DEVICE: &str = "org.bluez.Device1";
const BATTERY: &str = "org.bluez.Battery1";
const OBJECT_MANAGER: &str = "org.freedesktop.DBus.ObjectManager";
/// How long a connect/disconnect may take before `busy` is cleared.
const OP_TIMEOUT: Duration = Duration::from_secs(20);

// ---- pure core -------------------------------------------------------------

/// BlueZ `Icon` → Lucide icon name.
fn lucide_icon(bluez: &str) -> &'static str {
    match bluez {
        "audio-headset" | "audio-headphones" => "headphones",
        "audio-card" => "speaker",
        "input-keyboard" => "keyboard",
        "input-mouse" => "mouse",
        "phone" => "smartphone",
        "computer" => "laptop",
        "input-gaming" => "gamepad-2",
        _ => "bluetooth",
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Device {
    address: String,
    alias: String,
    icon: String,
    paired: bool,
    connected: bool,
}

impl Device {
    fn update(&mut self, p: &Props) {
        let text = |k: &str| p.get(k).and_then(Prop::as_str).map(str::to_owned);
        if let Some(v) = text("Address") {
            self.address = v;
        }
        if let Some(v) = text("Alias") {
            self.alias = v;
        }
        if let Some(v) = text("Icon") {
            self.icon = v;
        }
        if let Some(v) = p.get("Paired").and_then(Prop::as_bool) {
            self.paired = v;
        }
        if let Some(v) = p.get("Connected").and_then(Prop::as_bool) {
            self.connected = v;
        }
    }

    fn name(&self) -> &str {
        if self.alias.is_empty() {
            &self.address
        } else {
            &self.alias
        }
    }
}

/// Everything BlueZ told us, keyed by object path, plus our in-flight work.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Model {
    /// Adapter path → powered.
    adapters: BTreeMap<String, bool>,
    devices: BTreeMap<String, Device>,
    /// Device path → battery percentage.
    batteries: BTreeMap<String, i64>,
    /// Addresses with a connect/disconnect in flight.
    busy: BTreeSet<String>,
}

impl Model {
    /// `InterfacesAdded`, or one entry of `GetManagedObjects`.
    fn add(&mut self, path: &str, interfaces: &HashMap<String, Props>) {
        for (interface, props) in interfaces {
            self.change(path, interface, props);
        }
    }

    /// `PropertiesChanged` (also creates the object: BlueZ sends full
    /// property sets on `InterfacesAdded`).
    fn change(&mut self, path: &str, interface: &str, props: &Props) {
        match interface {
            ADAPTER => {
                let powered = self.adapters.entry(path.to_owned()).or_default();
                if let Some(v) = props.get("Powered").and_then(Prop::as_bool) {
                    *powered = v;
                }
            }
            DEVICE => self
                .devices
                .entry(path.to_owned())
                .or_default()
                .update(props),
            BATTERY => {
                if let Some(v) = props.get("Percentage").and_then(Prop::as_i64) {
                    self.batteries.insert(path.to_owned(), v.clamp(0, 100));
                }
            }
            _ => {}
        }
    }

    /// `InterfacesRemoved`.
    fn remove(&mut self, path: &str, interfaces: &[String]) {
        for interface in interfaces {
            match interface.as_str() {
                ADAPTER => {
                    self.adapters.remove(path);
                }
                DEVICE => {
                    if let Some(d) = self.devices.remove(path) {
                        self.busy.remove(&d.address);
                    }
                    self.batteries.remove(path);
                }
                BATTERY => {
                    self.batteries.remove(path);
                }
                _ => {}
            }
        }
    }

    /// The adapter calls go to (the first one, `hci0` on nearly every machine).
    fn adapter(&self) -> Option<&str> {
        self.adapters.keys().next().map(String::as_str)
    }

    fn device_by_address(&self, address: &str) -> Option<(&str, &Device)> {
        self.devices
            .iter()
            .find(|(_, d)| d.address == address)
            .map(|(p, d)| (p.as_str(), d))
    }

    /// The QML state.
    fn view(&self) -> Value {
        let mut shown: Vec<(&String, &Device)> = self
            .devices
            .iter()
            .filter(|(_, d)| (d.paired || d.connected) && !d.address.is_empty())
            .collect();
        shown.sort_by_cached_key(|(_, d)| {
            (!d.connected, d.name().to_lowercase(), d.address.clone())
        });
        let devices: Vec<Value> = shown
            .into_iter()
            .map(|(path, d)| {
                json!({
                    "address": d.address,
                    "name": d.name(),
                    "icon": lucide_icon(&d.icon),
                    "paired": d.paired,
                    "connected": d.connected,
                    "battery": self.batteries.get(path).copied().unwrap_or(-1),
                    "busy": self.busy.contains(&d.address),
                })
            })
            .collect();
        json!({
            "available": !self.adapters.is_empty(),
            "enabled": self.adapters.values().next().copied().unwrap_or(false),
            "devices": devices,
        })
    }
}

// ---- I/O seam --------------------------------------------------------------

type OpResult = Result<(), String>;

/// The three things we ask BlueZ to do.
trait BtIo {
    fn set_powered(&self, adapter: &str, on: bool) -> BoxFuture<'static, OpResult>;
    /// `Device1.Connect` (`connect`) or `Device1.Disconnect`.
    fn set_connected(&self, device: &str, connect: bool) -> BoxFuture<'static, OpResult>;
}

/// An operation that settled.
#[derive(Debug)]
enum Done {
    Powered(OpResult),
    Device(String, OpResult),
}

struct Engine<I> {
    io: I,
    model: Model,
    ops: FuturesUnordered<BoxFuture<'static, Done>>,
    published: Arc<Published>,
    timeout: Duration,
}

impl<I> std::fmt::Debug for Engine<I> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine")
            .field("model", &self.model)
            .field("ops", &self.ops.len())
            .finish_non_exhaustive()
    }
}

impl<I: BtIo> Engine<I> {
    fn new(io: I, published: Arc<Published>) -> Self {
        Self {
            io,
            model: Model::default(),
            ops: FuturesUnordered::new(),
            published,
            timeout: OP_TIMEOUT,
        }
    }

    fn publish(&self) {
        self.published.publish(self.model.view());
    }

    /// BlueZ went away (or is about to be re-read from scratch).
    fn reset(&mut self) {
        self.model = Model::default();
        self.ops.clear();
        self.publish();
    }

    fn set_enabled(&mut self, on: bool) {
        let Some(adapter) = self.model.adapter() else {
            tracing::debug!("bluetooth.setEnabled: no adapter");
            self.published.resend(&["enabled", "devices"]);
            return;
        };
        let op = self.io.set_powered(adapter, on);
        let timeout = self.timeout;
        self.ops.push(
            async move {
                Done::Powered(
                    tokio::time::timeout(timeout, op)
                        .await
                        .unwrap_or_else(|_| Err("timed out".into())),
                )
            }
            .boxed(),
        );
    }

    fn toggle_device(&mut self, address: &str) {
        let Some((path, device)) = self.model.device_by_address(address) else {
            tracing::debug!(address, "bluetooth.toggleDevice: unknown device");
            return;
        };
        if self.model.busy.contains(address) {
            return;
        }
        let op = self.io.set_connected(path, !device.connected);
        let timeout = self.timeout;
        let addr = address.to_owned();
        self.ops.push(
            async move {
                let r = tokio::time::timeout(timeout, op)
                    .await
                    .unwrap_or_else(|_| Err("timed out".into()));
                Done::Device(addr, r)
            }
            .boxed(),
        );
        self.model.busy.insert(address.to_owned());
        self.publish();
    }

    fn settle(&mut self, done: Done) {
        match done {
            Done::Powered(Ok(())) => {}
            Done::Powered(Err(e)) => {
                tracing::warn!(%e, "could not switch the Bluetooth adapter");
                // The UI switched optimistically: put it back.
                self.published.resend(&["enabled", "devices"]);
            }
            Done::Device(address, result) => {
                if let Err(e) = result {
                    tracing::warn!(address, %e, "Bluetooth connect/disconnect failed");
                }
                self.model.busy.remove(&address);
                self.publish();
            }
        }
    }
}

#[derive(Debug, Clone)]
struct SysIo(Connection);

impl BtIo for SysIo {
    fn set_powered(&self, adapter: &str, on: bool) -> BoxFuture<'static, OpResult> {
        let (conn, adapter) = (self.0.clone(), adapter.to_owned());
        async move {
            bus::set_prop(&conn, BLUEZ, &adapter, ADAPTER, "Powered", on.into())
                .await
                .map_err(|e| e.to_string())
        }
        .boxed()
    }

    fn set_connected(&self, device: &str, connect: bool) -> BoxFuture<'static, OpResult> {
        let (conn, device) = (self.0.clone(), device.to_owned());
        let method = if connect { "Connect" } else { "Disconnect" };
        async move {
            conn.call_method(Some(BLUEZ), device.as_str(), Some(DEVICE), method, &())
                .await
                .map(drop)
                .map_err(|e| e.to_string())
        }
        .boxed()
    }
}

type RawInterfaces = HashMap<String, HashMap<String, OwnedValue>>;

fn convert(raw: &RawInterfaces) -> HashMap<String, Props> {
    raw.iter()
        .map(|(k, v)| (k.clone(), bus::props(v)))
        .collect()
}

/// Reads every BlueZ object into a fresh model.
async fn load(conn: &Connection) -> zbus::Result<Model> {
    let reply = conn
        .call_method(
            Some(BLUEZ),
            "/",
            Some(OBJECT_MANAGER),
            "GetManagedObjects",
            &(),
        )
        .await?;
    let objects: HashMap<OwnedObjectPath, RawInterfaces> = reply.body().deserialize()?;
    let mut model = Model::default();
    for (path, interfaces) in &objects {
        model.add(path.as_str(), &convert(interfaces));
    }
    Ok(model)
}

/// Applies one BlueZ signal. Returns `true` when BlueZ (re)appeared and must
/// be read from scratch.
fn apply_signal<I: BtIo>(engine: &mut Engine<I>, msg: &zbus::Message) -> bool {
    let header = msg.header();
    let member = header.member().map(|m| m.as_str()).unwrap_or_default();
    let path = header.path().map(|p| p.as_str()).unwrap_or_default();
    let body = msg.body();
    match member {
        "NameOwnerChanged" => {
            if let Some((_, _, new_owner)) = bus::owner_change(msg) {
                engine.reset();
                return !new_owner.is_empty();
            }
        }
        "InterfacesAdded" => {
            if let Ok((path, interfaces)) = body.deserialize::<(OwnedObjectPath, RawInterfaces)>() {
                engine.model.add(path.as_str(), &convert(&interfaces));
            }
        }
        "InterfacesRemoved" => {
            if let Ok((path, interfaces)) = body.deserialize::<(OwnedObjectPath, Vec<String>)>() {
                engine.model.remove(path.as_str(), &interfaces);
            }
        }
        "PropertiesChanged" => {
            if let Ok((interface, changed, _)) =
                body.deserialize::<(String, HashMap<String, OwnedValue>, Vec<String>)>()
            {
                engine.model.change(path, &interface, &bus::props(&changed));
            }
        }
        _ => {}
    }
    engine.publish();
    false
}

#[derive(Debug)]
enum Cmd {
    SetEnabled(bool),
    ToggleDevice(String),
}

/// One system-bus session. `Ok(())` = the service was dropped.
async fn session(
    rx: &mut mpsc::UnboundedReceiver<Cmd>,
    published: &Arc<Published>,
) -> zbus::Result<()> {
    let conn = Connection::system().await?;
    let object_manager = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(BLUEZ)?
        .interface(OBJECT_MANAGER)?
        .build();
    let mut stream = bus::signals(
        &conn,
        vec![
            bus::owner_rule(BLUEZ)?,
            object_manager,
            bus::props_rule(BLUEZ, "/org/bluez/*", ADAPTER)?,
            bus::props_rule(BLUEZ, "/org/bluez/*", DEVICE)?,
            bus::props_rule(BLUEZ, "/org/bluez/*", BATTERY)?,
        ],
    )
    .await?;
    let mut engine = Engine::new(SysIo(conn.clone()), Arc::clone(published));
    // Never auto-start BlueZ: a machine without Bluetooth keeps it off.
    let mut reload = bus::has_owner(&conn, BLUEZ).await;
    loop {
        if std::mem::take(&mut reload) {
            match load(&conn).await {
                Ok(model) => engine.model = model,
                Err(e) => tracing::debug!(%e, "BlueZ not readable yet"),
            }
            engine.publish();
        }
        tokio::select! {
            msg = stream.next() => {
                let Some(msg) = msg else {
                    return Err(zbus::Error::Failure("system bus closed".into()));
                };
                reload = apply_signal(&mut engine, &msg?);
            }
            Some(done) = engine.ops.next(), if !engine.ops.is_empty() => engine.settle(done),
            cmd = rx.recv() => match cmd {
                Some(Cmd::SetEnabled(on)) => engine.set_enabled(on),
                Some(Cmd::ToggleDevice(address)) => engine.toggle_device(&address),
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
            Err(e) => tracing::warn!(%e, "bluetooth: system bus lost; retrying"),
        }
        published.publish(Model::default().view());
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(60));
        while let Ok(cmd) = rx.try_recv() {
            tracing::debug!(?cmd, "bluetooth: dropped while offline");
            published.resend(&["enabled", "devices"]);
        }
    }
}

#[derive(Debug)]
struct Bluetooth {
    published: Arc<Published>,
    tx: mpsc::UnboundedSender<Cmd>,
}

impl Service for Bluetooth {
    fn name(&self) -> &'static str {
        NAME
    }
    fn state(&self) -> Value {
        self.published.state()
    }
    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let cmd = match method {
            "setEnabled" => Cmd::SetEnabled(args::bool(a, 0)?),
            "toggleDevice" => Cmd::ToggleDevice(args::string(a, 0)?),
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        };
        self.tx
            .send(cmd)
            .map_err(|_| CallError::Failed("bluetooth service stopped".into()))?;
        Ok(Value::Null)
    }
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let published = Arc::new(Published::new(
        NAME,
        ctx.sink.clone(),
        Model::default().view(),
    ));
    let (tx, rx) = mpsc::unbounded_channel();
    ctx.runtime.spawn(run(rx, Arc::clone(&published)));
    Box::new(Bluetooth { published, tx })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::Sink;
    use std::sync::Mutex;

    const HCI: &str = "/org/bluez/hci0";
    const BUDS: &str = "/org/bluez/hci0/dev_AC_12_2F_00_11_01";
    const KEYS: &str = "/org/bluez/hci0/dev_AC_12_2F_00_11_02";

    fn props(items: &[(&str, Prop)]) -> Props {
        items
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect()
    }

    fn device(address: &str, alias: &str, icon: &str, paired: bool, connected: bool) -> Props {
        props(&[
            ("Address", Prop::Str(address.into())),
            ("Alias", Prop::Str(alias.into())),
            ("Icon", Prop::Str(icon.into())),
            ("Paired", Prop::Bool(paired)),
            ("Connected", Prop::Bool(connected)),
        ])
    }

    fn sample() -> Model {
        let mut m = Model::default();
        m.change(HCI, ADAPTER, &props(&[("Powered", Prop::Bool(true))]));
        m.change(
            KEYS,
            DEVICE,
            &device(
                "AC:12:2F:00:11:02",
                "MX Keys",
                "input-keyboard",
                true,
                false,
            ),
        );
        let mut buds = HashMap::new();
        buds.insert(
            DEVICE.to_owned(),
            device(
                "AC:12:2F:00:11:01",
                "Keza's Buds",
                "audio-headset",
                true,
                true,
            ),
        );
        buds.insert(BATTERY.to_owned(), props(&[("Percentage", Prop::Int(72))]));
        m.add(BUDS, &buds);
        // Seen during a scan, never paired: not listed.
        m.change(
            "/org/bluez/hci0/dev_00_00_00_00_00_09",
            DEVICE,
            &device("00:00:00:00:00:09", "Stranger", "phone", false, false),
        );
        m
    }

    #[test]
    fn maps_icons() {
        for (bluez, lucide) in [
            ("audio-headset", "headphones"),
            ("audio-headphones", "headphones"),
            ("audio-card", "speaker"),
            ("input-keyboard", "keyboard"),
            ("input-mouse", "mouse"),
            ("phone", "smartphone"),
            ("computer", "laptop"),
            ("input-gaming", "gamepad-2"),
            ("input-tablet", "bluetooth"),
            ("", "bluetooth"),
        ] {
            assert_eq!(lucide_icon(bluez), lucide);
        }
    }

    #[test]
    fn view_lists_paired_or_connected_connected_first() {
        let v = sample().view();
        assert_eq!(
            v,
            json!({
                "available": true,
                "enabled": true,
                "devices": [
                    { "address": "AC:12:2F:00:11:01", "name": "Keza's Buds", "icon": "headphones",
                      "paired": true, "connected": true, "battery": 72, "busy": false },
                    { "address": "AC:12:2F:00:11:02", "name": "MX Keys", "icon": "keyboard",
                      "paired": true, "connected": false, "battery": -1, "busy": false },
                ],
            })
        );
        assert!(v["devices"][0]["battery"].is_i64());
    }

    #[test]
    fn sorts_by_name_within_a_group_and_falls_back_to_the_address() {
        let mut m = Model::default();
        m.change("/d/1", DEVICE, &device("00:01", "zeta", "", true, false));
        m.change("/d/2", DEVICE, &device("00:02", "Alpha", "", true, false));
        m.change("/d/3", DEVICE, &device("00:03", "", "", false, true));
        let v = m.view();
        let names: Vec<&str> = v["devices"]
            .as_array()
            .map(|a| a.iter().filter_map(|d| d["name"].as_str()).collect())
            .unwrap_or_default();
        assert_eq!(names, ["00:03", "Alpha", "zeta"]);
        assert_eq!(v["available"], false);
        assert_eq!(v["enabled"], false);
    }

    #[test]
    fn follows_property_changes_and_removals() {
        let mut m = sample();
        m.change(BUDS, DEVICE, &props(&[("Connected", Prop::Bool(false))]));
        m.change(BUDS, BATTERY, &props(&[("Percentage", Prop::Int(70))]));
        m.change(HCI, ADAPTER, &props(&[("Powered", Prop::Bool(false))]));
        // Unrelated interfaces and properties are ignored.
        m.change(
            BUDS,
            "org.bluez.MediaControl1",
            &props(&[("Connected", Prop::Bool(true))]),
        );
        m.change(BUDS, DEVICE, &props(&[("RSSI", Prop::Int(-60))]));
        let v = m.view();
        assert_eq!(v["enabled"], false);
        assert_eq!(v["devices"][0]["connected"], false);
        assert_eq!(v["devices"][0]["battery"], 70);
        assert_eq!(v["devices"][0]["name"], "Keza's Buds");

        m.remove(BUDS, &[BATTERY.to_owned()]);
        assert_eq!(m.view()["devices"][0]["battery"], -1);
        m.busy.insert("AC:12:2F:00:11:01".into());
        m.remove(
            BUDS,
            &[
                DEVICE.to_owned(),
                "org.freedesktop.DBus.Properties".to_owned(),
            ],
        );
        assert!(m.busy.is_empty());
        assert_eq!(m.view()["devices"].as_array().map(Vec::len), Some(1));
        m.remove(HCI, &[ADAPTER.to_owned()]);
        assert_eq!(m.view()["available"], false);
    }

    /// Records calls; results are scripted per call.
    #[derive(Debug, Clone, Default)]
    struct FakeIo {
        calls: Arc<Mutex<Vec<String>>>,
        fail: bool,
        hang: bool,
    }

    impl FakeIo {
        fn finish(&self, call: String) -> BoxFuture<'static, OpResult> {
            if let Ok(mut c) = self.calls.lock() {
                c.push(call);
            }
            let (fail, hang) = (self.fail, self.hang);
            async move {
                if hang {
                    std::future::pending::<()>().await;
                }
                if fail { Err("refused".into()) } else { Ok(()) }
            }
            .boxed()
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().map(|c| c.clone()).unwrap_or_default()
        }
    }

    impl BtIo for FakeIo {
        fn set_powered(&self, adapter: &str, on: bool) -> BoxFuture<'static, OpResult> {
            self.finish(format!("powered {adapter} {on}"))
        }
        fn set_connected(&self, device: &str, connect: bool) -> BoxFuture<'static, OpResult> {
            self.finish(format!("connected {device} {connect}"))
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
        let published = Arc::new(Published::new(NAME, sink, Model::default().view()));
        let mut e = Engine::new(io, published);
        e.model = sample();
        e.publish();
        take(&seen);
        (e, seen)
    }

    fn take(p: &Patches) -> Vec<Value> {
        p.lock()
            .map(|mut v| std::mem::take(&mut *v))
            .unwrap_or_default()
    }

    async fn settle_next(e: &mut Engine<FakeIo>) {
        if let Some(done) = e.ops.next().await {
            e.settle(done);
        }
    }

    #[tokio::test]
    async fn toggle_marks_busy_until_the_call_settles() {
        let io = FakeIo::default();
        let (mut e, seen) = engine(io.clone());
        e.toggle_device("AC:12:2F:00:11:02");
        // A second tap while busy and an unknown address do nothing.
        e.toggle_device("AC:12:2F:00:11:02");
        e.toggle_device("FF:FF:FF:FF:FF:FF");
        assert_eq!(io.calls(), [format!("connected {KEYS} true")]);
        let patches = take(&seen);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0]["devices"][1]["busy"], true);
        assert!(patches[0].get("enabled").is_none());

        settle_next(&mut e).await;
        assert_eq!(take(&seen)[0]["devices"][1]["busy"], false);
        // BlueZ then reports the new state; a connected device disconnects.
        e.model
            .change(KEYS, DEVICE, &props(&[("Connected", Prop::Bool(true))]));
        e.toggle_device("AC:12:2F:00:11:02");
        assert_eq!(io.calls()[1], format!("connected {KEYS} false"));
    }

    #[tokio::test]
    async fn failure_and_timeout_clear_busy() {
        let (mut e, seen) = engine(FakeIo {
            fail: true,
            ..FakeIo::default()
        });
        e.toggle_device("AC:12:2F:00:11:01");
        settle_next(&mut e).await;
        assert!(e.model.busy.is_empty());
        assert_eq!(take(&seen).len(), 2);

        let (mut e, _seen) = engine(FakeIo {
            hang: true,
            ..FakeIo::default()
        });
        e.timeout = Duration::from_millis(20);
        e.toggle_device("AC:12:2F:00:11:01");
        assert_eq!(e.model.busy.len(), 1);
        settle_next(&mut e).await;
        assert!(e.model.busy.is_empty());
    }

    #[tokio::test]
    async fn set_enabled_goes_to_the_adapter_and_failure_restores_the_ui() {
        let io = FakeIo::default();
        let (mut e, seen) = engine(io.clone());
        e.set_enabled(false);
        settle_next(&mut e).await;
        assert_eq!(io.calls(), [format!("powered {HCI} false")]);
        assert!(take(&seen).is_empty());

        let (mut e, seen) = engine(FakeIo {
            fail: true,
            ..FakeIo::default()
        });
        e.set_enabled(false);
        settle_next(&mut e).await;
        let patches = take(&seen);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0]["enabled"], true);
        assert!(patches[0]["devices"].is_array());

        // BlueZ gone: everything resets, pending work is dropped.
        e.toggle_device("AC:12:2F:00:11:01");
        e.reset();
        assert!(e.ops.is_empty());
        assert_eq!(e.published.state(), Model::default().view());
        e.set_enabled(true);
        assert!(e.ops.is_empty());
    }

    #[test]
    fn call_validates_arguments() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let svc = Bluetooth {
            published: Arc::new(Published::new(
                NAME,
                Sink::new(|_| {}),
                Model::default().view(),
            )),
            tx,
        };
        assert_eq!(
            svc.state(),
            json!({ "available": false, "enabled": false, "devices": [] })
        );
        assert!(svc.call("setEnabled", &[json!(true)]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::SetEnabled(true))));
        assert!(svc.call("toggleDevice", &[json!("AA:BB")]).is_ok());
        assert!(matches!(rx.try_recv(), Ok(Cmd::ToggleDevice(a)) if a == "AA:BB"));
        assert!(matches!(
            svc.call("setEnabled", &[json!("yes")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("scan", &[]),
            Err(CallError::UnknownMethod(_))
        ));
    }
}
