//! The D-Bus side of `Services.network`: NetworkManager on the system bus
//! (plus BlueZ adapters for airplane mode). Thin on purpose: it turns signals
//! into [`Input`]s and [`Request`]s into method calls; every decision lives in
//! [`super::model`].

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::{StreamExt, select_all};
use tokio::sync::mpsc::UnboundedSender;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, Message, MessageStream};

use super::Backend;
use super::model::{DeviceFacts, Input, Loaded, RawAp, Request, Security};

const NM: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const SETTINGS_PATH: &str = "/org/freedesktop/NetworkManager/Settings";
const IF_DEVICE: &str = "org.freedesktop.NetworkManager.Device";
const IF_WIRELESS: &str = "org.freedesktop.NetworkManager.Device.Wireless";
const IF_AP: &str = "org.freedesktop.NetworkManager.AccessPoint";
const IF_SETTINGS: &str = "org.freedesktop.NetworkManager.Settings";
const IF_PROFILE: &str = "org.freedesktop.NetworkManager.Settings.Connection";
const IF_PROPS: &str = "org.freedesktop.DBus.Properties";
const IF_DBUS: &str = "org.freedesktop.DBus";
const BLUEZ: &str = "org.bluez";
const IF_ADAPTER: &str = "org.bluez.Adapter1";

const DEVICE_TYPE_WIFI: u32 = 2;
const SEC_WIFI: &str = "802-11-wireless";
const SEC_WIFI_SECURITY: &str = "802-11-wireless-security";

/// Signals queued per subscription while the watcher is busy.
const QUEUE: usize = 256;
/// Pause before reconnecting to a system bus that went away.
const BUS_RETRY: Duration = Duration::from_secs(30);

type Props = HashMap<String, OwnedValue>;
type Settings = HashMap<String, Props>;

fn as_u32(v: &Value<'_>) -> Option<u32> {
    match v {
        Value::U32(n) => Some(*n),
        _ => None,
    }
}
fn as_u8(v: &Value<'_>) -> Option<u8> {
    match v {
        Value::U8(n) => Some(*n),
        _ => None,
    }
}
fn as_bool(v: &Value<'_>) -> Option<bool> {
    match v {
        Value::Bool(b) => Some(*b),
        _ => None,
    }
}
fn as_i64(v: &Value<'_>) -> Option<i64> {
    match v {
        Value::I64(n) => Some(*n),
        _ => None,
    }
}
fn as_string(v: &Value<'_>) -> Option<String> {
    match v {
        Value::Str(s) => Some(s.as_str().to_owned()),
        Value::ObjectPath(p) => Some(p.as_str().to_owned()),
        _ => None,
    }
}
fn as_bytes(v: &Value<'_>) -> Option<Vec<u8>> {
    match v {
        Value::Array(a) => a.iter().map(as_u8).collect(),
        _ => None,
    }
}
fn as_paths(v: &Value<'_>) -> Vec<String> {
    match v {
        Value::Array(a) => a.iter().filter_map(as_string).collect(),
        _ => Vec::new(),
    }
}
/// An object path property, with NetworkManager's "/" (none) as `None`.
fn as_object(v: &Value<'_>) -> Option<String> {
    as_string(v).filter(|p| p != "/")
}

