//! The notification store: pure state, no I/O, no clock of its own (every
//! mutating method takes `now_ms`, so tests inject time).
//!
//! Lifetime rules (freedesktop spec 1.2, applied to a shell with a history):
//!
//! - A notification is **open** while it sits in `popups` or in `history`.
//!   `NotificationClosed` is reported exactly once, when it has left both.
//! - `expire` removes the toast only. If the row is also in the history it
//!   stays open (the user can still act on it there): no signal. If it is not
//!   (`transient` hint, or pushed out by the history cap) it is closed with
//!   reason 1 (expired).
//! - `dismiss` / `clear_all` remove from both lists: reason 2 (dismissed).
//! - `close` (the `CloseNotification` D-Bus call) removes from both: reason 3.
//! - The history holds [`HISTORY_CAP`] rows; the oldest is dropped. A dropped
//!   row that has no toast any more is closed with reason 1.
//! - `replaces_id` updates the row in place where it exists (toast and
//!   history keep their position) and pops it again when its toast was gone.
//! - Do Not Disturb: no toast unless urgency is critical (2). A `transient`
//!   notification that may not pop is not kept at all (closed, reason 1).
//! - `resident`: invoking an action does not remove the notification; only
//!   its toast goes away.

use serde_json::{Value, json};

/// Rows kept in the history.
pub(crate) const HISTORY_CAP: usize = 200;
/// Toasts kept in the model (the UI shows 3; the rest queue behind them).
pub(crate) const POPUP_CAP: usize = 20;
const SUMMARY_MAX: usize = 200;
const BODY_MAX: usize = 2000;
const NAME_MAX: usize = 100;
const PATH_MAX: usize = 4096;
const ACTIONS_MAX: usize = 8;

/// `NotificationClosed` reason: the toast timed out.
pub(crate) const REASON_EXPIRED: u32 = 1;
/// `NotificationClosed` reason: the user dismissed it.
pub(crate) const REASON_DISMISSED: u32 = 2;
/// `NotificationClosed` reason: `CloseNotification` was called.
pub(crate) const REASON_CLOSED: u32 = 3;

/// A notification as posted (already parsed, not yet sanitized).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Incoming {
    pub(crate) app_name: String,
    /// `0` = new notification.
    pub(crate) replaces_id: u32,
    /// Final icon (name, path or URL); see `hints::resolve_icon`.
    pub(crate) app_icon: String,
    pub(crate) summary: String,
    pub(crate) body: String,
    /// `(key, label)` pairs.
    pub(crate) actions: Vec<(String, String)>,
    /// 0 low, 1 normal, 2 critical.
    pub(crate) urgency: u8,
    /// URL or `""`.
    pub(crate) image: String,
    pub(crate) transient: bool,
    pub(crate) resident: bool,
    /// `false` when the app's banners are switched off (`per_app`).
    pub(crate) banners: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Note {
    nid: u32,
    app_name: String,
    app_icon: String,
    summary: String,
    body: String,
    urgency: u8,
    time_ms: u64,
    /// JSON string of `[{key,label}]`, like the QML mock.
    actions: String,
    image: String,
    resident: bool,
}

impl Note {
    fn to_json(&self) -> Value {
        json!({
            "nid": self.nid,
            "appName": self.app_name,
            "appIcon": self.app_icon,
            "summary": self.summary,
            "body": self.body,
            "urgency": self.urgency,
            "time": self.time_ms,
            "actions": self.actions,
            "image": self.image,
        })
    }
}

/// What one operation changed; the service turns it into patches and D-Bus
/// signals.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Effects {
    pub(crate) popups: bool,
    pub(crate) history: bool,
    /// `(id, reason)` for `NotificationClosed`.
    pub(crate) closed: Vec<(u32, u32)>,
}

/// Popups and history, newest first.
#[derive(Debug, Default)]
pub(crate) struct Store {
    dnd: bool,
    popups: Vec<Note>,
    history: Vec<Note>,
    last_id: u32,
}

impl Store {
    pub(crate) fn new(dnd: bool) -> Self {
        Self {
            dnd,
            ..Self::default()
        }
    }

    pub(crate) fn dnd(&self) -> bool {
        self.dnd
    }

