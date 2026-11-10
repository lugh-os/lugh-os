//! Pure core of `Services.network`: no I/O, no clock, no D-Bus types.
//!
//! - [`Machine`] reduces [`Input`]s (facts from NetworkManager, UI commands,
//!   timer expiries, results of requests) into [`Effect`]s (requests to the
//!   backend, timers) and a [`View`] (the QML state).
//! - [`Publisher`] turns successive views into patches: only changed keys,
//!   with signal-strength noise damped and rate-limited.

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// At most this many rows in `networks`.
pub(super) const MAX_NETWORKS: usize = 40;
/// A strength must move by at least this much to be published.
pub(super) const STRENGTH_STEP: u8 = 5;
/// Strength-only patches are at least this far apart.
pub(super) const STRENGTH_INTERVAL: Duration = Duration::from_secs(2);
/// `scanning` falls back to false after this long without a new `LastScan`.
pub(super) const SCAN_TIMEOUT: Duration = Duration::from_secs(10);
/// A connection attempt is abandoned after this long.
pub(super) const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

// NM80211ApFlags / NM80211ApSecurityFlags.
const AP_FLAG_PRIVACY: u32 = 0x1;
const SEC_KEY_MGMT_PSK: u32 = 0x100;
const SEC_KEY_MGMT_8021X: u32 = 0x200;
const SEC_KEY_MGMT_SAE: u32 = 0x400;
const SEC_KEY_MGMT_OWE: u32 = 0x800;
const SEC_KEY_MGMT_EAP_SUITE_B: u32 = 0x2000;

// NMDeviceState.
const DEV_PREPARE: u32 = 40;
const DEV_CONFIG: u32 = 50;
const DEV_NEED_AUTH: u32 = 60;
const DEV_SECONDARIES: u32 = 90;
const DEV_ACTIVATED: u32 = 100;
const DEV_FAILED: u32 = 120;

// NMDeviceStateReason.
const REASON_NO_SECRETS: u32 = 7;
const REASON_SUPPLICANT_TIMEOUT: u32 = 11;
const REASON_SSID_NOT_FOUND: u32 = 53;

const TYPE_ETHERNET: &str = "802-3-ethernet";
const TYPE_WIFI: &str = "802-11-wireless";

/// One access point as NetworkManager reports it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct RawAp {
    /// SSID, lossily decoded; empty for hidden networks.
    pub ssid: String,
    /// 0-100.
    pub strength: u8,
    /// `Flags` (NM80211ApFlags).
    pub flags: u32,
    /// `WpaFlags` (NM80211ApSecurityFlags).
    pub wpa: u32,
    /// `RsnFlags` (NM80211ApSecurityFlags).
    pub rsn: u32,
}

/// How an access point is protected, as far as connecting is concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Security {
    /// No encryption, no password.
    Open,
    /// Opportunistic encryption (enhanced open): no password.
    Owe,
    /// WEP: not supported for new profiles.
    Wep,
    /// WPA/WPA2 personal (also WPA2/WPA3 transition).
    Psk,
    /// WPA3 personal only.
    Sae,
    /// 802.1X: needs a profile made elsewhere.
    Enterprise,
}

impl Security {
    /// Classifies an AP from its `Flags`, `WpaFlags` and `RsnFlags`.
    pub(super) fn of(flags: u32, wpa: u32, rsn: u32) -> Self {
        let sec = wpa | rsn;
        if sec & (SEC_KEY_MGMT_8021X | SEC_KEY_MGMT_EAP_SUITE_B) != 0 {
            Self::Enterprise
        } else if sec & SEC_KEY_MGMT_PSK != 0 {
            Self::Psk
        } else if sec & SEC_KEY_MGMT_SAE != 0 {
            Self::Sae
        } else if sec & SEC_KEY_MGMT_OWE != 0 {
            Self::Owe
        } else if flags & AP_FLAG_PRIVACY != 0 || sec != 0 {
            Self::Wep
        } else {
            Self::Open
        }
    }

    /// The `secure` role: a lock in the UI, a password (or sign-in) to join.
    pub(super) fn is_secure(self) -> bool {
        !matches!(self, Self::Open | Self::Owe)
    }
}

/// One row of `Services.network.networks`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Network {
    pub ssid: String,
    pub strength: u8,
    pub secure: bool,
    pub known: bool,
    pub connected: bool,
}

impl Network {
    fn to_json(&self) -> Value {
        json!({
            "ssid": self.ssid,
            "strength": self.strength,
            "secure": self.secure,
            "known": self.known,
            "connected": self.connected,
        })
    }
}

fn sort_networks(rows: &mut [Network]) {
    rows.sort_by(|a, b| {
        b.connected
            .cmp(&a.connected)
            .then(b.strength.cmp(&a.strength))
            .then_with(|| a.ssid.cmp(&b.ssid))
    });
}

/// Builds the `networks` rows: hidden SSIDs dropped, one row per SSID (the
/// strongest AP wins), connected first, then by strength, capped.
pub(super) fn build_networks<'a>(
    aps: impl IntoIterator<Item = &'a RawAp>,
    is_known: impl Fn(&str) -> bool,
    connected_ssid: &str,
) -> Vec<Network> {
    let mut best: HashMap<&str, &RawAp> = HashMap::new();
    for ap in aps {
        if ap.ssid.is_empty() {
            continue;
        }
        let slot = best.entry(ap.ssid.as_str()).or_insert(ap);
        if ap.strength > slot.strength {
            *slot = ap;
        }
    }
    let mut rows: Vec<Network> = best
        .into_values()
        .map(|ap| Network {
            ssid: ap.ssid.clone(),
            strength: ap.strength.min(100),
            secure: Security::of(ap.flags, ap.wpa, ap.rsn).is_secure(),
            known: is_known(&ap.ssid),
            connected: !connected_ssid.is_empty() && ap.ssid == connected_ssid,
        })
        .collect();
    sort_networks(&mut rows);
    rows.truncate(MAX_NETWORKS);
    rows
}

/// Why a connection attempt failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ConnectError {
    /// Wrong or missing password (need-auth, no-secrets, supplicant errors).
    Auth,
    /// The network is not (or no longer) in range.
    NotFound,
    /// Nothing happened for [`CONNECT_TIMEOUT`].
    Timeout,
    /// WEP or 802.1X without a saved profile.
    Unsupported,
    /// Anything else.
    Other,
}