fn prop<T>(props: &Props, key: &str, f: impl Fn(&Value<'_>) -> Option<T>) -> Option<T> {
    props.get(key).and_then(|v| f(v))
}

fn ap_from(props: &Props) -> RawAp {
    RawAp {
        ssid: prop(props, "Ssid", as_bytes)
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default(),
        strength: prop(props, "Strength", as_u8).unwrap_or(0),
        flags: prop(props, "Flags", as_u32).unwrap_or(0),
        wpa: prop(props, "WpaFlags", as_u32).unwrap_or(0),
        rsn: prop(props, "RsnFlags", as_u32).unwrap_or(0),
    }
}

/// SSID of a saved profile, when it is a Wi-Fi profile.
fn profile_ssid(settings: &Settings) -> Option<String> {
    let kind = settings.get("connection")?.get("type")?;
    if as_string(kind)? != SEC_WIFI {
        return None;
    }
    let ssid = as_bytes(settings.get(SEC_WIFI)?.get("ssid")?)?;
    Some(String::from_utf8_lossy(&ssid).into_owned()).filter(|s| !s.is_empty())
}

/// Settings for `AddAndActivateConnection`. NetworkManager completes the rest
/// (mode, ciphers, …) from the access point it is given.
fn new_profile<'a>(
    ssid: &'a str,
    security: Security,
    psk: &'a str,
) -> HashMap<&'static str, HashMap<&'static str, Value<'a>>> {
    let mut all = HashMap::new();
    let mut connection = HashMap::new();
    connection.insert("type", Value::from(SEC_WIFI));
    connection.insert("id", Value::from(ssid));
    all.insert("connection", connection);
    // A lossily decoded SSID would not match the AP: leave it to
    // NetworkManager then.
    if !ssid.contains(char::REPLACEMENT_CHARACTER) {
        let mut wifi = HashMap::new();
        wifi.insert("ssid", Value::from(ssid.as_bytes().to_vec()));
        all.insert(SEC_WIFI, wifi);
    }
    let key_mgmt = match security {
        Security::Psk => Some("wpa-psk"),
        Security::Sae => Some("sae"),
        Security::Owe => Some("owe"),
        Security::Open | Security::Wep | Security::Enterprise => None,
    };
    if let Some(key_mgmt) = key_mgmt {
        let mut sec = HashMap::new();
        sec.insert("key-mgmt", Value::from(key_mgmt));
        if matches!(security, Security::Psk | Security::Sae) {
            sec.insert("psk", Value::from(psk));
        }
        all.insert(SEC_WIFI_SECURITY, sec);
    }
    all
}

fn object_path(path: &str) -> zbus::Result<ObjectPath<'_>> {
    ObjectPath::try_from(path).map_err(zbus::Error::from)
}

async fn get_all(conn: &Connection, dest: &str, path: &str, iface: &str) -> zbus::Result<Props> {
    conn.call_method(Some(dest), path, Some(IF_PROPS), "GetAll", &(iface,))
        .await?
        .body()
        .deserialize()
}

async fn get(conn: &Connection, path: &str, iface: &str, name: &str) -> zbus::Result<OwnedValue> {
    conn.call_method(Some(NM), path, Some(IF_PROPS), "Get", &(iface, name))
        .await?
        .body()
        .deserialize()
}

async fn set_bool(
    conn: &Connection,
    dest: &str,
    path: &str,
    iface: &str,
    name: &str,
    on: bool,
) -> zbus::Result<()> {
    conn.call_method(
        Some(dest),
        path,
        Some(IF_PROPS),
        "Set",
        &(iface, name, Value::from(on)),
    )
    .await
    .map(drop)
}

async fn profile_settings(conn: &Connection, path: &str) -> zbus::Result<Settings> {
    conn.call_method(Some(NM), path, Some(IF_PROFILE), "GetSettings", &())
        .await?
        .body()
        .deserialize()
}

/// The real backend. Holds the system bus connection, made on first use and
/// dropped when the bus goes away.
#[derive(Debug, Default)]
pub(super) struct Nm {
    conn: tokio::sync::Mutex<Option<Connection>>,
}

impl Nm {
    async fn conn(&self) -> zbus::Result<Connection> {
        let mut slot = self.conn.lock().await;
        if let Some(c) = slot.as_ref() {
            return Ok(c.clone());
        }
        let c = Connection::system().await?;
        *slot = Some(c.clone());
        Ok(c)
    }

    async fn forget_conn(&self) {
        *self.conn.lock().await = None;
    }

