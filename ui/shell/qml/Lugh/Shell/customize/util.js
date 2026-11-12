// Helpers shared by the Customize panel: settings search, clock text and
// the id catalogs (names translated at use, through name()).
.pragma library

// The nearest ancestor of `item` (itself included) that has `prop`. Called
// from bindings, so the parent chain and the property are dependencies.
function ancestor(item, prop) {
    for (let p = item; p; p = p.parent)
        if (p[prop] !== undefined) return p;
    return null;
}

// True when every word of `query` occurs in `text` (case-insensitive).
function match(query, text) {
    const q = (query || "").trim().toLowerCase();
    if (q === "") return true;
    const t = (text || "").toLowerCase();
    for (const w of q.split(/\s+/))
        if (t.indexOf(w) < 0) return false;
    return true;
}

// Panel clock text, as the tray shows it.
function timeText(d, h24, seconds) {
    const f = h24 ? (seconds ? "HH:mm:ss" : "HH:mm") : (seconds ? "h:mm:ss AP" : "h:mm AP");
    return Qt.formatTime(d, f);
}

// Translation context of the catalog names below. They are marked with
// QT_TRANSLATE_NOOP so lupdate extracts them; show them through name().
const trContext = "Customize";
function name(catalog, id) {
    return catalog[id] ? qsTranslate(trContext, catalog[id].name) : id;
}

// Names and icons of the quick-panel toggle ids (ShellSettings.quickToggles).
const quickToggles = {
    wifi:         { name: QT_TRANSLATE_NOOP("Customize", "Wi-Fi"),          icon: "wifi" },
    bluetooth:    { name: QT_TRANSLATE_NOOP("Customize", "Bluetooth"),      icon: "bluetooth" },
    dnd:          { name: QT_TRANSLATE_NOOP("Customize", "Do not disturb"), icon: "bell-off" },
    nightlight:   { name: QT_TRANSLATE_NOOP("Customize", "Night light"),    icon: "sunset" },
    airplane:     { name: QT_TRANSLATE_NOOP("Customize", "Airplane mode"),  icon: "plane" },
    powerprofile: { name: QT_TRANSLATE_NOOP("Customize", "Power profile"),  icon: "gauge" },
    darkmode:     { name: QT_TRANSLATE_NOOP("Customize", "Dark style"),     icon: "moon" },
    caffeine:     { name: QT_TRANSLATE_NOOP("Customize", "Keep awake"),     icon: "coffee" }
};
const quickToggleIds = ["wifi", "bluetooth", "dnd", "nightlight", "airplane", "powerprofile", "darkmode", "caffeine"];

// Title-bar buttons (ShellSettings.titlebarButtons, comma list).
const titlebarButtons = {
    minimize: { name: QT_TRANSLATE_NOOP("Customize", "Minimize"), icon: "minus" },
    maximize: { name: QT_TRANSLATE_NOOP("Customize", "Maximize"), icon: "square" },
    close:    { name: QT_TRANSLATE_NOOP("Customize", "Close"),    icon: "x" }
};
const titlebarButtonIds = ["minimize", "maximize", "close"];