impl ConnectError {
    /// Maps the `reason` of a device that went to the failed state.
    pub(super) fn from_reason(reason: u32) -> Self {
        match reason {
            REASON_NO_SECRETS..=REASON_SUPPLICANT_TIMEOUT => Self::Auth,
            REASON_SSID_NOT_FOUND => Self::NotFound,
            _ => Self::Other,
        }
    }

    /// The user-facing `lastError`. For a protected network every failure
    /// short of "not there" reads like the mock: a wrong password is by far
    /// the usual cause, and NetworkManager often reports it as a timeout.
    pub(super) fn message(self, ssid: &str, secure: bool) -> String {
        let tail = match self {
            Self::NotFound => " It's out of range.",
            Self::Unsupported => " It needs a sign-in this device can't do yet.",
            Self::Auth => " Wrong password?",
            Self::Timeout | Self::Other if secure => " Wrong password?",
            Self::Timeout => " The network didn't respond.",
            Self::Other => "",
        };
        format!("Couldn't connect to {ssid}.{tail}")
    }
}

/// The Wi-Fi device as loaded.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct DeviceFacts {
    /// Object path of the device.
    pub path: String,
    /// NMDeviceState.
    pub state: u32,
    /// Object path of the active AP, if any.
    pub active_ap: Option<String>,
    /// `LastScan` (CLOCK_BOOTTIME ms, -1 never).
    pub last_scan: i64,
}

/// Everything read from NetworkManager in one go.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct Loaded {
    pub wireless_enabled: bool,
    /// `PrimaryConnectionType`, `""` when there is none.
    pub primary_type: String,
    /// The first Wi-Fi device, if the machine has one.
    pub device: Option<DeviceFacts>,
    /// Access points of that device: (object path, AP).
    pub aps: Vec<(String, RawAp)>,
    /// Saved Wi-Fi profiles: SSID → profile object path.
    pub known: HashMap<String, String>,
}

/// A call from the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Command {
    SetWifiEnabled(bool),
    SetAirplaneMode(bool),
    Rescan,
    Connect { ssid: String, password: String },
    Disconnect,
}

/// Which one-shot timer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TimerKind {
    Scan,
    Connect,
}

/// Something that happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Input {
    Command(Command),
    /// NetworkManager left the bus (or was never there).
    Gone,
    /// NetworkManager (re)appeared: the full set of facts.
    Loaded(Box<Loaded>),
    WirelessEnabled(bool),
    PrimaryType(String),
    /// Device state transition.
    DeviceState {
        new: u32,
        old: u32,
        reason: u32,
    },
    ActiveAp(Option<String>),
    LastScan(i64),
    /// An AP appeared or changed.
    ApUpsert(String, RawAp),
    ApStrength(String, u8),
    /// The device's current AP object paths; others are forgotten.
    ApPaths(Vec<String>),
    /// Saved Wi-Fi profiles: SSID → profile object path.
    Known(HashMap<String, String>),
    /// `RequestScan` was refused.
    ScanFailed,
    /// `AddAndActivateConnection` made this profile for attempt `attempt`.
    ProfileCreated {
        attempt: u64,
        path: String,
    },
    /// The activation request itself was refused.
    ActivateFailed {
        attempt: u64,
    },
    /// Bluetooth adapters that were powered before airplane mode cut them.
    BluetoothWasOn(Vec<String>),
    Timeout(TimerKind, u64),
}

/// A request to the system (executed by the backend).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    SetWireless(bool),
    Scan {
        device: String,
    },
    /// Activate a saved profile; `psk` replaces its password first.
    Activate {
        attempt: u64,
        device: String,
        profile: String,
        ap: String,
        psk: Option<String>,
    },
    AddAndActivate {
        attempt: u64,
        device: String,
        ap: String,
        ssid: String,
        security: Security,
        psk: String,
    },
    DeleteProfile(String),
    Disconnect {
        device: String,
    },
    /// Power off every Bluetooth adapter; answers `BluetoothWasOn`.
    BluetoothOff,
    /// Power these adapters back on.
    BluetoothOn(Vec<String>),
}