    async fn exec(&self, req: Request) -> zbus::Result<Vec<Input>> {
        let conn = self.conn().await?;
        match req {
            Request::SetWireless(on) => {
                set_bool(&conn, NM, NM_PATH, NM, "WirelessEnabled", on).await?;
            }
            Request::Scan { device } => {
                let options: HashMap<&str, Value<'_>> = HashMap::new();
                conn.call_method(
                    Some(NM),
                    device.as_str(),
                    Some(IF_WIRELESS),
                    "RequestScan",
                    &(options,),
                )
                .await?;
            }
            Request::Activate {
                device,
                profile,
                ap,
                psk,
                ..
            } => {
                if let Some(psk) = psk
                    && let Err(e) = update_psk(&conn, &profile, &psk).await
                {
                    tracing::warn!(%e, "could not update the saved Wi-Fi password");
                }
                let body = (
                    object_path(&profile)?,
                    object_path(&device)?,
                    object_path(&ap)?,
                );
                conn.call_method(Some(NM), NM_PATH, Some(NM), "ActivateConnection", &body)
                    .await?;
            }
            Request::AddAndActivate {
                attempt,
                device,
                ap,
                ssid,
                security,
                psk,
            } => {
                let body = (
                    new_profile(&ssid, security, &psk),
                    object_path(&device)?,
                    object_path(&ap)?,
                );
                let reply = conn
                    .call_method(
                        Some(NM),
                        NM_PATH,
                        Some(NM),
                        "AddAndActivateConnection",
                        &body,
                    )
                    .await?;
                let (path, _active): (OwnedObjectPath, OwnedObjectPath) =
                    reply.body().deserialize()?;
                return Ok(vec![Input::ProfileCreated {
                    attempt,
                    path: path.as_str().to_owned(),
                }]);
            }
            Request::DeleteProfile(path) => {
                conn.call_method(Some(NM), path.as_str(), Some(IF_PROFILE), "Delete", &())
                    .await?;
            }
            Request::Disconnect { device } => {
                conn.call_method(
                    Some(NM),
                    device.as_str(),
                    Some(IF_DEVICE),
                    "Disconnect",
                    &(),
                )
                .await?;
            }
            Request::BluetoothOff => {
                return Ok(vec![Input::BluetoothWasOn(bluetooth_off(&conn).await)]);
            }
            Request::BluetoothOn(adapters) => {
                for a in adapters {
                    if let Err(e) = set_bool(&conn, BLUEZ, &a, IF_ADAPTER, "Powered", true).await {
                        tracing::debug!(%e, adapter = %a, "could not power Bluetooth on");
                    }
                }
            }
        }
        Ok(Vec::new())
    }
}

impl Backend for Nm {
    async fn run(&self, req: Request) -> Vec<Input> {
        // What the machine must hear when the request is refused.
        let on_error = match &req {
            Request::SetWireless(_) => None, // the real value, read below
            Request::Scan { .. } => Some(Input::ScanFailed),
            Request::Activate { attempt, .. } | Request::AddAndActivate { attempt, .. } => {
                Some(Input::ActivateFailed { attempt: *attempt })
            }
            Request::BluetoothOff => Some(Input::BluetoothWasOn(Vec::new())),
            _ => None,
        };
        let was_set_wireless = matches!(req, Request::SetWireless(_));
        match self.exec(req).await {
            Ok(inputs) => inputs,
            Err(e) => {
                tracing::debug!(%e, "network request failed");
                if was_set_wireless
                    && let Ok(conn) = self.conn().await
                    && let Ok(v) = get(&conn, NM_PATH, NM, "WirelessEnabled").await
                    && let Some(on) = as_bool(&v)
                {
                    return vec![Input::WirelessEnabled(on)];
                }
                on_error.into_iter().collect()
            }
        }
    }
}

/// Stores a new password in a saved WPA-personal profile.
async fn update_psk(conn: &Connection, profile: &str, psk: &str) -> zbus::Result<()> {
    let mut settings = profile_settings(conn, profile).await?;
    let Some(sec) = settings.get_mut(SEC_WIFI_SECURITY) else {
        return Ok(());
    };
    let key_mgmt = prop(sec, "key-mgmt", as_string).unwrap_or_default();
    if key_mgmt != "wpa-psk" && key_mgmt != "sae" {
        return Ok(());
    }
    let value = OwnedValue::try_from(Value::from(psk)).map_err(zbus::Error::from)?;
    sec.insert("psk".to_owned(), value);
    // The password lives in the profile, not in a secret agent's keyring.
    sec.remove("psk-flags");
    conn.call_method(Some(NM), profile, Some(IF_PROFILE), "Update", &(settings,))
        .await
        .map(drop)
}

