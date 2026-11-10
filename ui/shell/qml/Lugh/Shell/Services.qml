// Services: everything the shell reads from or asks of the system, behind one
// QML-facing API. This file is the **mock** backend used by the preview, the
// demos and QML tests: plausible data, simulated delays and failures.
//
// Contract: the Rust core (crates/lugh-shell-core, bridged with cxx-qt) will
// expose objects with exactly these property, model-role, function and signal
// names. Surfaces must only use what is declared here; if a surface needs more,
// add it here (mock + comment) so the Rust side knows to implement it.
//
// Dev conveniences in the mock:
//   - Wi-Fi password "wrong" fails; anything else connects after ~1.2 s.
//   - Lock screen / greeter password "lugh" succeeds; anything else fails.
//   - Services.notifications.notify(...) posts a notification.
pragma Singleton
import QtQuick
import Lugh.UI

QtObject {
    id: services

    // ---- session ----------------------------------------------------------
    property QtObject session: QtObject {
        property string userName: "amara"
        property string realName: "Amara Nkusi"
        property string avatar: ""          // file URL or "" (initials fallback)
        property string hostName: "lugh-laptop"
        property string osVersion: "Lugh 0.1 (Phase 1 preview)"
        property bool locked: false
        property bool authenticating: false
        property string authError: ""        // plain-language, "" when none
        signal unlocked()

        function lock() { authError = ""; locked = true; }
        // Async: sets authenticating, then either `locked = false` + unlocked()
        // or authError = "Wrong password. Try again."
        function unlock(password) {
            authenticating = true;
            authError = "";
            _authTimer.password = password;
            _authTimer.restart();
        }
        function logout() { console.info("[mock] logout"); }
        function restart() { console.info("[mock] restart"); }
        function shutdown() { console.info("[mock] shutdown"); }
        function suspend() { console.info("[mock] suspend"); lock(); }

        property Timer _authTimer: Timer {
            property string password
            interval: 650
            onTriggered: {
                services.session.authenticating = false;
                if (password === "lugh") {
                    services.session.locked = false;
                    services.session.unlocked();
                } else {
                    services.session.authError = qsTr("Wrong password. Try again.");
                }
            }
        }
    }

    // ---- clock ------------------------------------------------------------
    // `now` ticks once a second, aligned to the wall clock.
    property QtObject clock: QtObject {
        property date now: new Date()
        property bool use24h: true
        readonly property string time: Qt.formatTime(now, use24h ? "HH:mm" : "h:mm AP")
        readonly property string date: Qt.formatDate(now, "ddd d MMM")
        readonly property string longDate: Qt.formatDate(now, "dddd, d MMMM")
        property Timer _tick: Timer {
            interval: 1000 - (new Date()).getMilliseconds()
            running: true
            repeat: true
            onTriggered: { services.clock.now = new Date(); interval = 1000; }
        }
    }

    // ---- window manager (Hyprland adapter in Phase 1) ----------------------
    property QtObject wm: QtObject {
        // roles: wsId (int), name (string), occupied (bool)
        property ListModel workspaces: ListModel {
            ListElement { wsId: 1; name: "1"; occupied: true }
            ListElement { wsId: 2; name: "2"; occupied: true }
            ListElement { wsId: 3; name: "3"; occupied: false }
            ListElement { wsId: 4; name: "4"; occupied: false }
        }
        property int activeWorkspace: 1
        property string focusedAppId: "firefox"
        property string focusedAppName: "Firefox"
        property string focusedTitle: "Lugh — Mozilla Firefox"
        // True when a window on the active workspace overlaps the dock area
        // (drives dock auto-hide).
        property bool dockOverlapped: false
        // roles: winId (string), appId, title, workspace (int), focused (bool)
        property ListModel toplevels: ListModel {
            ListElement { winId: "0x1"; appId: "firefox"; title: "Lugh — Mozilla Firefox"; workspace: 1; focused: true }
            ListElement { winId: "0x2"; appId: "org.codeberg.dnkl.foot"; title: "amara@lugh-laptop: ~"; workspace: 1; focused: false }
            ListElement { winId: "0x3"; appId: "vlc"; title: "VLC media player"; workspace: 2; focused: false }
        }
        function switchWorkspace(wsId) { activeWorkspace = wsId; }
        function activate(winId) {
            for (let i = 0; i < toplevels.count; ++i) {
                const t = toplevels.get(i);
                toplevels.setProperty(i, "focused", t.winId === winId);
                if (t.winId === winId) {
                    focusedAppId = t.appId;
                    focusedTitle = t.title;
                    focusedAppName = services.apps.nameFor(t.appId);
                    activeWorkspace = t.workspace;
                }
            }
        }
        function close(winId) {
            for (let i = 0; i < toplevels.count; ++i)
                if (toplevels.get(i).winId === winId) { toplevels.remove(i); break; }
            services.apps._syncRunning();
        }
    }

    // ---- apps (desktop entries, dock, launching via systemd scopes) --------
    property QtObject apps: QtObject {
        // Every installed app. roles: appId, name, genericName, icon (freedesktop
        // icon name), keywords (space-separated)
        property ListModel installed: ListModel {
            ListElement { appId: "firefox"; name: "Firefox"; genericName: "Web Browser"; icon: "firefox"; keywords: "internet web browser" }
            ListElement { appId: "lugh-files"; name: "Files"; genericName: "File Manager"; icon: "system-file-manager"; keywords: "folder explorer" }
            ListElement { appId: "org.codeberg.dnkl.foot"; name: "Terminal"; genericName: "Terminal"; icon: "utilities-terminal"; keywords: "shell cmd powershell console" }
            ListElement { appId: "vlc"; name: "VLC"; genericName: "Media Player"; icon: "vlc"; keywords: "video music movie" }
            ListElement { appId: "lugh-settings"; name: "Settings"; genericName: "System Settings"; icon: "preferences-system"; keywords: "control panel preferences" }
            ListElement { appId: "lugh-store"; name: "Store"; genericName: "App Store"; icon: "system-software-install"; keywords: "install apps programs" }
            ListElement { appId: "featherpad"; name: "Text Editor"; genericName: "Text Editor"; icon: "accessories-text-editor"; keywords: "notepad txt" }
            ListElement { appId: "qalculate-qt"; name: "Calculator"; genericName: "Calculator"; icon: "accessories-calculator"; keywords: "math" }
            ListElement { appId: "qimgv"; name: "Images"; genericName: "Image Viewer"; icon: "image-viewer"; keywords: "photos pictures" }
            ListElement { appId: "qpdfview"; name: "Documents"; genericName: "PDF Viewer"; icon: "application-pdf"; keywords: "pdf reader" }
            ListElement { appId: "lugh-tasks"; name: "Tasks"; genericName: "Task Manager"; icon: "utilities-system-monitor"; keywords: "task manager processes" }
        }
        // Dock contents, in order: pinned first, then running unpinned.
        // roles: appId, name, icon, pinned (bool), running (bool),
        //        windows (int), launching (bool), attention (bool)
        property ListModel dock: ListModel {
            ListElement { appId: "firefox"; name: "Firefox"; icon: "firefox"; pinned: true; running: true; windows: 1; launching: false; attention: false }
            ListElement { appId: "lugh-files"; name: "Files"; icon: "system-file-manager"; pinned: true; running: false; windows: 0; launching: false; attention: false }
            ListElement { appId: "org.codeberg.dnkl.foot"; name: "Terminal"; icon: "utilities-terminal"; pinned: true; running: true; windows: 1; launching: false; attention: false }
            ListElement { appId: "lugh-store"; name: "Store"; icon: "system-software-install"; pinned: true; running: false; windows: 0; launching: false; attention: false }
            ListElement { appId: "lugh-settings"; name: "Settings"; icon: "preferences-system"; pinned: true; running: false; windows: 0; launching: false; attention: false }
            ListElement { appId: "vlc"; name: "VLC"; icon: "vlc"; pinned: false; running: true; windows: 1; launching: false; attention: false }
        }
        // Emitted when an app fails to start (dock shows an inline toast).
        signal launchFailed(string appId, string message)

        function nameFor(appId) {
            for (let i = 0; i < installed.count; ++i)
                if (installed.get(i).appId === appId) return installed.get(i).name;
            return appId;
        }
        function iconFor(appId) {
            for (let i = 0; i < installed.count; ++i)
                if (installed.get(i).appId === appId) return installed.get(i).icon;
            return "application-x-executable";
        }
        // Focuses the app if running, else launches it in its own scope.
        function activate(appId) {
            for (let i = 0; i < services.wm.toplevels.count; ++i) {
                const t = services.wm.toplevels.get(i);
                if (t.appId === appId) { services.wm.activate(t.winId); return; }
            }
            launch(appId);
        }
        // Always starts a new instance (middle click, "New window").
        function launch(appId) {
            const idx = _dockIndex(appId);
            if (idx >= 0) dock.setProperty(idx, "launching", true);
            _launchTimer.queue.push(appId);
            _launchTimer.start();
        }
        function quit(appId) {
            for (let i = services.wm.toplevels.count - 1; i >= 0; --i)
                if (services.wm.toplevels.get(i).appId === appId) services.wm.toplevels.remove(i);
            _syncRunning();
        }
        function pin(appId) {
            const idx = _dockIndex(appId);
            if (idx >= 0) { dock.setProperty(idx, "pinned", true); return; }
            dock.append({ appId: appId, name: nameFor(appId), icon: iconFor(appId), pinned: true,
                          running: false, windows: 0, launching: false, attention: false });
        }
        function unpin(appId) {
            const idx = _dockIndex(appId);
            if (idx < 0) return;
            if (!dock.get(idx).running) { dock.remove(idx); return; }
            dock.setProperty(idx, "pinned", false);
            // Keep "pinned first": move it right after the last pinned item.
            let last = -1;
            for (let i = 0; i < dock.count; ++i) if (dock.get(i).pinned) last = i;
            if (last > idx) dock.move(idx, last, 1);
        }

        function _dockIndex(appId) {
            for (let i = 0; i < dock.count; ++i) if (dock.get(i).appId === appId) return i;
            return -1;
        }
        function _syncRunning() {
            for (let i = dock.count - 1; i >= 0; --i) {
                const d = dock.get(i);
                let n = 0;
                for (let j = 0; j < services.wm.toplevels.count; ++j)
                    if (services.wm.toplevels.get(j).appId === d.appId) ++n;
                dock.setProperty(i, "windows", n);
                dock.setProperty(i, "running", n > 0);
                if (n === 0 && !d.pinned) dock.remove(i);
            }
        }
        property Timer _launchTimer: Timer {
            property var queue: []
            interval: 700
            onTriggered: {
                const q = queue; queue = [];
                for (const appId of q) {
                    const winId = "0x" + Math.floor(Math.random() * 1e6).toString(16);
                    services.wm.toplevels.append({ winId: winId, appId: appId, title: services.apps.nameFor(appId),
                                                   workspace: services.wm.activeWorkspace, focused: false });
                    if (services.apps._dockIndex(appId) < 0)
                        services.apps.dock.append({ appId: appId, name: services.apps.nameFor(appId), icon: services.apps.iconFor(appId),
                                                    pinned: false, running: true, windows: 1, launching: false, attention: false });
                    const idx = services.apps._dockIndex(appId);
                    services.apps.dock.setProperty(idx, "launching", false);
                    services.apps._syncRunning();
                    services.wm.activate(winId);
                }
            }
        }
    }

    // ---- launcher (search providers live in Rust: lugh-shell-core) ---------
    property QtObject launcher: QtObject {
        property string query: ""
        property bool searching: false
        // Flat, already ranked, grouped by `group` in display order.
        // roles: kind ("app" | "setting" | "window" | "file" | "calc" | "command"),
        //        group (display name: "Apps", "Settings", …), title, subtitle,
        //        icon (freedesktop name; symbolic Lucide name when kind != app),
        //        target (appId / winId / path / value to copy / command)
        property ListModel results: ListModel {}
        // Shown when the query is empty. roles: appId, name, icon
        property ListModel recent: ListModel {
            ListElement { appId: "firefox"; name: "Firefox"; icon: "firefox" }
            ListElement { appId: "lugh-files"; name: "Files"; icon: "system-file-manager" }
            ListElement { appId: "org.codeberg.dnkl.foot"; name: "Terminal"; icon: "utilities-terminal" }
            ListElement { appId: "lugh-settings"; name: "Settings"; icon: "preferences-system" }
            ListElement { appId: "vlc"; name: "VLC"; icon: "vlc" }
        }
        // Synchronous in the mock; the Rust side answers in < 30 ms and streams
        // slow providers (files, Store) in later.
        function search(text) {
            query = text;
            results.clear();
            const q = text.trim().toLowerCase();
            if (!q.length) return;
            if (/^[=]?[\d\s.+\-*/^()%]+$/.test(q) && /\d/.test(q) && /[+\-*/^%]/.test(q)) {
                let v = NaN;
                try { v = Function('"use strict";return (' + q.replace(/^=/, "").replace(/\^/g, "**") + ")")(); } catch (e) {}
                if (isFinite(v))
                    results.append({ kind: "calc", group: qsTr("Calculator"), title: String(Math.round(v * 1e10) / 1e10),
                                     subtitle: qsTr("Press Enter to copy"), icon: "calculator", target: String(v) });
            }
            const aliases = { "control panel": "lugh-settings", "task manager": "lugh-tasks", "cmd": "org.codeberg.dnkl.foot",
                              "powershell": "org.codeberg.dnkl.foot", "add or remove programs": "lugh-store", "notepad": "featherpad" };
            const seen = {};
            for (const a in aliases)
                if (a.startsWith(q) && q.length >= 3) {
                    const id = aliases[a]; seen[id] = true;
                    results.append({ kind: "app", group: qsTr("Apps"), title: services.apps.nameFor(id),
                                     subtitle: qsTr("Matches ‘%1’").arg(a),
                                     icon: services.apps.iconFor(id), target: id });
                }
            for (let i = 0; i < services.apps.installed.count; ++i) {
                const a = services.apps.installed.get(i);
                if (seen[a.appId]) continue;
                const hay = (a.name + " " + a.genericName + " " + a.keywords).toLowerCase();
                if (hay.indexOf(q) >= 0)
                    results.append({ kind: "app", group: qsTr("Apps"), title: a.name, subtitle: a.genericName, icon: a.icon, target: a.appId });
            }
            for (let i = 0; i < services.wm.toplevels.count; ++i) {
                const t = services.wm.toplevels.get(i);
                if (t.title.toLowerCase().indexOf(q) >= 0)
                    results.append({ kind: "window", group: qsTr("Open windows"), title: t.title,
                                     subtitle: qsTr("Switch to window"), icon: services.apps.iconFor(t.appId), target: t.winId });
            }
            const settings = [["Wi-Fi", "network/wifi", "wifi"], ["Bluetooth", "bluetooth", "bluetooth"], ["Wallpaper", "appearance/wallpaper", "image"],
                              ["Dark mode", "appearance/theme", "moon"], ["Display", "display", "monitor"], ["Sound", "sound", "volume-2"]];
            for (const s of settings)
                if (s[0].toLowerCase().indexOf(q) >= 0)
                    results.append({ kind: "setting", group: qsTr("Settings"), title: s[0], subtitle: qsTr("Settings"), icon: s[2], target: s[1] });
            const files = [["Rwanda trip budget.ods", "~/Documents"], ["Lugh pitch.pdf", "~/Documents"], ["IMG_2041.jpg", "~/Pictures"]];
            for (const f of files)
                if (f[0].toLowerCase().indexOf(q) >= 0)
                    results.append({ kind: "file", group: qsTr("Files"), title: f[0], subtitle: f[1], icon: "file", target: f[1] + "/" + f[0] });
            if (q.startsWith(">"))
                results.append({ kind: "command", group: qsTr("Run"), title: text.trim().slice(1).trim(),
                                 subtitle: qsTr("Run in Terminal"), icon: "terminal", target: text.trim().slice(1).trim() });
        }
        // Ctrl+Enter: open the file's location / the app's details.
        function activateSecondary(index) {
            const r = results.get(index);
            if (r) console.info("[mock] launcher secondary", r.kind, r.target);
        }
        function activate(index) {
            const r = results.get(index);
            if (!r) return;
            if (r.kind === "app") services.apps.activate(r.target);
            else if (r.kind === "window") services.wm.activate(r.target);
            else console.info("[mock] launcher activate", r.kind, r.target);
        }
    }

    // ---- notifications (org.freedesktop.Notifications server) --------------
    property QtObject notifications: QtObject {
        property bool dnd: false
        // On-screen toasts, newest first, max 3 shown by the UI.
        // roles: nid (int), appName, appIcon, summary, body, urgency (0 low,
        //        1 normal, 2 critical), time (epoch ms), actions (JSON string of
        //        [{key, label}]), image (URL or "")
        property ListModel popups: ListModel {}
        // History, newest first. Same roles as popups.
        property ListModel history: ListModel {
            ListElement { nid: 3; appName: "Firefox"; appIcon: "firefox"; summary: "Download complete"; body: "lugh-0.1-amd64.iso (1.9 GB) finished downloading."; urgency: 1; time: 0; actions: "[{\"key\":\"open\",\"label\":\"Open folder\"}]"; image: "" }
            ListElement { nid: 2; appName: "Calendar"; appIcon: "x-office-calendar"; summary: "Design review in 15 minutes"; body: "Shell visuals with Keza and Jean-Paul"; urgency: 1; time: 0; actions: "[]"; image: "" }
            ListElement { nid: 1; appName: "System"; appIcon: "preferences-system"; summary: "Updates ready"; body: "12 updates are ready to install. A snapshot is taken first."; urgency: 0; time: 0; actions: "[{\"key\":\"install\",\"label\":\"Install now\"}]"; image: "" }
        }
        readonly property int count: history.count
        property int _next: 10
        signal actionInvoked(int nid, string key)

        // actions: array of {key, label} or a JSON string (key "default" = click on
        // the body, not shown as a button); image: URL; appIcon: icon override.
        function notify(appName, summary, body, urgency, actions, image, appIcon) {
            const acts = actions === undefined ? "[]" : (typeof actions === "string" ? actions : JSON.stringify(actions));
            const n = { nid: _next++, appName: appName, appIcon: appIcon || services.apps.iconFor(appName.toLowerCase()), summary: summary,
                        body: body || "", urgency: urgency === undefined ? 1 : urgency, time: Date.now(), actions: acts, image: image || "" };
            history.insert(0, n);
            if (!dnd || n.urgency === 2) popups.insert(0, n);
            return n.nid;
        }
        // Removes the toast only (it stays in history).
        function expire(nid) { _removeFrom(popups, nid); }
        // Removes from toasts and history.
        function dismiss(nid) { _removeFrom(popups, nid); _removeFrom(history, nid); }
        function clearAll() { popups.clear(); history.clear(); }
        function invokeAction(nid, key) { actionInvoked(nid, key); dismiss(nid); }
        function _removeFrom(model, nid) {
            for (let i = 0; i < model.count; ++i) if (model.get(i).nid === nid) { model.remove(i); return; }
        }
        Component.onCompleted: {
            const now = Date.now();
            const ages = [4, 38, 125];
            for (let i = 0; i < history.count; ++i) history.setProperty(i, "time", now - ages[i] * 60000);
        }
    }

    // ---- trash (gio / XDG trash spec) -------------------------------------
    property QtObject trash: QtObject {
        property bool full: true
        function open() { console.info("[mock] open trash"); }
        function empty() { full = false; }
    }

    // ---- network (NetworkManager) -----------------------------------------
    property QtObject network: QtObject {
        property bool wifiAvailable: true
        property bool wifiEnabled: true
        property bool airplaneMode: false
        property bool wired: false
        property bool connected: true
        property string ssid: "Kigali Heights 5G"
        property int strength: 78                      // 0-100
        property bool scanning: false
        property string connectingSsid: ""             // "" when idle
        property string lastError: ""                  // plain language, "" when none
        // roles: ssid, strength (0-100), secure (bool), known (bool), connected (bool)
        property ListModel networks: ListModel {
            ListElement { ssid: "Kigali Heights 5G"; strength: 78; secure: true; known: true; connected: true }
            ListElement { ssid: "Lugh Studio"; strength: 64; secure: true; known: true; connected: false }
            ListElement { ssid: "CafeNeo Guest"; strength: 41; secure: false; known: false; connected: false }
            ListElement { ssid: "MTN-Fiber-2F"; strength: 22; secure: true; known: false; connected: false }
        }
        function setWifiEnabled(on) { wifiEnabled = on; connected = on && ssid !== ""; if (on) rescan(); }
        function setAirplaneMode(on) { airplaneMode = on; if (on) setWifiEnabled(false); }
        function rescan() { scanning = true; _scanTimer.restart(); }
        // Async. On failure sets lastError = "Couldn't connect to <ssid>. Wrong password?"
        function connectTo(ssid, password) {
            lastError = ""; connectingSsid = ssid;
            _connectTimer.password = password || ""; _connectTimer.restart();
        }
        function disconnect() {
            for (let i = 0; i < networks.count; ++i) networks.setProperty(i, "connected", false);
            connected = false; ssid = "";
        }
        property Timer _scanTimer: Timer { interval: 1400; onTriggered: services.network.scanning = false }
        property Timer _connectTimer: Timer {
            property string password
            interval: 1200
            onTriggered: {
                const n = services.network;
                if (password === "wrong") {
                    n.lastError = qsTr("Couldn't connect to %1. Wrong password?").arg(n.connectingSsid);
                } else {
                    for (let i = 0; i < n.networks.count; ++i) {
                        const hit = n.networks.get(i).ssid === n.connectingSsid;
                        n.networks.setProperty(i, "connected", hit);
                        if (hit) { n.networks.setProperty(i, "known", true); n.strength = n.networks.get(i).strength; }
                    }
                    n.ssid = n.connectingSsid; n.connected = true;
                }
                n.connectingSsid = "";
            }
        }
    }

    // ---- bluetooth (BlueZ) ------------------------------------------------
    property QtObject bluetooth: QtObject {
        property bool available: true
        property bool enabled: true
        // roles: address, name, icon (Lucide name), paired, connected, battery (-1 unknown), busy
        property ListModel devices: ListModel {
            ListElement { address: "AC:12:2F:00:11:01"; name: "Keza's Buds"; icon: "headphones"; paired: true; connected: true; battery: 72; busy: false }
            ListElement { address: "AC:12:2F:00:11:02"; name: "MX Keys"; icon: "keyboard"; paired: true; connected: false; battery: -1; busy: false }
            ListElement { address: "AC:12:2F:00:11:03"; name: "Living room speaker"; icon: "speaker"; paired: true; connected: false; battery: -1; busy: false }
        }
        readonly property int connectedCount: { let n = 0; for (let i = 0; i < devices.count; ++i) if (devices.get(i).connected) ++n; return n; }
        function setEnabled(on) { enabled = on; if (!on) for (let i = 0; i < devices.count; ++i) devices.setProperty(i, "connected", false); }
        function toggleDevice(address) {
            for (let i = 0; i < devices.count; ++i)
                if (devices.get(i).address === address) {
                    devices.setProperty(i, "connected", !devices.get(i).connected);
                    enabledChanged();   // nudge connectedCount
                }
        }
    }

    // ---- audio (PipeWire via pipewire-pulse) ------------------------------
    property QtObject audio: QtObject {
        property real volume: 0.62                     // 0..1 (1.0 = 100%)
        property bool muted: false
        property real micVolume: 0.8
        property bool micMuted: false
        // roles: devId, name, icon (Lucide), active (bool)
        property ListModel outputs: ListModel {
            ListElement { devId: "alsa.speakers"; name: "Speakers"; icon: "speaker"; active: true }
            ListElement { devId: "bluez.buds"; name: "Keza's Buds"; icon: "headphones"; active: false }
            ListElement { devId: "hdmi.1"; name: "HDMI — LG UltraFine"; icon: "monitor"; active: false }
        }
        function setVolume(v) { volume = Math.max(0, Math.min(1, v)); if (volume > 0) muted = false; }
        function setMuted(m) { muted = m; }
        function setMicMuted(m) { micMuted = m; }
        function setOutput(devId) { for (let i = 0; i < outputs.count; ++i) outputs.setProperty(i, "active", outputs.get(i).devId === devId); }
    }

    // ---- display (logind SetBrightness) -----------------------------------
    property QtObject display: QtObject {
        property bool brightnessAvailable: true
        property real brightness: 0.7                  // 0..1
        property bool nightLight: false
        function setBrightness(v) { brightness = Math.max(0.05, Math.min(1, v)); }
        function setNightLight(on) { nightLight = on; }
    }

    // ---- power (UPower + power-profiles-daemon) ---------------------------
    property QtObject power: QtObject {
        property bool hasBattery: true
        property int batteryPercent: 64
        property bool charging: false
        property string timeRemaining: "3 h 40 min"   // "" when unknown
        property string profile: "balanced"            // power-saver | balanced | performance
        function setProfile(p) { profile = p; }
    }

    // ---- media (MPRIS) ----------------------------------------------------
    property QtObject media: QtObject {
        property bool hasPlayer: true
        property string player: "VLC"
        property string title: "Umuhanzi w'Ijuru"
        property string artist: "Meddy"
        property string artUrl: ""
        property bool playing: true
        property real position: 0.34                   // 0..1
        function playPause() { playing = !playing; }
        function next() { console.info("[mock] media next"); }
        function previous() { console.info("[mock] media previous"); }
    }

    // ---- keyboard ---------------------------------------------------------
    property QtObject keyboard: QtObject {
        property var layouts: ["us", "fr"]
        property string current: "us"
        property bool capsLock: false
        function next() { const i = layouts.indexOf(current); current = layouts[(i + 1) % layouts.length]; }
    }

    // ---- appearance (lugh-settingsd; the mock writes Theme directly) -------
    property QtObject appearance: QtObject {
        readonly property bool dark: Theme.dark
        readonly property string accent: Theme.accentName
        property string wallpaperLight: ""   // set by the frame from branding/wallpapers
        property string wallpaperDark: ""
        // Bundled art dir (file URL ending in "/"); "" = /usr/share/backgrounds/lugh/.
        // The preview/qml-check set it to the repo's branding/wallpapers/ when
        // lugh-branding isn't installed, so Wallpaper never probes a missing path.
        property string wallpaperDir: ""
        function setDark(on) { Theme.dark = on; }
        function setAccent(name) { Theme.accentName = name; }
    }

    // ---- OSD requests (media keys → compositor bind → space.lugh.Shell1.ShowOSD)
    property QtObject osd: QtObject {
        // kind: "volume" | "brightness" | "mic" | "caps" | "layout" | "airplane"
        // value: 0..1 for sliders; for toggles 1 = on, 0 = off; ignored for layout.
        signal requested(string kind, real value)
        function show(kind, value) { requested(kind, value); }
    }
}
