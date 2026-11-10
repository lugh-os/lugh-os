//! Glue shared by the `power`, `bluetooth` and `display` services: the
//! published-state holder (diff → patch) and thin system-bus helpers.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use futures_util::stream::{SelectAll, select_all};
use serde_json::{Map, Value};
use zbus::zvariant::{self, OwnedValue};
use zbus::{Connection, MatchRule, MessageStream};

use crate::services::Sink;

/// Keys of `new` whose value differs from `old` (or is absent there).
pub(in crate::services) fn diff(
    old: &Map<String, Value>,
    new: &Map<String, Value>,
) -> Map<String, Value> {
    new.iter()
        .filter(|(k, v)| old.get(*k) != Some(*v))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

/// The state the UI has been told about. `publish` sends only what changed.
#[derive(Debug)]
pub(in crate::services) struct Published {
    service: &'static str,
    sink: Sink,
    last: Mutex<Map<String, Value>>,
}

fn object(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

impl Published {
    pub(in crate::services) fn new(service: &'static str, sink: Sink, initial: Value) -> Self {
        Self {
            service,
            sink,
            last: Mutex::new(object(initial)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Map<String, Value>> {
        self.last
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Full current state.
    pub(in crate::services) fn state(&self) -> Value {
        Value::Object(self.lock().clone())
    }

    /// Merges `new` (a JSON object, full or partial) and patches the UI with
    /// the keys that changed.
    pub(in crate::services) fn publish(&self, new: Value) {
        let new = object(new);
        let changed = {
            let mut last = self.lock();
            let changed = diff(&last, &new);
            for (k, v) in &changed {
                last.insert(k.clone(), v.clone());
            }
            changed
        };
        self.sink.patch(self.service, Value::Object(changed));
    }

    /// Records a value without telling the UI (it already shows it:
    /// optimistic sliders).
    pub(in crate::services) fn set_silent(&self, key: &str, value: Value) {
        self.lock().insert(key.to_owned(), value);
    }

    /// Sends the current value of `keys` again: undoes an optimistic UI
    /// update after a call failed.
    pub(in crate::services) fn resend(&self, keys: &[&str]) {
        let data: Map<String, Value> = {
            let last = self.lock();
            keys.iter()
                .filter_map(|k| last.get(*k).map(|v| ((*k).to_owned(), v.clone())))
                .collect()
        };
        self.sink.patch(self.service, Value::Object(data));
    }
}

/// A D-Bus property value reduced to what the services need.
#[derive(Debug, Clone, PartialEq)]
pub(in crate::services) enum Prop {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    /// A list of strings (also: the `Profile` of each entry of an `aa{sv}`).
    List(Vec<String>),
    Other,
}

impl Prop {
    pub(in crate::services) fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub(in crate::services) fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Int(n) => Some(*n),
            _ => None,
        }
    }
    pub(in crate::services) fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Float(f) => Some(*f),
            #[allow(clippy::cast_precision_loss)]
            Self::Int(n) => Some(*n as f64),
            _ => None,
        }
    }
    pub(in crate::services) fn as_str(&self) -> Option<&str> {
        match self {
            Self::Str(s) => Some(s),
            _ => None,
        }
    }
}

/// Property name → value.
pub(in crate::services) type Props = HashMap<String, Prop>;

fn prop(v: &zvariant::Value<'_>) -> Prop {
    use zvariant::Value as V;
    match v {
        V::Bool(b) => Prop::Bool(*b),
        V::U8(n) => Prop::Int(i64::from(*n)),
        V::I16(n) => Prop::Int(i64::from(*n)),
        V::U16(n) => Prop::Int(i64::from(*n)),
        V::I32(n) => Prop::Int(i64::from(*n)),
        V::U32(n) => Prop::Int(i64::from(*n)),
        V::I64(n) => Prop::Int(*n),
        V::U64(n) => Prop::Int(i64::try_from(*n).unwrap_or(i64::MAX)),
        V::F64(f) => Prop::Float(*f),
        V::Str(s) => Prop::Str(s.to_string()),
        V::ObjectPath(p) => Prop::Str(p.to_string()),
        V::Value(inner) => prop(inner),
        V::Array(items) => Prop::List(
            items
                .iter()
                .filter_map(|item| match item {
                    V::Str(s) => Some(s.to_string()),
                    // power-profiles-daemon: [{ "Profile": "balanced", … }, …]
                    V::Dict(_) => HashMap::<String, OwnedValue>::try_from(item.try_clone().ok()?)
                        .ok()?
                        .get("Profile")
                        .and_then(|p| match &**p {
                            V::Str(s) => Some(s.to_string()),
                            _ => None,
                        }),
                    _ => None,
                })
                .collect(),
        ),
        _ => Prop::Other,
    }
}

/// Converts an `a{sv}`.
pub(in crate::services) fn props(raw: &HashMap<String, OwnedValue>) -> Props {
    raw.iter().map(|(k, v)| (k.clone(), prop(v))).collect()
}

/// Merged stream of the signals matching any of `rules`.
pub(in crate::services) async fn signals(
    conn: &Connection,
    rules: Vec<MatchRule<'static>>,
) -> zbus::Result<SelectAll<MessageStream>> {
    let mut streams = Vec::with_capacity(rules.len());
    for rule in rules {
        streams.push(MessageStream::for_match_rule(rule, conn, Some(64)).await?);
    }
    Ok(select_all(streams))
}

/// `NameOwnerChanged` of one well-known name.
pub(in crate::services) fn owner_rule(name: &'static str) -> zbus::Result<MatchRule<'static>> {
    Ok(MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")?
        .interface("org.freedesktop.DBus")?
        .member("NameOwnerChanged")?
        .arg(0, name)?
        .build())
}

/// `PropertiesChanged` of `interface` sent by `sender`, on `path` or (when
/// `path` ends in `/*`) anywhere below it.
pub(in crate::services) fn props_rule(
    sender: &'static str,
    path: &'static str,
    interface: &'static str,
) -> zbus::Result<MatchRule<'static>> {
    let b = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(sender)?
        .interface("org.freedesktop.DBus.Properties")?
        .member("PropertiesChanged")?
        .arg(0, interface)?;
    let b = match path.strip_suffix("/*") {
        Some(ns) => b.path_namespace(ns)?,
        None => b.path(path)?,
    };
    Ok(b.build())
}

/// Whether `name` is on the bus right now (never auto-starts it).
pub(in crate::services) async fn has_owner(conn: &Connection, name: &str) -> bool {
    let reply = conn
        .call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            "NameHasOwner",
            &(name,),
        )
        .await;
    reply
        .ok()
        .and_then(|m| m.body().deserialize::<bool>().ok())
        .unwrap_or(false)
}

/// `Properties.GetAll`.
pub(in crate::services) async fn get_all(
    conn: &Connection,
    dest: &str,
    path: &str,
    interface: &str,
) -> zbus::Result<Props> {
    let reply = conn
        .call_method(
            Some(dest),
            path,
            Some("org.freedesktop.DBus.Properties"),
            "GetAll",
            &(interface,),
        )
        .await?;
    let raw: HashMap<String, OwnedValue> = reply.body().deserialize()?;
    Ok(props(&raw))
}

/// `Properties.Set`.
pub(in crate::services) async fn set_prop(
    conn: &Connection,
    dest: &str,
    path: &str,
    interface: &str,
    name: &str,
    value: zvariant::Value<'_>,
) -> zbus::Result<()> {
    conn.call_method(
        Some(dest),
        path,
        Some("org.freedesktop.DBus.Properties"),
        "Set",
        &(interface, name, value),
    )
    .await
    .map(drop)
}

/// The string arguments of a `NameOwnerChanged`: `(name, old, new)`.
pub(in crate::services) fn owner_change(msg: &zbus::Message) -> Option<(String, String, String)> {
    let h = msg.header();
    (h.member().map(|m| m.as_str()) == Some("NameOwnerChanged"))
        .then(|| msg.body().deserialize::<(String, String, String)>().ok())
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    #[test]
    fn publish_sends_only_changed_keys() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s2 = Arc::clone(&seen);
        let sink = Sink::new(move |e| {
            if let Ok(mut v) = s2.lock() {
                v.push(e.to_json()["d"].clone());
            }
        });
        let p = Published::new("power", sink, json!({ "a": 1, "b": [1] }));
        p.publish(json!({ "a": 1, "b": [1] }));
        p.publish(json!({ "a": 2, "b": [1] }));
        p.set_silent("a", json!(3));
        p.publish(json!({ "a": 3 }));
        p.resend(&["b", "missing"]);
        let seen = seen.lock().map(|v| v.clone()).unwrap_or_default();
        assert_eq!(seen, vec![json!({ "a": 2 }), json!({ "b": [1] })]);
        assert_eq!(p.state(), json!({ "a": 3, "b": [1] }));
    }

    #[test]
    fn converts_variants() {
        use zvariant::Value as V;
        assert_eq!(prop(&V::from(true)), Prop::Bool(true));
        assert_eq!(prop(&V::from(72u8)), Prop::Int(72));
        assert_eq!(prop(&V::from(1.5f64)).as_f64(), Some(1.5));
        assert_eq!(prop(&V::from("x")).as_str(), Some("x"));
        assert_eq!(
            prop(&V::from(vec!["a", "b"])),
            Prop::List(vec!["a".into(), "b".into()])
        );
        assert_eq!(Prop::Int(2).as_bool(), None);
        assert_eq!(Prop::Int(2).as_i64(), Some(2));
    }
}
