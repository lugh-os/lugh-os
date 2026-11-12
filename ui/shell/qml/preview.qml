// Lugh desktop preview: the whole Lugh-mode desktop in ONE normal window, laid
// out exactly as the layer-shell surfaces of main.qml appear on screen, so it
// can be seen and screenshotted on any machine (no Hyprland needed).
//
//   scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
//       [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
//       [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast
//                |overview|customize]
//       [--query <text>]                       with --state launcher
//       [--page wifi|bluetooth|sound|power]    with --state controlcenter
//       [--page appearance|panel|clock|…]      with --state customize
//       [--kind volume|brightness|mic|caps|layout|airplane] [--value 0..1]
//                                              with --state osd
//       [--backend ws://127.0.0.1:7777]        live services (lugh-shell-devd)
//       [--screenshot <out.png>] [--shot-delay <ms>] [--measure]
//       [--motion <state> --motion-out <dir>] [--motion-frames 24]
//       [--motion-ms <stop after ms>] [--motion-offset <ms before 1st grab>]
//       [--wallpaper-dir <file URL/>]          (default: the repo's art)
//       [--dev-config]                         (set by the script: see below)
//
// Keys: Meta/Ctrl+Space launcher · Ctrl+C control center · Ctrl+N
// notifications · Ctrl+Tab overview · Ctrl+, customize · Ctrl+L lock ·
// Ctrl+D dark toggle · Ctrl+B keyboard into the panel (Super+B on the
// desktop) · Esc closes.
//
// Config: scripts/shell-preview.sh runs this with a throwaway XDG_CONFIG_HOME
// and --dev-config; --dark / --accent / --reduce-motion (and Ctrl+D) are then
// written into ShellSettings, so Customize shows the same values as the
// screen, and the user's ~/.config/lugh/lugh-shell.conf is never touched.
// Without --dev-config (qml6 by hand) they only set Theme for the run.
//
// Stacking mirrors the layer-shell layers: background (Wallpaper) < app
// windows < top (Panel, at the bottom edge) < overlay (panels, toasts, lock).
// Appearance follows ShellSettings like main.qml; the flags override it.
// Resize the window to check the layout at other screen sizes.
// Glass: on Hyprland the compositor blurs behind glass. Here Theme.backdrop is
// set to a pre-blurred wallpaper and GlassPanel draws the part under itself.
//
// --motion: once everything is loaded and settled, grabs the scene, applies
// <state>, then keeps grabbing every ~33 ms; the frames go to <dir> as
// f-<nn>-<ms>.png (ms since the trigger). A grab of the whole scene takes
// 35–100 ms, so scripts/shell-motion.sh runs several passes whose first grab
// is shifted by --motion-offset and interleaves them into contact sheets.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "preview"
import "preview/optional.js" as Opt