/// Powers off every Bluetooth adapter and returns those that were on.
/// No BlueZ, no adapters: an empty list.
async fn bluetooth_off(conn: &Connection) -> Vec<String> {
    type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;
    let objects: Objects = match conn
        .call_method(
            Some(BLUEZ),
            "/",
            Some("org.freedesktop.DBus.ObjectManager"),
            "GetManagedObjects",
            &(),
        )
        .await
        .and_then(|m| m.body().deserialize())
    {
        Ok(o) => o,
        Err(e) => {
            tracing::debug!(%e, "no BlueZ; airplane mode covers Wi-Fi only");
            return Vec::new();
        }
    };
    let mut was_on = Vec::new();
    for (path, ifaces) in &objects {
        let powered = ifaces
            .get(IF_ADAPTER)
            .and_then(|p| prop(p, "Powered", as_bool));
        if powered == Some(true) {
            match set_bool(conn, BLUEZ, path.as_str(), IF_ADAPTER, "Powered", false).await {
                Ok(()) => was_on.push(path.as_str().to_owned()),
                Err(e) => tracing::debug!(%e, "could not power Bluetooth off"),
            }
        }
    }
    was_on
}

fn rules() -> zbus::Result<Vec<MatchRule<'static>>> {
    let signal = || MatchRule::builder().msg_type(zbus::message::Type::Signal);
    let mut rules = vec![
        signal()
            .sender(IF_DBUS)?
            .interface(IF_DBUS)?
            .member("NameOwnerChanged")?
            .arg(0, NM)?
            .build(),
        signal()
            .sender(NM)?
            .interface(IF_DEVICE)?
            .member("StateChanged")?
            .build(),
    ];
    // Only the interfaces we read: no wake-ups for IP configs, statistics, …
    for iface in [NM, IF_WIRELESS, IF_AP] {
        rules.push(
            signal()
                .sender(NM)?
                .interface(IF_PROPS)?
                .member("PropertiesChanged")?
                .arg(0, iface)?
                .build(),
        );
    }
    for member in ["DeviceAdded", "DeviceRemoved"] {
        rules.push(signal().sender(NM)?.interface(NM)?.member(member)?.build());
    }
    for iface in [IF_SETTINGS, IF_PROFILE] {
        rules.push(signal().sender(NM)?.interface(iface)?.build());
    }
    Ok(rules)
}

/// Follows NetworkManager for as long as the service lives: loads the facts,
/// then forwards changes. Survives NetworkManager and bus restarts.
pub(super) async fn watch(nm: Arc<Nm>, tx: UnboundedSender<Input>) {
    while !tx.is_closed() {
        match nm.conn().await {
            Ok(conn) => {
                if let Err(e) = follow(&conn, &tx).await {
                    tracing::warn!(%e, "lost the system bus; reconnecting");
                }
                nm.forget_conn().await;
                let _ = tx.send(Input::Gone);
            }
            Err(e) => tracing::debug!(%e, "no system bus yet"),
        }
        tokio::time::sleep(BUS_RETRY).await;
    }
}

async fn follow(conn: &Connection, tx: &UnboundedSender<Input>) -> zbus::Result<()> {
    let mut streams = Vec::new();
    for rule in rules()? {
        streams.push(MessageStream::for_match_rule(rule, conn, Some(QUEUE)).await?);
    }
    let mut signals = select_all(streams);
    let mut w = Watcher {
        conn,
        tx,
        device: None,
        aps: HashSet::new(),
        profiles: HashMap::new(),
    };
    w.reload().await;
    while let Some(msg) = signals.next().await {
        w.on_signal(&msg?).await;
        if tx.is_closed() {
            break;
        }
    }
    Ok(())
}