/// What the driver must do after an input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Effect {
    Io(Request),
    /// Deliver `Input::Timeout(kind, id)` after the duration.
    Timer(TimerKind, u64, Duration),
    /// Send these state keys even if unchanged: the UI set them
    /// optimistically and may be wrong.
    Republish(&'static [&'static str]),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Attempt {
    id: u64,
    ssid: String,
    secure: bool,
    /// Profile made by this attempt (deleted again when it fails).
    created: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Airplane {
    wifi_was_on: bool,
    bluetooth_was_on: Vec<String>,
}

/// The state machine. Feed it [`Input`]s, run the [`Effect`]s, show the
/// [`View`].
#[derive(Debug, Default)]
pub(super) struct Machine {
    present: bool,
    wireless_enabled: bool,
    primary_type: String,
    device: Option<DeviceFacts>,
    aps: BTreeMap<String, RawAp>,
    known: HashMap<String, String>,
    scanning: bool,
    scan_id: u64,
    attempt: Option<Attempt>,
    next_attempt: u64,
    /// Attempts that ended (kept only until their late `ProfileCreated`).
    last_success: u64,
    last_error: String,
    airplane: Option<Airplane>,
}

const WIFI_KEYS: &[&str] = &["wifiEnabled", "connected", "ssid", "strength"];
const AIRPLANE_KEYS: &[&str] = &["airplaneMode", "wifiEnabled", "connected", "ssid"];

impl Machine {
    /// Applies one input.
    pub(super) fn handle(&mut self, input: Input) -> Vec<Effect> {
        let mut fx = Vec::new();
        match input {
            Input::Command(c) => self.command(c, &mut fx),
            Input::Gone => {
                self.present = false;
                self.wireless_enabled = false;
                self.primary_type.clear();
                self.device = None;
                self.aps.clear();
                self.known.clear();
                self.scanning = false;
                if self.attempt.is_some() {
                    self.fail(ConnectError::Other, &mut fx);
                }
            }
            Input::Loaded(l) => {
                let l = *l;
                self.present = true;
                self.wireless_enabled = l.wireless_enabled;
                self.primary_type = l.primary_type;
                self.device = l.device;
                self.aps = l.aps.into_iter().collect();
                self.known = l.known;
                self.scanning = false;
            }
            Input::WirelessEnabled(on) => self.wireless_enabled = on,
            Input::PrimaryType(t) => self.primary_type = t,
            Input::DeviceState { new, old, reason } => {
                if let Some(d) = &mut self.device {
                    d.state = new;
                }
                if self.attempt.is_some() {
                    if new == DEV_FAILED {
                        self.fail(ConnectError::from_reason(reason), &mut fx);
                    } else if new == DEV_NEED_AUTH && old == DEV_CONFIG {
                        // The handshake was rejected and NetworkManager now
                        // waits for new secrets: that is a wrong password.
                        self.fail(ConnectError::Auth, &mut fx);
                    }
                }
            }
            Input::ActiveAp(ap) => {
                if let Some(d) = &mut self.device {
                    d.active_ap = ap;
                }
            }
            Input::LastScan(t) => {
                if let Some(d) = &mut self.device
                    && d.last_scan != t
                {
                    d.last_scan = t;
                    self.scanning = false;
                }
            }
            Input::ApUpsert(path, ap) => {
                self.aps.insert(path, ap);
            }
            Input::ApStrength(path, s) => {
                if let Some(ap) = self.aps.get_mut(&path) {
                    ap.strength = s;
                }
            }
            Input::ApPaths(paths) => self.aps.retain(|p, _| paths.contains(p)),
            Input::Known(known) => self.known = known,
            Input::ScanFailed => self.scanning = false,
            Input::ProfileCreated { attempt, path } => match &mut self.attempt {
                Some(a) if a.id == attempt => a.created = Some(path),
                _ if attempt == self.last_success => {}
                // The attempt already failed or was replaced: no leftovers.
                _ => fx.push(Effect::Io(Request::DeleteProfile(path))),
            },
            Input::ActivateFailed { attempt } => {
                if self.attempt.as_ref().is_some_and(|a| a.id == attempt) {
                    self.fail(ConnectError::Other, &mut fx);
                }
            }
            Input::BluetoothWasOn(adapters) => match &mut self.airplane {
                Some(a) => a.bluetooth_was_on = adapters,
                // Airplane mode ended before the answer came: undo.
                None if !adapters.is_empty() => {
                    fx.push(Effect::Io(Request::BluetoothOn(adapters)));
                }
                None => {}
            },
            Input::Timeout(TimerKind::Scan, id) => {
                if id == self.scan_id {
                    self.scanning = false;
                }
            }
            Input::Timeout(TimerKind::Connect, id) => {
                if self.attempt.as_ref().is_some_and(|a| a.id == id) {
                    self.fail(ConnectError::Timeout, &mut fx);
                }
            }
        }
        self.check_connected();
        fx
    }

    fn command(&mut self, c: Command, fx: &mut Vec<Effect>) {
        match c {
            Command::SetWifiEnabled(on) => {
                if on {
                    // Wi-Fi on means airplane mode is over (Bluetooth stays
                    // as it is: the user asked for Wi-Fi only).
                    self.airplane = None;
                }
                self.set_wireless(on, fx);
                fx.push(Effect::Republish(WIFI_KEYS));
            }
            Command::SetAirplaneMode(true) => {
                if self.airplane.is_none() {
                    self.airplane = Some(Airplane {
                        wifi_was_on: self.wireless_enabled,
                        bluetooth_was_on: Vec::new(),
                    });
                    self.set_wireless(false, fx);
                    fx.push(Effect::Io(Request::BluetoothOff));
                }
                fx.push(Effect::Republish(AIRPLANE_KEYS));
            }
            Command::SetAirplaneMode(false) => {
                if let Some(saved) = self.airplane.take() {
                    if saved.wifi_was_on {
                        self.set_wireless(true, fx);
                    }
                    if !saved.bluetooth_was_on.is_empty() {
                        fx.push(Effect::Io(Request::BluetoothOn(saved.bluetooth_was_on)));
                    }
                }
                fx.push(Effect::Republish(AIRPLANE_KEYS));
            }
            Command::Rescan => {
                if let Some(d) = &self.device
                    && self.present
                    && self.wireless_enabled
                {
                    self.scan_id += 1;
                    self.scanning = true;
                    fx.push(Effect::Io(Request::Scan {
                        device: d.path.clone(),
                    }));
                    fx.push(Effect::Timer(TimerKind::Scan, self.scan_id, SCAN_TIMEOUT));
                }
            }
            Command::Connect { ssid, password } => self.connect(ssid, password, fx),
            Command::Disconnect => {
                if self.attempt.is_some() {
                    self.abandon(fx);
                }
                if let Some(d) = &self.device
                    && d.state >= DEV_PREPARE
                {
                    fx.push(Effect::Io(Request::Disconnect {
                        device: d.path.clone(),
                    }));
                }
            }
        }
    }

    fn set_wireless(&mut self, on: bool, fx: &mut Vec<Effect>) {
        if !on && self.attempt.is_some() {
            self.abandon(fx);
        }
        if !on {
            self.scanning = false;
        }
        // Optimistic, like the UI: NetworkManager confirms with a signal, and
        // the backend reports the real value if the request is refused.
        if self.present {
            self.wireless_enabled = on;
        }
        fx.push(Effect::Io(Request::SetWireless(on)));
    }

    fn connect(&mut self, ssid: String, password: String, fx: &mut Vec<Effect>) {
        if self.attempt.is_some() {
            self.abandon(fx);
        }
        self.last_error.clear();
        if ssid.is_empty() || (self.current_ssid() == ssid) {
            return;
        }
        let target = self
            .aps
            .iter()
            .filter(|(_, ap)| ap.ssid == ssid)
            .max_by_key(|(_, ap)| ap.strength)
            .map(|(path, ap)| (path.clone(), Security::of(ap.flags, ap.wpa, ap.rsn)));
        let device = self.device.as_ref().map(|d| d.path.clone());
        let (Some(device), Some((ap, security)), true) =
            (device, target, self.present && self.wireless_enabled)
        else {
            self.last_error = ConnectError::NotFound.message(&ssid, false);
            return;
        };
        let secure = security.is_secure();
        let id = self.next_attempt + 1;
        let request = if let Some(profile) = self.known.get(&ssid) {
            let personal = matches!(security, Security::Psk | Security::Sae);
            Request::Activate {
                attempt: id,
                device,
                profile: profile.clone(),
                ap,
                psk: (personal && !password.is_empty()).then_some(password),
            }
        } else {
            match security {
                Security::Wep | Security::Enterprise => {
                    self.last_error = ConnectError::Unsupported.message(&ssid, secure);
                    return;
                }
                Security::Psk | Security::Sae if password.is_empty() => {
                    self.last_error = ConnectError::Auth.message(&ssid, secure);
                    return;
                }
                _ => Request::AddAndActivate {
                    attempt: id,
                    device,
                    ap,
                    ssid: ssid.clone(),
                    security,
                    psk: if secure { password } else { String::new() },
                },
            }
        };
        self.next_attempt = id;
        self.attempt = Some(Attempt {
            id,
            ssid,
            secure,
            created: None,
        });
        fx.push(Effect::Io(request));
        fx.push(Effect::Timer(TimerKind::Connect, id, CONNECT_TIMEOUT));
    }

    /// Ends the attempt with an error for the user.
    fn fail(&mut self, error: ConnectError, fx: &mut Vec<Effect>) {
        if let Some(a) = &self.attempt {
            self.last_error = error.message(&a.ssid, a.secure);
        }
        self.abandon(fx);
    }

    /// Ends the attempt quietly: stops a half-way activation and removes the
    /// profile it made.
    fn abandon(&mut self, fx: &mut Vec<Effect>) {
        let Some(a) = self.attempt.take() else {
            return;
        };
        if let Some(d) = &self.device
            && (DEV_PREPARE..=DEV_SECONDARIES).contains(&d.state)
        {
            fx.push(Effect::Io(Request::Disconnect {
                device: d.path.clone(),
            }));
        }
        if let Some(path) = a.created {
            fx.push(Effect::Io(Request::DeleteProfile(path)));
        }
    }

    fn check_connected(&mut self) {
        if let Some(a) = &self.attempt
            && self.current_ssid() == a.ssid
        {
            self.last_success = a.id;
            self.attempt = None;
            self.last_error.clear();
        }
    }

    /// SSID of the activated Wi-Fi connection, `""` when there is none.
    fn current_ssid(&self) -> &str {
        if !(self.present && self.wireless_enabled) {
            return "";
        }
        self.device
            .as_ref()
            .filter(|d| d.state == DEV_ACTIVATED)
            .and_then(|d| d.active_ap.as_ref())
            .and_then(|p| self.aps.get(p))
            .map_or("", |ap| ap.ssid.as_str())
    }

    /// The QML state right now (strengths undamped: see [`Publisher`]).
    pub(super) fn view(&self) -> View {
        let ssid = self.current_ssid();
        let wifi_on = self.present && self.wireless_enabled;
        let strength = self
            .aps
            .values()
            .filter(|ap| !ssid.is_empty() && ap.ssid == ssid)
            .map(|ap| ap.strength.min(100))
            .max()
            .unwrap_or(0);
        let other_link = !self.primary_type.is_empty() && self.primary_type != TYPE_WIFI;
        View {
            wifi_available: self.present && self.device.is_some(),
            wifi_enabled: wifi_on,
            airplane_mode: self.airplane.is_some(),
            wired: self.present && self.primary_type == TYPE_ETHERNET,
            connected: self.present && (!ssid.is_empty() || other_link),
            ssid: ssid.to_owned(),
            strength,
            scanning: self.scanning,
            connecting_ssid: self
                .attempt
                .as_ref()
                .map(|a| a.ssid.clone())
                .unwrap_or_default(),
            last_error: self.last_error.clone(),
            networks: if wifi_on {
                build_networks(self.aps.values(), |s| self.known.contains_key(s), ssid)
            } else {
                Vec::new()
            },
        }
    }
}

/// `Services.network` as typed fields.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct View {
    pub wifi_available: bool,
    pub wifi_enabled: bool,
    pub airplane_mode: bool,
    pub wired: bool,
    pub connected: bool,
    pub ssid: String,
    pub strength: u8,
    pub scanning: bool,
    pub connecting_ssid: String,
    pub last_error: String,
    pub networks: Vec<Network>,
}

