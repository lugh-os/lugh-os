// Shared helpers for NotificationPopups and NotificationCenter: action
// parsing, a safe subset of the freedesktop body markup, relative times and
// grouping the history by app. Pure functions, no QML state.
.pragma library

// actions: JSON string (or array) of [{key, label}]. The freedesktop
// "default" action is the click on the notification body, never a button.
function parseActions(json) {
    let a = json;
    if (typeof a === "string") {
        if (a === "") return [];
        try { a = JSON.parse(a); } catch (e) { return []; }
    }
    if (!Array.isArray(a)) return [];
    return a.filter(x => x && typeof x.key === "string" && x.key !== "default"
                         && typeof x.label === "string" && x.label !== "").slice(0, 3);
}

function hasDefaultAction(json) {
    let a = json;
    if (typeof a === "string") {
        try { a = JSON.parse(a || "[]"); } catch (e) { return false; }
    }
    return Array.isArray(a) && a.some(x => x && x.key === "default");
}

function _escape(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Body markup (spec "body-markup"): keeps <b>, <i>, <u> and <a href> with an
// http(s)/mailto target; everything else is shown as literal text. Line breaks
// become <br>. The result is for Text.StyledText.
function bodyMarkup(body) {
    if (!body) return "";
    // Decode the few entities senders use, then escape everything.
    let s = String(body).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"")
                        .replace(/&apos;/g, "'").replace(/&amp;/g, "&");
    s = _escape(s);
    s = s.replace(/&lt;(\/?)(b|i|u)&gt;/gi, (m, slash, tag) => "<" + slash + tag.toLowerCase() + ">");
    s = s.replace(/&lt;a\s+href=(?:&quot;|')((?:https?:\/\/|mailto:)[^"'<>\s]*?)(?:&quot;|')\s*&gt;/gi,
                  (m, href) => "<a href=\"" + href + "\">");
    s = s.replace(/&lt;\/a&gt;/gi, "</a>");
    return s.replace(/\r?\n/g, "<br>");
}

// Plain text version (accessible names, tooltips).
function plain(body) {
    return String(body || "").replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
                             .replace(/&quot;/g, "\"").replace(/&amp;/g, "&");
}

// "now", "4 min ago", "2 h ago", "Yesterday", "Tue", "12 Oct".
// `now` is passed in so callers can drive updates from one shared timer.
function relativeTime(epochMs, now) {
    if (!epochMs) return "";
    const d = Math.max(0, (now - epochMs) / 1000);
    if (d < 60) return qsTr("now");
    if (d < 3600) return qsTr("%1 min ago").arg(Math.floor(d / 60));
    const then = new Date(epochMs), today = new Date(now);
    const dayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
    if (epochMs >= dayStart) return qsTr("%1 h ago").arg(Math.floor(d / 3600));
    if (epochMs >= dayStart - 86400000) return qsTr("Yesterday");
    if (epochMs >= dayStart - 6 * 86400000) return Qt.formatDate(then, "ddd");
    return Qt.formatDate(then, "d MMM");
}

// Groups a ListModel (newest first) by app, groups ordered by their newest
// notification. Returns [{appName, appIcon, items: [row objects]}].
function groupByApp(model) {
    const groups = [], byName = {};
    for (let i = 0; i < model.count; ++i) {
        const r = model.get(i);
        const n = { nid: r.nid, appName: r.appName, appIcon: r.appIcon, summary: r.summary, body: r.body,
                    urgency: r.urgency, time: r.time, actions: r.actions, image: r.image };
        let g = byName[n.appName];
        if (!g) {
            g = byName[n.appName] = { appName: n.appName, appIcon: n.appIcon, items: [] };
            groups.push(g);
        }
        g.items.push(n);
    }
    return groups;
}

// ISO 8601 week number of a Date.
function isoWeek(d) {
    const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
    const day = t.getUTCDay() || 7;
    t.setUTCDate(t.getUTCDate() + 4 - day);
    const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
    return Math.ceil(((t - y0) / 86400000 + 1) / 7);
}