    /// Returns `true` when the value changed.
    pub(crate) fn set_dnd(&mut self, on: bool) -> bool {
        let changed = self.dnd != on;
        self.dnd = on;
        changed
    }

    pub(crate) fn popups_json(&self) -> Value {
        Value::Array(self.popups.iter().map(Note::to_json).collect())
    }

    pub(crate) fn history_json(&self) -> Value {
        Value::Array(self.history.iter().map(Note::to_json).collect())
    }

    fn is_open(&self, nid: u32) -> bool {
        self.popups.iter().any(|n| n.nid == nid) || self.history.iter().any(|n| n.nid == nid)
    }

    /// Ids stay within the positive `int` range of the QML `nid` role and are
    /// never reused while still open.
    fn next_id(&mut self) -> u32 {
        loop {
            self.last_id = if self.last_id >= i32::MAX as u32 {
                1
            } else {
                self.last_id + 1
            };
            if !self.is_open(self.last_id) {
                return self.last_id;
            }
        }
    }

    /// Adds or replaces a notification. Returns its id.
    pub(crate) fn insert(&mut self, n: Incoming, now_ms: u64, fx: &mut Effects) -> u32 {
        // A replaces_id we do not know keeps the id the client asked for (what
        // `notify-send -r` users expect), unless it cannot be a QML int.
        let nid = if n.replaces_id != 0 && n.replaces_id <= i32::MAX as u32 {
            n.replaces_id
        } else {
            self.next_id()
        };
        let note = Note {
            nid,
            app_name: clean_line(&n.app_name, NAME_MAX),
            app_icon: clean_line(&n.app_icon, PATH_MAX),
            summary: clean_line(&n.summary, SUMMARY_MAX),
            body: clean_text(&n.body, BODY_MAX),
            urgency: n.urgency.min(2),
            time_ms: now_ms,
            actions: actions_json(&n.actions),
            image: clean_line(&n.image, PATH_MAX),
            resident: n.resident,
        };
        let may_pop = n.banners && (!self.dnd || note.urgency == 2);

        if let Some(row) = self.popups.iter_mut().find(|r| r.nid == nid) {
            *row = note.clone();
            fx.popups = true;
        } else if may_pop {
            self.popups.insert(0, note.clone());
            fx.popups = true;
            while self.popups.len() > POPUP_CAP {
                if let Some(old) = self.popups.pop() {
                    self.closed_if_gone(old.nid, REASON_EXPIRED, fx);
                }
            }
        }

        if let Some(pos) = self.history.iter().position(|r| r.nid == nid) {
            if n.transient {
                self.history.remove(pos);
            } else {
                self.history[pos] = note;
            }
            fx.history = true;
        } else if !n.transient {
            self.history.insert(0, note);
            fx.history = true;
            while self.history.len() > HISTORY_CAP {
                if let Some(old) = self.history.pop() {
                    self.closed_if_gone(old.nid, REASON_EXPIRED, fx);
                }
            }
        }
        // Transient and not allowed to pop: it was never shown anywhere.
        self.closed_if_gone(nid, REASON_EXPIRED, fx);
        nid
    }

    fn closed_if_gone(&self, nid: u32, reason: u32, fx: &mut Effects) {
        if !self.is_open(nid) {
            fx.closed.push((nid, reason));
        }
    }

    fn remove_popup(&mut self, nid: u32, fx: &mut Effects) -> bool {
        let Some(pos) = self.popups.iter().position(|r| r.nid == nid) else {
            return false;
        };
        self.popups.remove(pos);
        fx.popups = true;
        true
    }

    fn remove_history(&mut self, nid: u32, fx: &mut Effects) -> bool {
        let Some(pos) = self.history.iter().position(|r| r.nid == nid) else {
            return false;
        };
        self.history.remove(pos);
        fx.history = true;
        true
    }

    /// The toast timed out: it leaves `popups` and stays in the history.
    pub(crate) fn expire(&mut self, nid: u32, fx: &mut Effects) {
        if self.remove_popup(nid, fx) {
            self.closed_if_gone(nid, REASON_EXPIRED, fx);
        }
    }