Window {
    id: win

    // ---- args -------------------------------------------------------------
    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }
    readonly property string motionName: arg("--motion", "")
    readonly property string motionDir: arg("--motion-out", "")
    readonly property int motionFrames: Number(arg("--motion-frames", 24))
    readonly property int motionMs: Number(arg("--motion-ms", 0))
    readonly property int motionOffset: Number(arg("--motion-offset", 0))
    // With --motion the state is applied by the capture, not at start.
    readonly property string startState: motionName !== "" ? "none" : arg("--state", "none")
    readonly property string shotPath: arg("--screenshot", "")
    readonly property string backendUrl: arg("--backend", "")

    width: Number(arg("--width", 1440))
    height: Number(arg("--height", 900))
    visible: true
    color: "#000000"
    title: "Lugh preview"

    // Layer-shell geometry (contract in ui/shell/README.md): windows keep
    // clear of the panel's exclusive zone.
    readonly property int panelZone: panel.item && panel.item.exclusiveZone !== undefined ? panel.item.exclusiveZone : 0

    // Surfaces are created only once Theme/Services are configured from the
    // args (no light→dark cross-fade at start, no wallpaper lookup misses)
    // and, with --backend, once it is connected (or 1.5 s passed).
    property bool configured: false

    // A surface from Lugh.Shell, tolerant of missing types.
    component Surface: Loader {
        required property string type
        active: win.configured
        sourceComponent: Opt.component("Lugh.Shell", type)
    }
    // A full-screen overlay surface: drawn only while `shown` (an unmapped
    // layer window in production), takes focus while open. Created
    // asynchronously after the first frame, as in main.qml.
    component Overlay: Surface {
        id: ov
        anchors.fill: parent
        active: win.configured && win._firstFrame
        asynchronous: true
        readonly property bool shown: item !== null && item.shown === true
        visible: shown
        onShownChanged: {
            if (shown && item.wantsKeyboard !== false) ov.forceActiveFocus();
            else if (!shown && ov.activeFocus) desk.forceActiveFocus();
        }
    }

    Item {
        id: desk
        anchors.fill: parent
        focus: true

        // ---- background layer ---------------------------------------------
        // Pre-blurred wallpaper (small file), under the sharp one: what
        // GlassPanel samples through Theme.backdrop.
        Surface {
            id: blurredWall
            type: "Wallpaper"
            anchors.fill: parent
            active: win.configured && Theme.transparency
            onLoaded: item.blurred = true
        }
        Surface {
            id: wallpaper
            type: "Wallpaper"
            anchors.fill: parent
        }

        // ---- app windows (work area above the panel's zone) -------------------
        Item {
            id: windows
            anchors { fill: parent; topMargin: 8; bottomMargin: win.panelZone }
            visible: Services.wm.activeWorkspace === 1

            // Bottom → top. raise() moves an id to the end.
            property var stack: ["files", "terminal", "browser"]
            readonly property string focusedId: stack[stack.length - 1]
            function raise(id) {
                const s = stack.filter(x => x !== id);
                s.push(id);
                stack = s;
            }
            function focusWindow(id) {
                raise(id);
                if (Services.live) return;
                const map = { browser: "0x1", terminal: "0x2" };
                if (map[id]) {
                    Services.wm.activate(map[id]);
                } else {
                    Services.wm.focusedAppId = "lugh-files";
                    Services.wm.focusedAppName = "Files";
                    Services.wm.focusedTitle = "Documents";
                }
            }
            Connections {
                target: Services.wm
                function onFocusedAppIdChanged() {
                    const map = { "firefox": "browser", "org.codeberg.dnkl.foot": "terminal", "lugh-files": "files" };
                    const id = map[Services.wm.focusedAppId];
                    if (id && id !== windows.focusedId) windows.raise(id);
                }
            }

            // Floating windows, 12 px or more clear of the islands' zone.
            MockWindow {
                id: filesWin
                title: "Documents"
                x: Math.round(windows.width * 0.05)
                y: Math.round(windows.height * 0.07)
                width: Math.round(windows.width * 0.42)
                height: Math.round(windows.height * 0.56)
                z: windows.stack.indexOf("files")
                focused: windows.focusedId === "files"
                onActivated: windows.focusWindow("files")
                FilesContent { anchors.fill: parent }
            }
            MockWindow {
                id: terminalWin
                title: "amara@lugh-laptop: ~"
                bodyColor: "#1C1B19"
                titleBarColor: Theme.dark ? "#1C1B19" : "#262522"
                titleColor: focused ? "#EDEBE6" : "#A29D94"
                x: Math.round(windows.width * 0.57)
                y: Math.round(windows.height * 0.44)
                width: Math.round(windows.width * 0.38)
                height: Math.round(windows.height * 0.48)
                z: windows.stack.indexOf("terminal")
                focused: windows.focusedId === "terminal"
                onActivated: windows.focusWindow("terminal")
                TerminalContent { anchors.fill: parent }
            }
            MockWindow {
                id: browserWin
                title: "Lugh — Mozilla Firefox"
                bodyColor: Theme.surface
                titleBarColor: Theme.bg
                x: Math.round(windows.width * 0.2)
                y: Math.round(windows.height * 0.03)
                width: Math.round(windows.width * 0.55)
                height: Math.round(windows.height * 0.86)
                z: windows.stack.indexOf("browser")
                focused: windows.focusedId === "browser"
                onActivated: windows.focusWindow("browser")
                BrowserContent { anchors.fill: parent }
            }
        }

        // ---- top layer ------------------------------------------------------
        Surface {
            id: panel
            type: "Panel"
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: item ? item.implicitHeight : 0
        }

        // ---- overlay layer (most recently stacked on top) -------------------
        Overlay { id: lughMenu; type: "LughMenu" }
        Overlay { id: launcher; type: "Launcher" }
        Overlay { id: controlCenter; type: "ControlCenter" }
        Overlay { id: notificationCenter; type: "NotificationCenter" }
        Overlay { id: overview; type: "Overview" }
        Overlay { id: customize; type: "Customize" }

        Surface {
            id: popups
            type: "NotificationPopups"
            active: win.configured && win._firstFrame
            asynchronous: true
            // Top-right corner, 10 px from the edges (no top bar).
            anchors { top: parent.top; topMargin: 10; right: parent.right; rightMargin: 10 }
            visible: item !== null && item.shown === true
        }

        Overlay { id: lockScreen; type: "LockScreen" }
    }

    // ---- keyboard ---------------------------------------------------------
    Shortcut { sequences: ["Meta+Space", "Ctrl+Space"]; onActivated: ShellState.toggleLauncher() }
    Shortcut { sequence: "Ctrl+C"; enabled: !Services.session.locked; onActivated: ShellState.toggleControlCenter() }
    Shortcut { sequence: "Ctrl+N"; enabled: !Services.session.locked; onActivated: ShellState.toggleNotificationCenter() }
    Shortcut { sequence: "Ctrl+Tab"; enabled: !Services.session.locked; onActivated: ShellState.toggleOverview() }
    Shortcut { sequence: "Ctrl+,"; enabled: !Services.session.locked; onActivated: ShellState.toggleCustomize() }
    Shortcut { sequence: "Ctrl+L"; onActivated: { ShellState.closeAll(); Services.session.lock(); } }
    Shortcut { sequence: "Ctrl+D"; onActivated: win.toggleDark() }
    Shortcut { sequence: "Ctrl+B"; enabled: !Services.session.locked; onActivated: ShellState.focusPanel() }
    Shortcut { sequence: "Esc"; enabled: ShellState.anyOverlayOpen; onActivated: ShellState.closeAll() }

    // ---- live backend (--backend ws://…) ----------------------------------
    // WsBackend is loaded by URL (it needs QtWebSockets, which production
    // never does). Missing file or module: one warning, the mock stays.
    property QtObject wsBackend: null
    function startBackend(url) {
        const c = Qt.createComponent(Qt.resolvedUrl("Lugh/Shell/backend/WsBackend.qml"));
        if (c.status !== Component.Ready) {
            console.warn("lugh-preview: --backend unavailable, using the mock:", c.errorString().trim());
            return false;
        }
        wsBackend = c.createObject(win, { url: url });
        if (wsBackend && wsBackend.connected) backendUp();
        return wsBackend !== null;
    }
    function backendUp() {
        if (!Services.live) {
            Services.attach(wsBackend);
            console.info("lugh-preview: attached to", backendUrl);
        }
        configured = true;
    }
    Connections {
        target: win.wsBackend
        ignoreUnknownSignals: true
        function onConnectedChanged() { if (win.wsBackend.connected) win.backendUp(); }
    }
    Timer {
        id: backendWait
        interval: 1500
        onTriggered: {
            if (!Services.live) console.warn("lugh-preview: no answer from", win.backendUrl, "yet; showing mock data until it connects");
            win.configured = true;
        }
    }

    // ---- start-up -----------------------------------------------------------
    // --state is applied once every deferred surface has loaded (or failed).
    readonly property bool overlaysReady: _firstFrame
        && [lughMenu, launcher, controlCenter, notificationCenter, overview, customize, lockScreen, popups]
           .every(l => l.status !== Loader.Loading && (l.status === Loader.Ready || l.sourceComponent === null))
    onOverlaysReadyChanged: if (overlaysReady) {
        applyState(startState);
        _stateApplied = true;
        if (motionName !== "") motionSettle.start();
    }

    function applyState(s) {
        switch (s) {
        case "launcher": {
            ShellState.openLauncher();
            const q = arg("--query", "");
            if (q !== "") Qt.callLater(() => {
                Services.launcher.search(q);
                const it = launcher.item;
                if (it && "query" in it) it.query = q;
            });
            break;
        }
        case "controlcenter": {
            const page = arg("--page", "");
            if (page !== "") ShellState.openControlCenter(page);
            else ShellState.toggleControlCenter();
            break;
        }
        case "notifications": ShellState.toggleNotificationCenter(); break;
        case "menu": ShellState.toggleLughMenu(); break;
        case "lock": Services.session.lock(); break;
        case "overview": ShellState.openOverview(); break;
        case "customize": ShellState.openCustomize(arg("--page", "")); break;
        case "osd": Services.osd.show(arg("--kind", "volume"), Number(arg("--value", 0.62))); break;
        case "toast":
            Services.notifications.notify("Calendar", "Design review in 15 minutes",
                                          "Shell visuals with Keza and Jean-Paul · Room 2");
            Services.notifications.notify("Firefox", "Download complete",
                                          "lugh-0.1-amd64.iso (1.9 GB) is in Downloads.");
            break;
        case "none": case "": break;
        default: console.warn("lugh-preview: unknown state", s);
        }
    }

    // Appearance from ShellSettings (as main.qml). With --dev-config the
    // flags were written into ShellSettings at start; without, they win for
    // the run (Theme only).
    readonly property bool devConfig: flag("--dev-config")
    function applySettings() {
        Theme.dark = (!devConfig && flag("--dark")) || ShellSettings.dark;
        Theme.accentName = devConfig ? ShellSettings.accent : arg("--accent", ShellSettings.accent);
        Theme.transparency = ShellSettings.transparency;
        Theme.reduceMotion = (!devConfig && flag("--reduce-motion")) || ShellSettings.reduceMotion;
        if ("animationScale" in Theme) Theme.animationScale = ShellSettings.animationScale;
    }
    function toggleDark() {
        if (devConfig) ShellSettings.dark = !ShellSettings.dark;
        else Theme.dark = !Theme.dark;
    }
    // Running from the source tree (always, for the preview): the repo's art,
    // so nothing probes /usr/share/backgrounds/lugh before the flag lands.
    function sourceTreeWallpapers() {
        const self = Qt.resolvedUrl("preview.qml").toString();
        return self.startsWith("file://") && !self.startsWith("file:///usr/")
            ? Qt.resolvedUrl("../../../branding/wallpapers/").toString() : "";
    }
    Connections {
        target: ShellSettings
        function onDarkChanged() { win.applySettings(); }
        function onAccentChanged() { win.applySettings(); }
        function onTransparencyChanged() { win.applySettings(); }
        function onReduceMotionChanged() { win.applySettings(); }
        function onAnimationScaleChanged() { win.applySettings(); }
    }

    Component.onCompleted: {
        // Bundled wallpaper dir when lugh-branding isn't installed (passed by
        // scripts/shell-preview.sh; else the repo's), before any image loads.
        const wpDir = arg("--wallpaper-dir", "") || sourceTreeWallpapers();
        if (wpDir !== "") Services.appearance.wallpaperDir = wpDir;
        if (devConfig) {
            if (flag("--dark")) ShellSettings.dark = true;
            if (arg("--accent", "") !== "") ShellSettings.accent = arg("--accent", "");
            if (flag("--reduce-motion")) ShellSettings.reduceMotion = true;
        }
        applySettings();
        Theme.backdrop = blurredWall;
        if (backendUrl !== "" && startBackend(backendUrl)) {
            if (!configured) backendWait.start();
        } else {
            configured = true;
        }
    }

    // First frame: printed for the start-up budget (scripts/shell-preview.sh
    // --measure turns it into ms since process start).
    property bool _firstFrame: false
    Connections {
        target: win
        enabled: !win._firstFrame
        function onFrameSwapped() {
            win._firstFrame = true;
            console.info("lugh-preview: first-frame-epoch-ms", Date.now());
            if (win.flag("--measure")) measureQuit.start();
        }
    }
    // Quit 1.5 s after the first frame (deferred overlays have loaded by then,
    // so max RSS includes them).
    Timer { id: measureQuit; interval: 1500; onTriggered: Qt.quit() }

    // --screenshot: once the state is applied, let loads and open springs
    // settle, grab, quit. The OSD only stays 1.2 s, so it is caught earlier.
    property bool _stateApplied: false
    Timer {
        running: win.shotPath !== "" && win._stateApplied
        interval: Number(win.arg("--shot-delay", win.startState === "osd" ? 450 : 1200))
        onTriggered: desk.grabToImage(r => {
            if (!r.saveToFile(win.shotPath)) {
                console.error("lugh-preview: could not write", win.shotPath);
                Qt.exit(3);
            } else {
                console.info("lugh-preview: wrote", win.shotPath);
                Qt.exit(0);
            }
        })
    }

    // ---- --motion capture ---------------------------------------------------
    // Grab results are kept in memory and written at the end, so encoding
    // PNGs never stalls the animation being recorded. Each frame carries the
    // time it was asked for, in ms since the trigger (frame 0 = before).
    property var _frames: []
    property double _motionT0: 0
    property double _lastGrab: 0
    Timer { id: motionSettle; interval: 700; onTriggered: win._grabFrame() }
    Timer { id: motionNext; onTriggered: win._grabFrame() }
    function _grabFrame() {
        const asked = Date.now();
        _lastGrab = asked;
        desk.grabToImage(r => {
            const first = _frames.length === 0;
            _frames.push({ image: r, t: first ? 0 : Math.round(asked - _motionT0) });
            if (first) {
                _motionT0 = Date.now();
                applyState(motionName);
            }
            if (_frames.length >= motionFrames || (motionMs > 0 && asked - _motionT0 >= motionMs)) {
                _saveFrames();
                return;
            }
            motionNext.interval = first ? Math.max(1, motionOffset)
                                        : Math.max(1, 33 - (Date.now() - _lastGrab));
            motionNext.start();
        });
    }
    function _saveFrames() {
        const pad = (n, w) => String(n).padStart(w, "0");
        for (let i = 0; i < _frames.length; ++i) {
            const f = _frames[i];
            const path = motionDir + "/f-" + pad(i, 2) + "-" + pad(f.t, 4) + ".png";
            if (!f.image.saveToFile(path)) {
                console.error("lugh-preview: could not write", path);
                Qt.exit(3);
                return;
            }
        }
        console.info("lugh-preview: wrote", _frames.length, "frames over", _frames[_frames.length - 1].t, "ms to", motionDir);
        Qt.exit(0);
    }
}
