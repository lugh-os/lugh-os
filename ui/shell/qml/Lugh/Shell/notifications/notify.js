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