// The notification center's list: groups flattened to light rows.
//   header  one per app (appName, appIcon, count, collapsible, open)
//   item    one notification
//   more    "N more" under a collapsed group (more = hidden count)
// A group with more than `limit` notifications shows its newest `limit` until
// `expanded[appName]` is true. Every row carries every role (ListModel).
function flatten(groups, expanded, limit) {
    const rows = [];
    const blank = { nid: -1, summary: "", body: "", urgency: 1, time: 0, actions: "[]", image: "" };
    for (const g of groups) {
        const collapsible = g.items.length > limit;
        const open = !collapsible || expanded[g.appName] === true;
        const base = { appName: g.appName, appIcon: g.appIcon || "", count: g.items.length,
                       collapsible: collapsible, open: open, more: 0 };
        rows.push(Object.assign({ kind: "header", key: "h:" + g.appName }, blank, base));
        const shown = open ? g.items : g.items.slice(0, limit);
        for (const n of shown)
            rows.push(Object.assign({ kind: "item", key: "n:" + n.nid }, base,
                                    { nid: n.nid, summary: n.summary || "", body: n.body || "", urgency: n.urgency,
                                      time: n.time || 0, actions: n.actions || "[]", image: n.image || "" }));
        if (!open)
            rows.push(Object.assign({ kind: "more", key: "m:" + g.appName }, blank, base,
                                    { more: g.items.length - limit }));
    }
    return rows;
}

function _isSubsequence(small, big) {
    let j = 0;
    for (let i = 0; i < big.length && j < small.length; ++i)
        if (big[i] === small[j]) ++j;
    return j === small.length;
}

// Brings a ListModel in line with flatten()'s rows. Pure removals and pure
// insertions are applied row by row (so the view animates them and keeps its
// scroll position); anything else rebuilds the model. Returns false on a rebuild.
function syncRows(model, rows) {
    const oldKeys = [];
    for (let i = 0; i < model.count; ++i) oldKeys.push(model.get(i).key);
    const newKeys = rows.map(r => r.key);
    if (_isSubsequence(newKeys, oldKeys)) {
        for (let i = 0, j = 0; i < model.count;) {
            if (j < newKeys.length && model.get(i).key === newKeys[j]) { ++i; ++j; }
            else model.remove(i);
        }
    } else if (_isSubsequence(oldKeys, newKeys)) {
        for (let i = 0; i < rows.length; ++i)
            if (i >= model.count || model.get(i).key !== rows[i].key) model.insert(i, rows[i]);
    } else {
        model.clear();
        for (const r of rows) model.append(r);
        return false;
    }
    for (let i = 0; i < rows.length; ++i) {
        const cur = model.get(i), r = rows[i];
        for (const k in r)
            if (cur[k] !== r[k]) model.setProperty(i, k, r[k]);
    }
    return true;
}

// Actions for the notification center, where a click expands the card: the
// "default" action becomes the first button ("Open" when it has no label).
function parseActionsWithDefault(json, openLabel) {
    let a = json;
    if (typeof a === "string") {
        if (a === "") return [];
        try { a = JSON.parse(a); } catch (e) { return []; }
    }
    if (!Array.isArray(a)) return [];
    const out = [];
    const def = a.find(x => x && x.key === "default");
    if (def) out.push({ key: "default", label: typeof def.label === "string" && def.label !== "" ? def.label : openLabel });
    return out.concat(parseActions(a)).slice(0, 3);
}

// Widths for a row of buttons that must fit `avail`: short ones keep their
// size, long ones share what is left (and elide).
function fitWidths(natural, avail, gap) {
    const n = natural.length;
    if (n === 0) return [];
    let room = avail - gap * (n - 1);
    const out = natural.slice();
    let open = natural.map((w, i) => i).sort((a, b) => natural[a] - natural[b]);
    while (open.length > 0) {
        const share = room / open.length, i = open[0];
        if (natural[i] <= share) { out[i] = natural[i]; room -= natural[i]; open.shift(); }
        else { for (const k of open) out[k] = Math.floor(share); break; }
    }
    return out;
}