impl View {
    fn fields(&self) -> [(&'static str, Value); 11] {
        [
            ("wifiAvailable", self.wifi_available.into()),
            ("wifiEnabled", self.wifi_enabled.into()),
            ("airplaneMode", self.airplane_mode.into()),
            ("wired", self.wired.into()),
            ("connected", self.connected.into()),
            ("ssid", self.ssid.as_str().into()),
            ("strength", self.strength.into()),
            ("scanning", self.scanning.into()),
            ("connectingSsid", self.connecting_ssid.as_str().into()),
            ("lastError", self.last_error.as_str().into()),
            (
                "networks",
                Value::Array(self.networks.iter().map(Network::to_json).collect()),
            ),
        ]
    }

    /// The full state object.
    pub(super) fn to_json(&self) -> Value {
        Value::Object(
            self.fields()
                .into_iter()
                .map(|(k, v)| (k.to_owned(), v))
                .collect(),
        )
    }

    /// Keys of `self` that differ from `old`, plus the `force`d ones.
    pub(super) fn diff(&self, old: &Self, force: &[&str]) -> Map<String, Value> {
        self.fields()
            .into_iter()
            .zip(old.fields())
            .filter(|((k, new), (_, old))| new != old || force.contains(k))
            .map(|((k, new), _)| (k.to_owned(), new))
            .collect()
    }

    /// Same state apart from signal strengths and what follows from them
    /// (row order, rows appearing or leaving).
    fn differs_only_by_signal(&self, old: &Self) -> bool {
        let rest = |v: &Self| Self {
            strength: 0,
            networks: Vec::new(),
            ..v.clone()
        };
        let connected_row = |v: &Self| {
            v.networks
                .iter()
                .find(|n| n.connected)
                .map(|n| n.ssid.clone())
        };
        rest(self) == rest(old) && connected_row(self) == connected_row(old)
    }
}

fn damp(new: u8, old: u8) -> u8 {
    if new.abs_diff(old) < STRENGTH_STEP {
        old
    } else {
        new
    }
}

/// Decides what reaches the UI and when.
#[derive(Debug, Default)]
pub(super) struct Publisher {
    published: View,
    last_signal_patch: Option<Instant>,
}

impl Publisher {
    /// The state the UI has (what a snapshot returns).
    pub(super) fn published(&self) -> &View {
        &self.published
    }