    /// Removes from both lists with `reason` (dismissed or closed by call).
    pub(crate) fn remove(&mut self, nid: u32, reason: u32, fx: &mut Effects) {
        let a = self.remove_popup(nid, fx);
        let b = self.remove_history(nid, fx);
        if a || b {
            fx.closed.push((nid, reason));
        }
    }

    /// Empties both lists (reason 2 for each notification).
    pub(crate) fn clear_all(&mut self, fx: &mut Effects) {
        let mut ids: Vec<u32> = self.popups.iter().map(|n| n.nid).collect();
        ids.extend(self.history.iter().map(|n| n.nid));
        ids.sort_unstable();
        ids.dedup();
        fx.popups |= !self.popups.is_empty();
        fx.history |= !self.history.is_empty();
        self.popups.clear();
        self.history.clear();
        fx.closed
            .extend(ids.into_iter().map(|id| (id, REASON_DISMISSED)));
    }

    /// The user chose an action. Returns `false` when the notification is
    /// gone (nothing to invoke). A `resident` notification only loses its
    /// toast; any other is dismissed.
    pub(crate) fn action_invoked(&mut self, nid: u32, fx: &mut Effects) -> bool {
        let resident = self
            .popups
            .iter()
            .chain(self.history.iter())
            .find(|n| n.nid == nid)
            .map(|n| n.resident);
        match resident {
            None => false,
            Some(true) => {
                self.expire(nid, fx);
                true
            }
            Some(false) => {
                self.remove(nid, REASON_DISMISSED, fx);
                true
            }
        }
    }
}

/// `[{key,label}]` as the JSON *string* the QML role holds.
fn actions_json(actions: &[(String, String)]) -> String {
    let list: Vec<Value> = actions
        .iter()
        .filter(|(key, _)| !key.is_empty())
        .take(ACTIONS_MAX)
        .map(|(key, label)| {
            json!({ "key": clean_line(key, NAME_MAX), "label": clean_line(label, NAME_MAX) })
        })
        .collect();
    Value::Array(list).to_string()
}

/// One line: control characters become spaces, runs of whitespace collapse,
/// at most `max` characters.
pub(crate) fn clean_line(s: &str, max: usize) -> String {
    let mut out = String::with_capacity(s.len().min(max * 4));
    let mut n = 0;
    let mut space = false;
    for c in s.trim().chars() {
        if n >= max {
            break;
        }
        if c.is_control() || c.is_whitespace() {
            space = true;
            continue;
        }
        if space && n > 0 {
            out.push(' ');
            n += 1;
            if n >= max {
                break;
            }
        }
        space = false;
        out.push(c);
        n += 1;
    }
    out.truncate(out.trim_end().len());
    out
}

