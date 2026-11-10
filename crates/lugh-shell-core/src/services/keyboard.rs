//! `Services.keyboard`: layouts, the active one, Caps Lock.
//!
//! State: `layouts` (short codes: `["us", "fr"]`), `current`, `capsLock`.
//! Methods: `next()`, `refresh()`.
//!
//! Under Hyprland the truth is `j/devices` (the main keyboard's `layout`,
//! `active_layout_index` / `active_keymap`, `capsLock`). It is read at start,
//! on every socket2 `activelayout` event and on `keyboard.refresh` (the
//! Caps Lock OSD path calls it). `next()` is `switchxkblayout all next`
//! (a hyprctl request, not a dispatcher, so it keeps its form under 0.55).
//!
//! Elsewhere the layouts come once from `XKB_DEFAULT_LAYOUT`, else from
//! `localectl status`; there is nothing to switch and `capsLock` is false.
//!
//! Nothing polls: the event socket is read asynchronously and the service
//! sleeps until Hyprland writes to it.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::io::AsyncBufReadExt as _;

use super::{CallError, Context, Service, Sink};
use crate::wm::WmEvent;
use crate::wm::hyprland::{EVENT_SOCKET, HyprlandAdapter, parse_event};

const NAME: &str = "keyboard";
/// Hyprland request that cycles the layout of every keyboard.
const NEXT_LAYOUT: &str = "switchxkblayout all next";

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let hyprland = HyprlandAdapter::from_env().ok().map(Arc::new);
    let inner = Arc::new(Inner {
        sink: ctx.sink.clone(),
        runtime: ctx.runtime.clone(),
        hyprland,
        state: Mutex::new(env_layouts(
            std::env::var("XKB_DEFAULT_LAYOUT").ok().as_deref(),
        )),
    });
    match &inner.hyprland {
        Some(_) => {
            inner.refresh();
            ctx.runtime.spawn(watch_events(Arc::clone(&inner)));
        }
        None => {
            if inner.snapshot().layouts.is_empty() {
                ctx.runtime.spawn(read_localectl(Arc::clone(&inner)));
            }
        }
    }
    Box::new(KeyboardService(inner))
}

/// The QML-visible state.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct KbState {
    layouts: Vec<String>,
    current: String,
    caps_lock: bool,
}

impl KbState {
    fn json(&self) -> Map<String, Value> {
        match json!({
            "layouts": self.layouts,
            "current": self.current,
            "capsLock": self.caps_lock,
        }) {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }

    fn diff(&self, old: &Self) -> Map<String, Value> {
        let old = old.json();
        self.json()
            .into_iter()
            .filter(|(k, v)| old.get(k) != Some(v))
            .collect()
    }
}

/// `"us, fr(azerty)"` → `["us", "fr"]`: codes only, no variants, no blanks.
fn split_layouts(list: &str) -> Vec<String> {
    list.split(',')
        .map(|l| l.split('(').next().unwrap_or_default().trim().to_owned())
        .filter(|l| !l.is_empty())
        .collect()
}

fn with_layouts(layouts: Vec<String>) -> KbState {
    KbState {
        current: layouts.first().cloned().unwrap_or_default(),
        layouts,
        caps_lock: false,
    }
}

/// State from `XKB_DEFAULT_LAYOUT`.
fn env_layouts(var: Option<&str>) -> KbState {
    with_layouts(split_layouts(var.unwrap_or_default()))
}

/// Layouts from `localectl status` output (`X11 Layout: us,fr`).
fn parse_localectl(output: &str) -> Vec<String> {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix("X11 Layout:"))
        .map(split_layouts)
        .filter(|l| l.iter().all(|code| code != "n/a" && code != "(unset)"))
        .unwrap_or_default()
}