struct Watcher<'a> {
    conn: &'a Connection,
    tx: &'a UnboundedSender<Input>,
    /// The Wi-Fi device we follow.
    device: Option<String>,
    /// Its access points, as far as the machine knows them.
    aps: HashSet<String>,
    /// Saved Wi-Fi profiles: object path → SSID.
    profiles: HashMap<String, String>,
}

impl Watcher<'_> {
    fn send(&self, input: Input) {
        let _ = self.tx.send(input);
    }

    async fn reload(&mut self) {
        match self.load().await {
            Ok(loaded) => self.send(Input::Loaded(Box::new(loaded))),
            Err(e) => {
                // Usually: NetworkManager is not running. NameOwnerChanged
                // brings us back here when it starts.
                tracing::debug!(%e, "NetworkManager unavailable");
                self.device = None;
                self.aps.clear();
                self.profiles.clear();
                self.send(Input::Gone);
            }
        }
    }

    async fn load(&mut self) -> zbus::Result<Loaded> {
        let conn = self.conn;
        let manager = get_all(conn, NM, NM_PATH, NM).await?;
        let mut loaded = Loaded {
            wireless_enabled: prop(&manager, "WirelessEnabled", as_bool).unwrap_or(false),
            primary_type: prop(&manager, "PrimaryConnectionType", as_string).unwrap_or_default(),
            ..Loaded::default()
        };
        self.device = None;
        self.aps.clear();
        for path in manager
            .get("Devices")
            .map(|v| as_paths(v))
            .unwrap_or_default()
        {
            let kind = get(conn, &path, IF_DEVICE, "DeviceType").await;
            if kind.ok().as_deref().and_then(as_u32) == Some(DEVICE_TYPE_WIFI) {
                self.device = Some(path);
                break;
            }
        }
        if let Some(path) = self.device.clone() {
            let state = get(conn, &path, IF_DEVICE, "State").await?;
            let wifi = get_all(conn, NM, &path, IF_WIRELESS).await?;
            loaded.device = Some(DeviceFacts {
                path,
                state: as_u32(&state).unwrap_or(0),
                active_ap: prop(&wifi, "ActiveAccessPoint", as_object),
                last_scan: prop(&wifi, "LastScan", as_i64).unwrap_or(-1),
            });
            for ap in wifi
                .get("AccessPoints")
                .map(|v| as_paths(v))
                .unwrap_or_default()
            {
                // An AP can vanish between the list and the read: skip it.
                if let Ok(props) = get_all(conn, NM, &ap, IF_AP).await {
                    loaded.aps.push((ap.clone(), ap_from(&props)));
                    self.aps.insert(ap);
                }
            }
        }
        self.profiles.clear();
        let list: Vec<OwnedObjectPath> = conn
            .call_method(
                Some(NM),
                SETTINGS_PATH,
                Some(IF_SETTINGS),
                "ListConnections",
                &(),
            )
            .await?
            .body()
            .deserialize()?;
        for path in list {
            self.read_profile(path.as_str()).await;
        }
        loaded.known = self.known();
        Ok(loaded)
    }

    /// Caches one saved profile (profiles of other kinds are skipped).
    async fn read_profile(&mut self, path: &str) {
        self.profiles.remove(path);
        match profile_settings(self.conn, path).await {
            Ok(s) => {
                if let Some(ssid) = profile_ssid(&s) {
                    self.profiles.insert(path.to_owned(), ssid);
                }
            }
            Err(e) => tracing::debug!(%e, path, "unreadable connection profile"),
        }
    }

    fn known(&self) -> HashMap<String, String> {
        self.profiles
            .iter()
            .map(|(path, ssid)| (ssid.clone(), path.clone()))
            .collect()
    }

    async fn on_signal(&mut self, msg: &Message) {
        let header = msg.header();
        let iface = header.interface().map_or("", |i| i.as_str());
        let member = header.member().map_or("", |m| m.as_str());
        let path = header.path().map_or("", |p| p.as_str());
        let body = msg.body();
        match (iface, member) {
            (IF_DBUS, "NameOwnerChanged") => {
                let Ok((_, _, owner)) = body.deserialize::<(String, String, String)>() else {
                    return;
                };
                if owner.is_empty() {
                    self.device = None;
                    self.aps.clear();
                    self.profiles.clear();
                    self.send(Input::Gone);
                } else {
                    self.reload().await;
                }
            }
            (IF_PROPS, "PropertiesChanged") => {
                if let Ok((iface, changed, _)) = body.deserialize::<(String, Props, Vec<String>)>()
                {
                    self.on_properties(path, &iface, &changed).await;
                }
            }
            (IF_DEVICE, "StateChanged") if self.device.as_deref() == Some(path) => {
                if let Ok((new, old, reason)) = body.deserialize::<(u32, u32, u32)>() {
                    self.send(Input::DeviceState { new, old, reason });
                }
            }
            (NM, "DeviceAdded" | "DeviceRemoved") => {
                // Virtual devices come and go all day: only a Wi-Fi device
                // appearing, or ours leaving, is worth a reload.
                let Ok(device) = body.deserialize::<OwnedObjectPath>() else {
                    return;
                };
                let ours = self.device.as_deref() == Some(device.as_str());
                if (member == "DeviceRemoved" && ours)
                    || (member == "DeviceAdded" && self.device.is_none())
                {
                    self.reload().await;
                }
            }
            (IF_SETTINGS, "NewConnection") => {
                if let Ok(profile) = body.deserialize::<OwnedObjectPath>() {
                    self.read_profile(profile.as_str()).await;
                    self.send(Input::Known(self.known()));
                }
            }
            (IF_SETTINGS, "ConnectionRemoved") => {
                if let Ok(profile) = body.deserialize::<OwnedObjectPath>()
                    && self.profiles.remove(profile.as_str()).is_some()
                {
                    self.send(Input::Known(self.known()));
                }
            }
            (IF_PROFILE, "Updated") => {
                let before = self.profiles.get(path).cloned();
                self.read_profile(path).await;
                if before.as_ref() != self.profiles.get(path) {
                    self.send(Input::Known(self.known()));
                }
            }
            (IF_PROFILE, "Removed") if self.profiles.remove(path).is_some() => {
                self.send(Input::Known(self.known()));
            }
            _ => {}
        }
    }

    async fn on_properties(&mut self, path: &str, iface: &str, changed: &Props) {
        match iface {
            NM if path == NM_PATH => {
                if let Some(on) = prop(changed, "WirelessEnabled", as_bool) {
                    self.send(Input::WirelessEnabled(on));
                }
                if let Some(t) = prop(changed, "PrimaryConnectionType", as_string) {
                    self.send(Input::PrimaryType(t));
                }
            }
            IF_WIRELESS if self.device.as_deref() == Some(path) => {
                if let Some(list) = changed.get("AccessPoints") {
                    self.sync_aps(as_paths(list)).await;
                }
                if let Some(ap) = changed.get("ActiveAccessPoint") {
                    self.send(Input::ActiveAp(as_object(ap)));
                }
                if let Some(t) = prop(changed, "LastScan", as_i64) {
                    self.send(Input::LastScan(t));
                }
            }
            IF_AP if self.aps.contains(path) => {
                let identity = ["Ssid", "Flags", "WpaFlags", "RsnFlags"];
                if identity.iter().any(|k| changed.contains_key(*k)) {
                    if let Ok(props) = get_all(self.conn, NM, path, IF_AP).await {
                        self.send(Input::ApUpsert(path.to_owned(), ap_from(&props)));
                    }
                } else if let Some(s) = prop(changed, "Strength", as_u8) {
                    self.send(Input::ApStrength(path.to_owned(), s));
                }
            }
            _ => {}
        }
    }

    /// Reads the access points that are new in `paths`, forgets the others.
    async fn sync_aps(&mut self, paths: Vec<String>) {
        for path in &paths {
            if !self.aps.contains(path)
                && let Ok(props) = get_all(self.conn, NM, path, IF_AP).await
            {
                self.send(Input::ApUpsert(path.clone(), ap_from(&props)));
            }
        }
        self.aps = paths.iter().cloned().collect();
        self.send(Input::ApPaths(paths));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned(v: Value<'_>) -> OwnedValue {
        OwnedValue::try_from(v).unwrap_or_else(|_| OwnedValue::from(0u8))
    }

    #[test]
    fn access_point_from_properties() {
        let props: Props = HashMap::from([
            (
                "Ssid".to_owned(),
                owned(Value::from(b"Caf\xc3\xa9".to_vec())),
            ),
            ("Strength".to_owned(), owned(Value::from(61u8))),
            ("Flags".to_owned(), owned(Value::from(1u32))),
            ("WpaFlags".to_owned(), owned(Value::from(0u32))),
            ("RsnFlags".to_owned(), owned(Value::from(0x188u32))),
        ]);
        assert_eq!(
            ap_from(&props),
            RawAp {
                ssid: "Café".to_owned(),
                strength: 61,
                flags: 1,
                wpa: 0,
                rsn: 0x188,
            }
        );
        assert_eq!(ap_from(&Props::new()), RawAp::default());
    }

    #[test]
    fn object_paths_and_none() {
        let p = |s: &str| ObjectPath::try_from(s.to_owned()).map(Value::from);
        assert_eq!(p("/").ok().as_ref().and_then(as_object), None);
        assert_eq!(
            p("/a/b").ok().as_ref().and_then(as_object),
            Some("/a/b".to_owned())
        );
    }

    #[test]
    fn saved_profile_ssid() {
        let section = |pairs: Vec<(&str, Value<'_>)>| -> Props {
            pairs
                .into_iter()
                .map(|(k, v)| (k.to_owned(), owned(v)))
                .collect()
        };
        let wifi: Settings = HashMap::from([
            (
                "connection".to_owned(),
                section(vec![("type", Value::from(SEC_WIFI))]),
            ),
            (
                SEC_WIFI.to_owned(),
                section(vec![("ssid", Value::from(b"Home".to_vec()))]),
            ),
        ]);
        assert_eq!(profile_ssid(&wifi), Some("Home".to_owned()));
        let wired: Settings = HashMap::from([(
            "connection".to_owned(),
            section(vec![("type", Value::from("802-3-ethernet"))]),
        )]);
        assert_eq!(profile_ssid(&wired), None);
    }

    #[test]
    fn new_profile_settings() {
        let p = new_profile("Office", Security::Psk, "s3cret");
        assert_eq!(p["connection"]["type"], Value::from(SEC_WIFI));
        assert_eq!(p[SEC_WIFI]["ssid"], Value::from(b"Office".to_vec()));
        assert_eq!(p[SEC_WIFI_SECURITY]["key-mgmt"], Value::from("wpa-psk"));
        assert_eq!(p[SEC_WIFI_SECURITY]["psk"], Value::from("s3cret"));

        let p = new_profile("Office", Security::Sae, "s3cret");
        assert_eq!(p[SEC_WIFI_SECURITY]["key-mgmt"], Value::from("sae"));

        let p = new_profile("Cafe", Security::Open, "");
        assert!(!p.contains_key(SEC_WIFI_SECURITY));

        let p = new_profile("Cafe", Security::Owe, "");
        assert_eq!(p[SEC_WIFI_SECURITY]["key-mgmt"], Value::from("owe"));
        assert!(!p[SEC_WIFI_SECURITY].contains_key("psk"));

        let p = new_profile("bad\u{fffd}", Security::Open, "");
        assert!(!p.contains_key(SEC_WIFI), "undecodable SSID is left to NM");
    }

    #[test]
    fn match_rules_build() {
        assert_eq!(rules().map(|r| r.len()).unwrap_or(0), 9);
    }
}