/// Body text: keeps `\n`, turns tabs into spaces, drops every other control
/// character, at most `max` characters.
pub(crate) fn clean_text(s: &str, max: usize) -> String {
    s.trim()
        .chars()
        .filter_map(|c| match c {
            '\n' => Some('\n'),
            '\t' => Some(' '),
            c if c.is_control() => None,
            c => Some(c),
        })
        .take(max)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(summary: &str) -> Incoming {
        Incoming {
            app_name: "Firefox".into(),
            app_icon: "firefox".into(),
            summary: summary.into(),
            urgency: 1,
            banners: true,
            ..Incoming::default()
        }
    }

    fn ids(v: &Value) -> Vec<u64> {
        v.as_array()
            .map(|a| a.iter().filter_map(|n| n["nid"].as_u64()).collect())
            .unwrap_or_default()
    }

    #[test]
    fn insert_is_newest_first_with_mock_types() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let mut a = note("one");
        a.actions = vec![("default".into(), "Open".into())];
        assert_eq!(s.insert(a, 1000, &mut fx), 1);
        assert_eq!(s.insert(note("two"), 2000, &mut fx), 2);
        assert!(fx.popups && fx.history && fx.closed.is_empty());
        assert_eq!(ids(&s.popups_json()), [2, 1]);
        assert_eq!(ids(&s.history_json()), [2, 1]);
        let row = &s.history_json()[1];
        assert_eq!(
            *row,
            json!({ "nid": 1, "appName": "Firefox", "appIcon": "firefox", "summary": "one",
                    "body": "", "urgency": 1, "time": 1000,
                    "actions": "[{\"key\":\"default\",\"label\":\"Open\"}]", "image": "" })
        );
        assert!(row["nid"].is_u64() && row["time"].is_u64() && row["actions"].is_string());
    }

    #[test]
    fn replace_updates_in_place_and_pops_again() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let a = s.insert(note("a"), 1, &mut fx);
        s.insert(note("b"), 2, &mut fx);
        s.expire(a, &mut fx);
        assert_eq!(ids(&s.popups_json()), [2]);
        assert!(fx.closed.is_empty(), "still open in the history");

        let mut fx = Effects::default();
        let mut r = note("a2");
        r.replaces_id = a;
        assert_eq!(s.insert(r, 3, &mut fx), a);
        assert_eq!(ids(&s.popups_json()), [1, 2], "popped again, newest first");
        assert_eq!(ids(&s.history_json()), [2, 1], "history row kept its place");
        assert_eq!(s.history_json()[1]["summary"], "a2");
        assert_eq!(s.history_json()[1]["time"], 3);

        // Replacing a visible toast keeps its position.
        let mut r = note("b2");
        r.replaces_id = 2;
        s.insert(r, 4, &mut fx);
        assert_eq!(ids(&s.popups_json()), [1, 2]);
        assert_eq!(s.popups_json()[1]["summary"], "b2");
        assert!(fx.closed.is_empty());

        // An unknown replaces_id keeps the requested id; new ids skip it.
        let mut r = note("c");
        r.replaces_id = 3;
        assert_eq!(s.insert(r, 5, &mut fx), 3);
        assert_eq!(s.insert(note("d"), 6, &mut fx), 4);
    }

    #[test]
    fn expire_dismiss_close_reasons() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let a = s.insert(note("a"), 1, &mut fx);
        let b = s.insert(note("b"), 2, &mut fx);
        let c = s.insert(note("c"), 3, &mut fx);

        let mut fx = Effects::default();
        s.expire(a, &mut fx);
        assert_eq!(
            fx,
            Effects {
                popups: true,
                history: false,
                closed: vec![]
            }
        );
        s.expire(a, &mut fx);
        s.expire(99, &mut fx);
        assert!(!fx.history && fx.closed.is_empty());

        let mut fx = Effects::default();
        s.remove(a, REASON_DISMISSED, &mut fx);
        assert_eq!(
            fx,
            Effects {
                popups: false,
                history: true,
                closed: vec![(a, 2)]
            }
        );
        let mut fx = Effects::default();
        s.remove(b, REASON_CLOSED, &mut fx);
        assert_eq!(fx.closed, [(b, 3)]);
        assert!(fx.popups && fx.history);
        let mut fx = Effects::default();
        s.remove(b, REASON_CLOSED, &mut fx);
        assert_eq!(fx, Effects::default(), "unknown id changes nothing");

        let mut fx = Effects::default();
        s.clear_all(&mut fx);
        assert_eq!(fx.closed, [(c, 2)]);
        assert_eq!(ids(&s.popups_json()), [] as [u64; 0]);
        let mut fx = Effects::default();
        s.clear_all(&mut fx);
        assert_eq!(fx, Effects::default());
    }

    #[test]
    fn transient_is_popup_only() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let mut t = note("t");
        t.transient = true;
        let id = s.insert(t.clone(), 1, &mut fx);
        assert!(fx.popups && !fx.history);
        assert_eq!(ids(&s.history_json()), [] as [u64; 0]);
        s.expire(id, &mut fx);
        assert_eq!(fx.closed, [(id, REASON_EXPIRED)]);

        // Under DND a transient notification is never shown: closed at once.
        s.set_dnd(true);
        let mut fx = Effects::default();
        let id = s.insert(t, 2, &mut fx);
        assert_eq!(
            fx,
            Effects {
                popups: false,
                history: false,
                closed: vec![(id, 1)]
            }
        );
    }

    #[test]
    fn dnd_and_banners_gate_the_popup() {
        let mut s = Store::new(true);
        assert!(s.dnd() && !s.set_dnd(true));
        let mut fx = Effects::default();
        s.insert(note("quiet"), 1, &mut fx);
        assert!(!fx.popups && fx.history);
        let mut crit = note("battery");
        crit.urgency = 2;
        let c = s.insert(crit, 2, &mut fx);
        assert_eq!(ids(&s.popups_json()), [u64::from(c)]);
        assert_eq!(ids(&s.history_json()), [2, 1]);

        assert!(s.set_dnd(false));
        let mut off = note("no banner");
        off.banners = false;
        off.urgency = 2;
        s.insert(off, 3, &mut fx);
        assert_eq!(ids(&s.popups_json()), [2]);
        assert_eq!(ids(&s.history_json()), [3, 2, 1]);
    }

    #[test]
    fn history_cap_drops_oldest() {
        let mut s = Store::new(true); // DND: no toasts, so a dropped row is closed
        let mut fx = Effects::default();
        for i in 0..HISTORY_CAP + 5 {
            s.insert(note("n"), i as u64, &mut fx);
        }
        let h = ids(&s.history_json());
        assert_eq!(h.len(), HISTORY_CAP);
        assert_eq!(h[0], (HISTORY_CAP + 5) as u64);
        assert_eq!(h[HISTORY_CAP - 1], 6);
        assert_eq!(fx.closed, [(1, 1), (2, 1), (3, 1), (4, 1), (5, 1)]);

        let mut s = Store::new(false);
        let mut fx = Effects::default();
        for i in 0..POPUP_CAP + 3 {
            s.insert(note("n"), i as u64, &mut fx);
        }
        assert_eq!(ids(&s.popups_json()).len(), POPUP_CAP);
        assert!(fx.closed.is_empty(), "rows pushed off the toasts stay open");
    }

    #[test]
    fn action_dismisses_unless_resident() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let a = s.insert(note("a"), 1, &mut fx);
        let mut r = note("r");
        r.resident = true;
        let r = s.insert(r, 2, &mut fx);

        let mut fx = Effects::default();
        assert!(s.action_invoked(a, &mut fx));
        assert_eq!(fx.closed, [(a, REASON_DISMISSED)]);
        assert!(!s.action_invoked(a, &mut fx));

        let mut fx = Effects::default();
        assert!(s.action_invoked(r, &mut fx));
        assert!(fx.popups && !fx.history && fx.closed.is_empty());
        assert_eq!(ids(&s.history_json()), [u64::from(r)]);
        assert!(
            s.action_invoked(r, &mut fx),
            "still there for a second action"
        );
    }

    #[test]
    fn sanitizes_text() {
        assert_eq!(clean_line("  a\u{7}b\n\tc  d ", 200), "a b c d");
        assert_eq!(clean_line(&"é".repeat(300), 200).chars().count(), 200);
        assert_eq!(clean_line("ab   cd", 3), "ab");
        assert_eq!(
            clean_text(" line1\r\nline\u{1b}[0m2\tx ", 2000),
            "line1\nline[0m2 x"
        );
        assert_eq!(clean_text(&"x".repeat(3000), 2000).len(), 2000);

        let mut s = Store::new(false);
        let mut fx = Effects::default();
        let mut n = note(&"s".repeat(500));
        n.body = "b".repeat(5000);
        n.urgency = 9;
        n.actions = (0..20).map(|i| (format!("k{i}"), "L\n".into())).collect();
        n.actions.push((String::new(), "skipped".into()));
        s.insert(n, 1, &mut fx);
        let row = &s.popups_json()[0];
        assert_eq!(row["summary"].as_str().map(str::len), Some(200));
        assert_eq!(row["body"].as_str().map(str::len), Some(2000));
        assert_eq!(row["urgency"], 2);
        let acts: Value =
            serde_json::from_str(row["actions"].as_str().unwrap_or_default()).unwrap_or_default();
        assert_eq!(acts.as_array().map(Vec::len), Some(ACTIONS_MAX));
        assert_eq!(acts[0], json!({ "key": "k0", "label": "L" }));
    }

    #[test]
    fn ids_wrap_inside_the_qml_int_range() {
        let mut s = Store::new(false);
        let mut fx = Effects::default();
        s.insert(note("first"), 1, &mut fx);
        s.last_id = i32::MAX as u32;
        assert_eq!(s.insert(note("wrapped"), 2, &mut fx), 2, "1 is still open");
        let mut big = note("big");
        big.replaces_id = u32::MAX;
        assert_eq!(s.insert(big, 3, &mut fx), 3);
    }
}