    /// Compares `next` with the published state. Returns the patch to send
    /// now (if any) and, when a strength-only change is being held back, how
    /// long until `update` should be called again.
    pub(super) fn update(
        &mut self,
        mut next: View,
        now: Instant,
        force: &[&str],
    ) -> (Option<Map<String, Value>>, Option<Duration>) {
        // Damp noise: a strength keeps its published value until it has moved
        // by a full step, so neither values nor ordering flap.
        let old = &self.published;
        if next.ssid == old.ssid {
            next.strength = damp(next.strength, old.strength);
        }
        for row in &mut next.networks {
            if let Some(prev) = old.networks.iter().find(|n| n.ssid == row.ssid) {
                row.strength = damp(row.strength, prev.strength);
            }
        }
        sort_networks(&mut next.networks);

        let patch = next.diff(old, force);
        if patch.is_empty() {
            return (None, None);
        }
        let signal_only = force.is_empty() && next.differs_only_by_signal(old);
        if signal_only
            && let Some(last) = self.last_signal_patch
            && let Some(wait) = STRENGTH_INTERVAL.checked_sub(now.saturating_duration_since(last))
            && !wait.is_zero()
        {
            return (None, Some(wait));
        }
        if patch.contains_key("strength") || patch.contains_key("networks") {
            self.last_signal_patch = Some(now);
        }
        self.published = next;
        (Some(patch), None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PSK: u32 = SEC_KEY_MGMT_PSK | 0x8;
    const DEV: &str = "/dev/1";

    fn ap(ssid: &str, strength: u8, rsn: u32) -> RawAp {
        RawAp {
            ssid: ssid.to_owned(),
            strength,
            flags: u32::from(rsn != 0),
            wpa: 0,
            rsn,
        }
    }

    /// Wi-Fi on, connected to "Home" (known), "Cafe" open, "Office" secured.
    fn loaded() -> Loaded {
        Loaded {
            wireless_enabled: true,
            primary_type: TYPE_WIFI.to_owned(),
            device: Some(DeviceFacts {
                path: DEV.to_owned(),
                state: DEV_ACTIVATED,
                active_ap: Some("/ap/1".to_owned()),
                last_scan: 100,
            }),
            aps: vec![
                ("/ap/1".to_owned(), ap("Home", 70, PSK)),
                ("/ap/2".to_owned(), ap("Home", 40, PSK)),
                ("/ap/3".to_owned(), ap("Cafe", 55, 0)),
                ("/ap/4".to_owned(), ap("Office", 80, PSK)),
                ("/ap/5".to_owned(), ap("", 90, PSK)),
            ],
            known: HashMap::from([("Home".to_owned(), "/profile/1".to_owned())]),
        }
    }

    fn machine() -> Machine {
        let mut m = Machine::default();
        assert!(m.handle(Input::Loaded(Box::new(loaded()))).is_empty());
        m
    }

    fn cmd(m: &mut Machine, c: Command) -> Vec<Effect> {
        m.handle(Input::Command(c))
    }

    fn connect(m: &mut Machine, ssid: &str, password: &str) -> Vec<Effect> {
        cmd(
            m,
            Command::Connect {
                ssid: ssid.to_owned(),
                password: password.to_owned(),
            },
        )
    }

    fn io(fx: &[Effect]) -> Vec<&Request> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::Io(r) => Some(r),
                _ => None,
            })
            .collect()
    }

    fn state(m: &mut Machine, new: u32, old: u32, reason: u32) -> Vec<Effect> {
        m.handle(Input::DeviceState { new, old, reason })
    }

    #[test]
    fn security_from_flags() {
        assert_eq!(Security::of(0, 0, 0), Security::Open);
        assert_eq!(Security::of(1, 0, 0), Security::Wep);
        assert_eq!(Security::of(1, 0, PSK), Security::Psk);
        assert_eq!(Security::of(1, PSK, 0), Security::Psk);
        assert_eq!(Security::of(1, 0, SEC_KEY_MGMT_SAE), Security::Sae);
        // WPA2/WPA3 transition joins with a PSK.
        assert_eq!(
            Security::of(1, 0, SEC_KEY_MGMT_SAE | SEC_KEY_MGMT_PSK),
            Security::Psk
        );
        assert_eq!(Security::of(1, 0, SEC_KEY_MGMT_8021X), Security::Enterprise);
        assert_eq!(Security::of(0, 0, SEC_KEY_MGMT_OWE), Security::Owe);
        assert!(!Security::Open.is_secure() && !Security::Owe.is_secure());
        assert!(Security::Psk.is_secure() && Security::Enterprise.is_secure());
    }

    #[test]
    fn networks_dedupe_sort_and_cap() {
        let l = loaded();
        let rows = build_networks(l.aps.iter().map(|(_, a)| a), |s| s == "Home", "Home");
        let names: Vec<&str> = rows.iter().map(|n| n.ssid.as_str()).collect();
        assert_eq!(names, ["Home", "Office", "Cafe"]);
        assert_eq!(rows[0].strength, 70);
        assert!(rows[0].connected && rows[0].known && rows[0].secure);
        assert!(!rows[1].connected && !rows[1].known && rows[1].secure);
        assert!(!rows[2].secure);

        let many: Vec<RawAp> = (0..60u8).map(|i| ap(&format!("n{i}"), i, 0)).collect();
        let rows = build_networks(&many, |_| false, "");
        assert_eq!(rows.len(), MAX_NETWORKS);
        assert_eq!(rows[0].ssid, "n59");
        assert!(rows.iter().all(|n| !n.connected));
    }

    #[test]
    fn view_matches_the_qml_contract() {
        let v = machine().view().to_json();
        assert_eq!(
            v,
            json!({
                "wifiAvailable": true, "wifiEnabled": true, "airplaneMode": false,
                "wired": false, "connected": true, "ssid": "Home", "strength": 70,
                "scanning": false, "connectingSsid": "", "lastError": "",
                "networks": [
                    { "ssid": "Home", "strength": 70, "secure": true, "known": true, "connected": true },
                    { "ssid": "Office", "strength": 80, "secure": true, "known": false, "connected": false },
                    { "ssid": "Cafe", "strength": 55, "secure": false, "known": false, "connected": false },
                ],
            })
        );
        assert!(v["strength"].is_u64() && v["networks"][0]["strength"].is_u64());
    }

