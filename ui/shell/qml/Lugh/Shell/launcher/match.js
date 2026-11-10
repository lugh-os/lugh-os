// Launcher text helpers: query-match emphasis for result titles.
.pragma library

function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// StyledText for `text` with the first case-insensitive occurrence of `query`
// in bold (a weight change, never color alone) and, when `color` is given,
// tinted. Plain escaped text when nothing matches (e.g. alias hits such as
// "control panel" → Settings, where the match is in the subtitle).
function emphasize(text, query, color) {
    const t = String(text);
    const q = String(query).trim().toLowerCase();
    if (!q.length) return escapeHtml(t);
    const i = t.toLowerCase().indexOf(q);
    if (i < 0) return escapeHtml(t);
    const open = color ? "<b><font color=\"" + color + "\">" : "<b>";
    const close = color ? "</font></b>" : "</b>";
    return escapeHtml(t.slice(0, i)) + open + escapeHtml(t.slice(i, i + q.length)) + close
        + escapeHtml(t.slice(i + q.length));
}