/// Language names xkb uses at the start of a layout description, for
/// Hyprland builds whose `j/devices` has no `active_layout_index`.
const DESCRIPTIONS: &[(&str, &str)] = &[
    ("us", "English (US"),
    ("gb", "English (UK"),
    ("fr", "French"),
    ("de", "German"),
    ("es", "Spanish"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("br", "Portuguese (Brazil"),
    ("be", "Belgian"),
    ("ch", "German (Switzerland"),
    ("ca", "French (Canada"),
    ("nl", "Dutch"),
    ("se", "Swedish"),
    ("no", "Norwegian"),
    ("dk", "Danish"),
    ("fi", "Finnish"),
    ("pl", "Polish"),
    ("ru", "Russian"),
    ("ua", "Ukrainian"),
    ("tr", "Turkish"),
    ("ara", "Arabic"),
    ("ke", "Swahili (Kenya"),
    ("tz", "Swahili (Tanzania"),
    ("rw", "Kinyarwanda"),
    ("ng", "English (Nigeria"),
    ("za", "English (South Africa"),
    ("gh", "English (Ghana"),
    ("et", "Amharic"),
];

/// Index of the configured layout a keymap description belongs to: the
/// longest known description prefix among the configured codes wins.
fn index_by_description(layouts: &[String], keymap: &str) -> Option<usize> {
    layouts
        .iter()
        .enumerate()
        .filter_map(|(i, code)| {
            DESCRIPTIONS
                .iter()
                .filter(|(c, prefix)| c == code && keymap.starts_with(prefix))
                .map(|(_, prefix)| prefix.len())
                .max()
                .map(|len| (len, i))
        })
        .max_by_key(|&(len, _)| len)
        .map(|(_, i)| i)
}

/// State from Hyprland's `j/devices` reply. `None` when it has no keyboard.
/// The main keyboard is the one flagged `main`, else the first.
fn parse_devices(devices: &str) -> Option<KbState> {
    let v: Value = serde_json::from_str(devices).ok()?;
    let keyboards = v.get("keyboards")?.as_array()?;
    let kb = keyboards
        .iter()
        .find(|k| k.get("main").and_then(Value::as_bool) == Some(true))
        .or_else(|| keyboards.first())?;
    let layouts = split_layouts(kb.get("layout").and_then(Value::as_str).unwrap_or_default());
    let keymap = kb
        .get("active_keymap")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let index = kb
        .get("active_layout_index")
        .and_then(Value::as_u64)
        .and_then(|i| usize::try_from(i).ok())
        .filter(|&i| i < layouts.len())
        .or_else(|| index_by_description(&layouts, keymap))
        .unwrap_or(0);
    Some(KbState {
        current: layouts.get(index).cloned().unwrap_or_default(),
        layouts,
        caps_lock: kb.get("capsLock").and_then(Value::as_bool).unwrap_or(false),
    })
}

struct Inner {
    sink: Sink,
    runtime: tokio::runtime::Handle,
    hyprland: Option<Arc<HyprlandAdapter>>,
    state: Mutex<KbState>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("keyboard::Inner")
            .field("hyprland", &self.hyprland.is_some())
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

impl Inner {
    fn snapshot(&self) -> KbState {
        match self.state.lock() {
            Ok(s) => s.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    /// Replaces the state and patches the keys that changed.
    fn set(&self, new: KbState) {
        let mut state = match self.state.lock() {
            Ok(s) => s,
            Err(poisoned) => poisoned.into_inner(),
        };
        let diff = new.diff(&state);
        *state = new;
        self.sink.patch(NAME, Value::Object(diff));
    }

    /// Re-reads `j/devices` on a blocking thread (the adapter's socket round
    /// trip is synchronous).
    fn refresh(self: &Arc<Self>) {
        let Some(adapter) = self.hyprland.clone() else {
            return;
        };
        let inner = Arc::clone(self);
        self.runtime
            .spawn_blocking(move || match adapter.request("j/devices") {
                Ok(reply) => match parse_devices(&reply) {
                    Some(state) => inner.set(state),
                    None => tracing::debug!("Hyprland reports no keyboard"),
                },
                Err(e) => tracing::debug!(%e, "could not read keyboards from Hyprland"),
            });
    }

    fn next(self: &Arc<Self>) {
        let Some(adapter) = self.hyprland.clone() else {
            return;
        };
        self.runtime.spawn_blocking(move || {
            // The `activelayout` event that follows updates the state.
            match adapter.request(NEXT_LAYOUT) {
                Ok(reply) if reply.trim() == "ok" => {}
                Ok(reply) => tracing::warn!(reply = reply.trim(), "layout switch refused"),
                Err(e) => tracing::warn!(%e, "layout switch failed"),
            }
        });
    }
}

/// Reads socket2 and refreshes on `activelayout`. Reconnects with a growing
/// pause; gives up when the compositor stays away (the session is ending).
async fn watch_events(inner: Arc<Inner>) {
    let Some(adapter) = inner.hyprland.clone() else {
        return;
    };
    let path = adapter.socket_dir().join(EVENT_SOCKET);
    let mut failures = 0u32;
    while failures < 6 {
        match tokio::net::UnixStream::connect(&path).await {
            Ok(stream) => {
                if failures > 0 {
                    inner.refresh(); // we may have missed a switch
                }
                failures = 0;
                let mut lines = tokio::io::BufReader::new(stream).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if matches!(parse_event(&line), WmEvent::Unknown { name, .. } if name == "activelayout")
                    {
                        inner.refresh();
                    }
                }
            }
            Err(e) => tracing::debug!(%e, "Hyprland event socket unavailable"),
        }
        failures += 1;
        tokio::time::sleep(Duration::from_millis(250) * 2u32.pow(failures)).await;
    }
    tracing::warn!("Hyprland event socket is gone; keyboard layout changes are no longer tracked");
}

/// Not under Hyprland and no `XKB_DEFAULT_LAYOUT`: ask systemd-localed once.
async fn read_localectl(inner: Arc<Inner>) {
    let run = tokio::process::Command::new("localectl")
        .arg("status")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let Ok(Ok(out)) = tokio::time::timeout(Duration::from_secs(5), run).await else {
        tracing::debug!("localectl unavailable; keyboard layouts unknown");
        return;
    };
    let layouts = parse_localectl(&String::from_utf8_lossy(&out.stdout));
    if !layouts.is_empty() {
        inner.set(with_layouts(layouts));
    }
}

/// The `keyboard` service.
#[derive(Debug)]
struct KeyboardService(Arc<Inner>);

impl Service for KeyboardService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        Value::Object(self.0.snapshot().json())
    }

    fn call(&self, method: &str, _args: &[Value]) -> Result<Value, CallError> {
        match method {
            "next" => self.0.next(),
            "refresh" => self.0.refresh(),
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::Event;

    const DEVICES: &str = r#"{
        "mice": [],
        "keyboards": [
            {"address":"0x1","name":"power-button","layout":"us","active_keymap":"English (US)","capsLock":false,"main":false},
            {"address":"0x2","name":"at-translated-set-2-keyboard","rules":"","model":"","layout":"us,fr","variant":"","options":"",
             "active_keymap":"French","capsLock":true,"numLock":false,"main":true}
        ],
        "tablets": [], "touch": [], "switches": []
    }"#;

    #[test]
    fn devices_main_keyboard_by_description() {
        assert_eq!(
            parse_devices(DEVICES),
            Some(KbState {
                layouts: vec!["us".into(), "fr".into()],
                current: "fr".into(),
                caps_lock: true,
            })
        );
    }

    #[test]
    fn devices_index_wins_over_description() {
        let json = r#"{"keyboards":[{"layout":"us, de(nodeadkeys) ,rw","active_keymap":"Something unknown",
            "active_layout_index":2,"capsLock":false}]}"#;
        let s = parse_devices(json).unwrap_or_default();
        assert_eq!(s.layouts, ["us", "de", "rw"]);
        assert_eq!(s.current, "rw");
        // An index out of range or an unknown description: the first layout.
        let json = r#"{"keyboards":[{"layout":"us,fr","active_keymap":"Klingon","active_layout_index":7}]}"#;
        assert_eq!(parse_devices(json).unwrap_or_default().current, "us");
    }

    #[test]
    fn devices_without_keyboards_or_garbage() {
        assert_eq!(parse_devices(r#"{"keyboards":[]}"#), None);
        assert_eq!(parse_devices("unknown request"), None);
        assert_eq!(parse_devices("{}"), None);
    }

    #[test]
    fn descriptions_pick_the_most_specific_layout() {
        let l = |codes: &[&str]| codes.iter().map(|c| (*c).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            index_by_description(&l(&["us", "fr"]), "English (US)"),
            Some(0)
        );
        assert_eq!(
            index_by_description(&l(&["us", "gb"]), "English (UK)"),
            Some(1)
        );
        assert_eq!(
            index_by_description(&l(&["pt", "br"]), "Portuguese (Brazil)"),
            Some(1)
        );
        assert_eq!(
            index_by_description(&l(&["br", "pt"]), "Portuguese"),
            Some(1)
        );
        assert_eq!(index_by_description(&l(&["us", "fr"]), "Klingon"), None);
    }

    #[test]
    fn fallback_sources() {
        assert_eq!(
            env_layouts(Some("us,fr")),
            KbState {
                layouts: vec!["us".into(), "fr".into()],
                current: "us".into(),
                caps_lock: false,
            }
        );
        assert_eq!(env_layouts(None), KbState::default());
        assert_eq!(env_layouts(Some(" , ")), KbState::default());
        let status = "System Locale: LANG=en_US.UTF-8\n    VC Keymap: us\n   X11 Layout: us,fr\n    X11 Model: pc105\n";
        assert_eq!(parse_localectl(status), ["us", "fr"]);
        assert!(parse_localectl("   X11 Layout: (unset)\n").is_empty());
        assert!(parse_localectl("   X11 Layout: n/a\n").is_empty());
        assert!(parse_localectl("nothing here").is_empty());
    }

    #[test]
    fn patches_carry_only_changed_keys() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap_or_else(|e| panic!("runtime: {e}"));
        let (tx, rx) = std::sync::mpsc::channel();
        let inner = Arc::new(Inner {
            sink: Sink::new(move |e| {
                let _ = tx.send(e);
            }),
            runtime: rt.handle().clone(),
            hyprland: None,
            state: Mutex::new(env_layouts(Some("us,fr"))),
        });
        let svc = KeyboardService(Arc::clone(&inner));
        assert_eq!(
            svc.state(),
            json!({ "layouts": ["us", "fr"], "current": "us", "capsLock": false })
        );
        let mut s = inner.snapshot();
        s.current = "fr".into();
        inner.set(s.clone());
        assert_eq!(
            rx.try_recv().ok(),
            Some(Event::Patch {
                service: "keyboard",
                data: json!({ "current": "fr" })
                    .as_object()
                    .cloned()
                    .unwrap_or_default(),
            })
        );
        inner.set(s);
        assert!(rx.try_recv().is_err());
        // Without Hyprland the calls are accepted and do nothing.
        assert_eq!(svc.call("next", &[]), Ok(Value::Null));
        assert_eq!(svc.call("refresh", &[]), Ok(Value::Null));
        assert!(matches!(
            svc.call("prev", &[]),
            Err(CallError::UnknownMethod(_))
        ));
        assert!(rx.try_recv().is_err());
    }
}