    #[test]
    fn absent_and_wired_states() {
        let mut m = Machine::default();
        let v = m.view();
        assert!(!v.wifi_available && !v.connected && v.networks.is_empty());

        m.handle(Input::Loaded(Box::new(Loaded {
            primary_type: TYPE_ETHERNET.to_owned(),
            ..Loaded::default()
        })));
        let v = m.view();
        assert!(v.wired && v.connected && !v.wifi_available && v.ssid.is_empty());

        let mut m = machine();
        m.handle(Input::Gone);
        let v = m.view();
        assert!(!v.wifi_available && !v.wifi_enabled && !v.connected);
        assert!(v.networks.is_empty() && v.ssid.is_empty());
        // …and it comes back by itself.
        m.handle(Input::Loaded(Box::new(loaded())));
        assert!(m.view().connected);
    }

    #[test]
    fn error_messages() {
        assert_eq!(
            ConnectError::Auth.message("Office", true),
            "Couldn't connect to Office. Wrong password?"
        );
        assert_eq!(
            ConnectError::Timeout.message("Office", true),
            "Couldn't connect to Office. Wrong password?"
        );
        assert_eq!(
            ConnectError::Timeout.message("Cafe", false),
            "Couldn't connect to Cafe. The network didn't respond."
        );
        assert_eq!(
            ConnectError::NotFound.message("Cafe", false),
            "Couldn't connect to Cafe. It's out of range."
        );
        assert_eq!(
            ConnectError::Other.message("Cafe", false),
            "Couldn't connect to Cafe."
        );
        assert_eq!(ConnectError::from_reason(7), ConnectError::Auth);
        assert_eq!(ConnectError::from_reason(8), ConnectError::Auth);
        assert_eq!(ConnectError::from_reason(11), ConnectError::Auth);
        assert_eq!(ConnectError::from_reason(53), ConnectError::NotFound);
        assert_eq!(ConnectError::from_reason(1), ConnectError::Other);
    }

    #[test]
    fn connect_known_profile_activates_it() {
        let mut m = machine();
        // Leave "Home" first so it is not the current network.
        state(&mut m, 30, 100, 0);
        let fx = connect(&mut m, "Home", "");
        assert_eq!(
            io(&fx),
            [&Request::Activate {
                attempt: 1,
                device: DEV.to_owned(),
                profile: "/profile/1".to_owned(),
                ap: "/ap/1".to_owned(),
                psk: None,
            }]
        );
        assert!(fx.contains(&Effect::Timer(TimerKind::Connect, 1, CONNECT_TIMEOUT)));
        assert_eq!(m.view().connecting_ssid, "Home");
        state(&mut m, 50, 40, 0);
        assert!(state(&mut m, 100, 90, 0).is_empty());
        let v = m.view();
        assert_eq!((v.connecting_ssid.as_str(), v.ssid.as_str()), ("", "Home"));
        // The timer of a finished attempt changes nothing.
        assert!(m.handle(Input::Timeout(TimerKind::Connect, 1)).is_empty());
        assert_eq!(m.view().last_error, "");
    }

    #[test]
    fn connect_new_network_then_success_keeps_the_profile() {
        let mut m = machine();
        let fx = connect(&mut m, "Office", "s3cret");
        assert_eq!(
            io(&fx),
            [&Request::AddAndActivate {
                attempt: 1,
                device: DEV.to_owned(),
                ap: "/ap/4".to_owned(),
                ssid: "Office".to_owned(),
                security: Security::Psk,
                psk: "s3cret".to_owned(),
            }]
        );
        state(&mut m, 40, 30, 0);
        m.handle(Input::ActiveAp(Some("/ap/4".to_owned())));
        assert_eq!(m.view().connecting_ssid, "Office");
        state(&mut m, 100, 90, 0);
        // The reply to AddAndActivate may come after the device is up.
        let fx = m.handle(Input::ProfileCreated {
            attempt: 1,
            path: "/profile/9".to_owned(),
        });
        assert!(fx.is_empty());
        let v = m.view();
        assert_eq!(
            (v.ssid.as_str(), v.connecting_ssid.as_str()),
            ("Office", "")
        );
        assert!(v.networks[0].connected && v.networks[0].ssid == "Office");
    }

    #[test]
    fn open_network_gets_no_password() {
        let mut m = machine();
        let fx = connect(&mut m, "Cafe", "ignored");
        assert!(matches!(
            io(&fx)[..],
            [Request::AddAndActivate { security: Security::Open, psk, .. }] if psk.is_empty()
        ));
    }

    #[test]
    fn wrong_password_fails_cleans_up_and_explains() {
        let mut m = machine();
        connect(&mut m, "Office", "wrong");
        m.handle(Input::ProfileCreated {
            attempt: 1,
            path: "/profile/9".to_owned(),
        });
        state(&mut m, 40, 30, 0);
        state(&mut m, 50, 40, 0);
        // need-auth after config: rejected handshake.
        let fx = state(&mut m, 60, 50, 0);
        assert_eq!(
            io(&fx),
            [
                &Request::Disconnect {
                    device: DEV.to_owned()
                },
                &Request::DeleteProfile("/profile/9".to_owned()),
            ]
        );
        let v = m.view();
        assert_eq!(v.last_error, "Couldn't connect to Office. Wrong password?");
        assert_eq!(v.connecting_ssid, "");
        // The follow-up failed state does not repeat the cleanup.
        assert!(state(&mut m, 120, 60, 7).is_empty());
    }

    #[test]
    fn failed_state_reasons_and_late_profile() {
        let mut m = machine();
        connect(&mut m, "Office", "pw");
        let fx = state(&mut m, 120, 50, 7);
        assert!(io(&fx).is_empty());
        assert_eq!(
            m.view().last_error,
            "Couldn't connect to Office. Wrong password?"
        );
        // The profile path arrives after the failure: still removed.
        let fx = m.handle(Input::ProfileCreated {
            attempt: 1,
            path: "/profile/9".to_owned(),
        });
        assert_eq!(io(&fx), [&Request::DeleteProfile("/profile/9".to_owned())]);

        connect(&mut m, "Cafe", "");
        assert_eq!(m.view().last_error, "", "a new attempt clears the error");
        state(&mut m, 120, 50, 53);
        assert_eq!(
            m.view().last_error,
            "Couldn't connect to Cafe. It's out of range."
        );
    }

    #[test]
    fn connect_timeout_and_refused_request() {
        let mut m = machine();
        connect(&mut m, "Office", "pw");
        state(&mut m, 50, 40, 0);
        assert!(m.handle(Input::Timeout(TimerKind::Connect, 99)).is_empty());
        let fx = m.handle(Input::Timeout(TimerKind::Connect, 1));
        assert_eq!(
            io(&fx),
            [&Request::Disconnect {
                device: DEV.to_owned()
            }]
        );
        assert_eq!(
            m.view().last_error,
            "Couldn't connect to Office. Wrong password?"
        );

        connect(&mut m, "Cafe", "");
        m.handle(Input::ActivateFailed { attempt: 1 });
        assert_eq!(m.view().connecting_ssid, "Cafe", "stale id is ignored");
        m.handle(Input::ActivateFailed { attempt: 2 });
        let v = m.view();
        assert_eq!(v.connecting_ssid, "");
        assert_eq!(v.last_error, "Couldn't connect to Cafe.");
    }

    #[test]
    fn connect_refused_without_touching_the_system() {
        let mut m = machine();
        assert!(connect(&mut m, "Nowhere", "pw").is_empty());
        assert_eq!(
            m.view().last_error,
            "Couldn't connect to Nowhere. It's out of range."
        );
        assert!(connect(&mut m, "Office", "").is_empty());
        assert_eq!(
            m.view().last_error,
            "Couldn't connect to Office. Wrong password?"
        );
        m.handle(Input::ApUpsert(
            "/ap/7".to_owned(),
            ap("Campus", 60, SEC_KEY_MGMT_8021X),
        ));
        assert!(connect(&mut m, "Campus", "pw").is_empty());
        assert!(
            m.view()
                .last_error
                .starts_with("Couldn't connect to Campus.")
        );
        // Already on it: nothing to do, and the old error goes away.
        assert!(connect(&mut m, "Home", "").is_empty());
        assert_eq!(m.view().last_error, "");
        assert_eq!(m.view().connecting_ssid, "");
    }

    #[test]
    fn known_profile_with_new_password_updates_it() {
        let mut m = machine();
        m.handle(Input::Known(HashMap::from([(
            "Office".to_owned(),
            "/profile/2".to_owned(),
        )])));
        let fx = connect(&mut m, "Office", "new-pw");
        assert!(matches!(
            io(&fx)[..],
            [Request::Activate { profile, psk: Some(p), .. }] if profile == "/profile/2" && p == "new-pw"
        ));
        // A failing saved profile is never deleted.
        let fx = state(&mut m, 120, 50, 7);
        assert!(io(&fx).is_empty());
    }

    #[test]
    fn replacing_an_attempt_removes_its_profile() {
        let mut m = machine();
        connect(&mut m, "Office", "pw");
        m.handle(Input::ProfileCreated {
            attempt: 1,
            path: "/profile/9".to_owned(),
        });
        let fx = connect(&mut m, "Cafe", "");
        assert_eq!(io(&fx)[0], &Request::DeleteProfile("/profile/9".to_owned()));
        assert_eq!(m.view().connecting_ssid, "Cafe");
        assert_eq!(m.view().last_error, "");
    }

    #[test]
    fn rescan_until_last_scan_changes_or_timeout() {
        let mut m = machine();
        let fx = cmd(&mut m, Command::Rescan);
        assert_eq!(
            fx,
            [
                Effect::Io(Request::Scan {
                    device: DEV.to_owned()
                }),
                Effect::Timer(TimerKind::Scan, 1, SCAN_TIMEOUT),
            ]
        );
        assert!(m.view().scanning);
        m.handle(Input::LastScan(100));
        assert!(m.view().scanning, "same LastScan is not a new scan");
        m.handle(Input::LastScan(250));
        assert!(!m.view().scanning);

        cmd(&mut m, Command::Rescan);
        m.handle(Input::Timeout(TimerKind::Scan, 1));
        assert!(m.view().scanning, "an old timer does not end a new scan");
        m.handle(Input::Timeout(TimerKind::Scan, 2));
        assert!(!m.view().scanning);

        cmd(&mut m, Command::Rescan);
        m.handle(Input::ScanFailed);
        assert!(!m.view().scanning);

        m.handle(Input::WirelessEnabled(false));
        assert!(cmd(&mut m, Command::Rescan).is_empty());
        assert!(!m.view().scanning);
    }

    #[test]
    fn wifi_toggle_is_optimistic_and_corrects_the_ui() {
        let mut m = machine();
        let fx = cmd(&mut m, Command::SetWifiEnabled(false));
        assert_eq!(io(&fx), [&Request::SetWireless(false)]);
        assert!(fx.iter().any(|e| matches!(e, Effect::Republish(_))));
        let v = m.view();
        assert!(!v.wifi_enabled && !v.connected && v.ssid.is_empty());
        assert!(v.networks.is_empty());
        // Refused: the backend reports the real value.
        m.handle(Input::WirelessEnabled(true));
        assert!(m.view().wifi_enabled && m.view().connected);
    }

    #[test]
    fn airplane_mode_saves_and_restores() {
        let mut m = machine();
        let fx = cmd(&mut m, Command::SetAirplaneMode(true));
        assert_eq!(
            io(&fx),
            [&Request::SetWireless(false), &Request::BluetoothOff]
        );
        assert!(m.view().airplane_mode && !m.view().wifi_enabled);
        m.handle(Input::BluetoothWasOn(vec!["/org/bluez/hci0".to_owned()]));
        // Twice is once.
        assert!(io(&cmd(&mut m, Command::SetAirplaneMode(true))).is_empty());

        let fx = cmd(&mut m, Command::SetAirplaneMode(false));
        assert_eq!(
            io(&fx),
            [
                &Request::SetWireless(true),
                &Request::BluetoothOn(vec!["/org/bluez/hci0".to_owned()]),
            ]
        );
        assert!(!m.view().airplane_mode && m.view().wifi_enabled);
        assert!(io(&cmd(&mut m, Command::SetAirplaneMode(false))).is_empty());
    }

    #[test]
    fn airplane_mode_keeps_what_was_already_off() {
        let mut m = machine();
        m.handle(Input::WirelessEnabled(false));
        cmd(&mut m, Command::SetAirplaneMode(true));
        m.handle(Input::BluetoothWasOn(Vec::new()));
        let fx = cmd(&mut m, Command::SetAirplaneMode(false));
        assert!(io(&fx).is_empty(), "Wi-Fi and Bluetooth were off before");
        assert!(!m.view().wifi_enabled);
    }

    #[test]
    fn airplane_mode_edge_cases() {
        // Left before Bluetooth answered: adapters are powered again.
        let mut m = machine();
        cmd(&mut m, Command::SetAirplaneMode(true));
        cmd(&mut m, Command::SetAirplaneMode(false));
        let fx = m.handle(Input::BluetoothWasOn(vec!["/a".to_owned()]));
        assert_eq!(io(&fx), [&Request::BluetoothOn(vec!["/a".to_owned()])]);

        // Turning Wi-Fi on ends airplane mode.
        let mut m = machine();
        cmd(&mut m, Command::SetAirplaneMode(true));
        let fx = cmd(&mut m, Command::SetWifiEnabled(true));
        assert_eq!(io(&fx), [&Request::SetWireless(true)]);
        assert!(!m.view().airplane_mode);
    }

    #[test]
    fn disconnect_only_when_there_is_something_to_drop() {
        let mut m = machine();
        let fx = cmd(&mut m, Command::Disconnect);
        assert_eq!(
            io(&fx),
            [&Request::Disconnect {
                device: DEV.to_owned()
            }]
        );
        state(&mut m, 30, 100, 0);
        assert!(!m.view().connected);
        assert!(cmd(&mut m, Command::Disconnect).is_empty());
    }

    #[test]
    fn ap_list_follows_the_device() {
        let mut m = machine();
        m.handle(Input::ApUpsert("/ap/8".to_owned(), ap("New", 99, 0)));
        assert_eq!(m.view().networks[1].ssid, "New");
        m.handle(Input::ApPaths(vec!["/ap/1".to_owned(), "/ap/8".to_owned()]));
        let v = m.view();
        let names: Vec<&str> = v.networks.iter().map(|n| n.ssid.as_str()).collect();
        assert_eq!(names, ["Home", "New"]);
        m.handle(Input::ApStrength("/ap/1".to_owned(), 33));
        assert_eq!(m.view().strength, 33);
    }

    #[test]
    fn patches_carry_only_changed_keys() {
        let mut m = machine();
        let mut p = Publisher::default();
        let t0 = Instant::now();
        let (patch, wait) = p.update(m.view(), t0, &[]);
        let patch = patch.unwrap_or_default();
        assert!(wait.is_none());
        assert!(patch.contains_key("networks") && patch.contains_key("ssid"));
        assert!(
            !patch.contains_key("airplaneMode"),
            "default value unchanged"
        );

        assert_eq!(p.update(m.view(), t0, &[]), (None, None));

        cmd(&mut m, Command::Rescan);
        let (patch, _) = p.update(m.view(), t0, &[]);
        assert_eq!(
            Value::Object(patch.unwrap_or_default()),
            json!({ "scanning": true })
        );

        // Forced keys go out even when unchanged.
        let (patch, _) = p.update(m.view(), t0, &["wifiEnabled"]);
        assert_eq!(
            Value::Object(patch.unwrap_or_default()),
            json!({ "wifiEnabled": true })
        );
        assert_eq!(p.published(), &m.view());
    }

    #[test]
    fn strength_noise_is_damped_and_rate_limited() {
        let mut m = machine();
        let mut p = Publisher::default();
        let t0 = Instant::now();
        p.update(m.view(), t0, &[]);
        let later = t0 + Duration::from_secs(10);

        // ±4 is noise: nothing, not even a pending flush.
        m.handle(Input::ApStrength("/ap/1".to_owned(), 74));
        m.handle(Input::ApStrength("/ap/3".to_owned(), 52));
        assert_eq!(p.update(m.view(), later, &[]), (None, None));

        // A real move is published at once when the last patch is old…
        m.handle(Input::ApStrength("/ap/1".to_owned(), 60));
        let (patch, wait) = p.update(m.view(), later, &[]);
        let patch = patch.unwrap_or_default();
        assert!(wait.is_none());
        assert_eq!(patch["strength"], 60);
        assert_eq!(patch["networks"][0]["strength"], 60);
        assert_eq!(patch["networks"][2]["strength"], 55, "noise kept damped");
        assert_eq!(patch.len(), 2);

        // …and held back when one went out less than 2 s ago.
        m.handle(Input::ApStrength("/ap/1".to_owned(), 50));
        let soon = later + Duration::from_millis(500);
        let (patch, wait) = p.update(m.view(), soon, &[]);
        assert!(patch.is_none());
        assert_eq!(wait, Some(Duration::from_millis(1500)));
        let (patch, wait) = p.update(m.view(), later + STRENGTH_INTERVAL, &[]);
        assert_eq!(patch.unwrap_or_default()["strength"], 50);
        assert!(wait.is_none());
    }

    #[test]
    fn real_changes_are_never_held_back() {
        let mut m = machine();
        let mut p = Publisher::default();
        let t0 = Instant::now();
        p.update(m.view(), t0, &[]);
        // Ordering changes from strength wait for the interval…
        m.handle(Input::ApStrength("/ap/3".to_owned(), 95));
        let (patch, wait) = p.update(m.view(), t0 + Duration::from_millis(100), &[]);
        assert!(patch.is_none() && wait.is_some());
        // …but a state change goes out immediately, with everything pending.
        state(&mut m, 30, 100, 0);
        let (patch, wait) = p.update(m.view(), t0 + Duration::from_millis(200), &[]);
        let patch = patch.unwrap_or_default();
        assert!(wait.is_none());
        assert_eq!(patch["connected"], false);
        assert_eq!(patch["ssid"], "");
        assert_eq!(patch["networks"][0]["ssid"], "Cafe");
        assert_eq!(patch["networks"][0]["strength"], 95);
    }
}
