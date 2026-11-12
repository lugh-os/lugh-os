// lugh-shell — production root (Lugh mode, "liquid" islands). Composes the
// shell surfaces into wlr-layer-shell windows (LayerShellQt) on Hyprland.
// Loaded by the Rust host (ui/shell/src, context objects LughBackend and
// LughNative); also runs with plain qml6 on the mock Services
// (scripts/shell-run.sh, nested headless KWin).
//
//   every screen:  LockScreen (overlay, exclusive keyboard, only while locked)
//                  Wallpaper  (background)
//                  Panel      (top layer; bottom edge, namespace "lugh-dock";
//                              exclusive zone from the panel; input =
//                              Panel.inputRects). There is no top bar.
//   active screen (the compositor picks the focused output on every map):
//                  LughMenu, Launcher, ControlCenter, NotificationCenter,
//                  Overview, Customize (overlay, full screen, mapped only
//                  while `shown`),
//                  NotificationPopups (overlay, top-right, content-sized)
//
// Appearance: ShellSettings (the user's lugh-shell.conf) drives Theme.dark,
// accentName, transparency, reduceMotion and animationScale, at start and on
// every change. Low power still forces glass off and reduced motion on (the
// user's values return when it clears). The dev flags below (--dark,
// --accent, --reduce-motion) are written into ShellSettings only with
// --dev-config, which scripts/shell-run.sh passes together with a throwaway
// XDG_CONFIG_HOME, so Customize shows them and the user's real config is
// never written; without --dev-config they override Theme for the run only.
//
// Keyboard: Super+B (FocusPanel) → ShellState.focusPanelRequested → the panel
// on the active output enters keyboard mode; its window is then
// keyboard-exclusive and activated until the panel gives the keyboard back
// (Esc, activation, an overlay opening).
//
// Active output: Services.wm.activeOutput (a Qt screen name; "" or unknown →
// the primary, i.e. first, screen). Only that screen's panel publishes
// ShellState geometry, in output-local coordinates (overlay windows cover
// their own output).
//
// Screens: window sizes bind to the output's QQuickScreenInfo (width/height
// notify on resolution, scale and rotation changes), outputs are added and
// removed by name on hot-plug.
//
// Start-up order (docs/dev/shell-performance.md):
//   1. locked at start (restart while locked): the lock windows first, the
//      desktop behind them only after the lock's first frame;
//   2. Wallpaper, Panel synchronously → first frame → Services.shell.ready();
//   3. the rest one at a time, asynchronously, while idle (or at once when an
//      overlay is asked for before its turn). `--lazy-overlays` skips step 3:
//      an overlay is then created on its first open. An overlay asked for
//      before it has loaded is created closed, synchronously, and opened on
//      the next turn of the event loop, so its open animation always starts
//      from a complete surface (never from one created already open).
//
// API notes (details in ui/shell/README.md):
//   - Only the LayerShellQt QML API of Debian trixie (layer-shell-qt 6.3.4) is
//     used: layer, anchors, exclusionZone, keyboardInteractivity, scope,
//     screenConfiguration. `margins` can't be set from QML on Qt 6.8, so the
//     toasts carry their offsets as transparent padding inside the window.
//   - "On the active screen" uses `wantsToBeOnActiveScreen` when the installed
//     LayerShellQt has it (6.6+) and `screenConfiguration: ScreenFromCompositor`
//     otherwise (trixie).
//   - Input regions go through LughNative.setInputRegion(window, [rect…])
//     (window coordinates), at most once per frame. Without LughNative (qml6)
//     the transparent parts of the panel and toast windows take clicks.
//   - Every surface is created through Qt.createComponent("Lugh.Shell", type):
//     a surface that is missing or fails to compile logs one warning and the
//     rest of the shell still runs.
//
// Dev flags (after `--`): --dark, --accent <name>, --reduce-motion,
// --dev-config (write those into ShellSettings; only with a throwaway
// config), --wallpaper-dir <file URL/> (default in the source tree: the
// repo's branding/wallpapers/), --lazy-overlays, --no-media (mock: nothing
// playing), --idle-report <s> (count frames per window for s seconds
// once settled, print them; scripts/shell-run.sh --nested reads it).
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShell
import Lugh.UI
import Lugh.Shell

QtObject {
    id: shell

    // ---- dev flags ----------------------------------------------------------
    readonly property var _args: Qt.application.arguments
    function _arg(name, fallback) {
        const i = _args.indexOf(name);
        return i >= 0 && i + 1 < _args.length ? _args[i + 1] : fallback;
    }
    readonly property bool lazyOverlays: _args.indexOf("--lazy-overlays") >= 0
    readonly property int idleReportSecs: Number(_arg("--idle-report", 0))

    Component.onCompleted: {
        // Before anything can load an image (Wallpaper, Customize thumbnails).
        const wpDir = _arg("--wallpaper-dir", "") || _sourceTreeWallpapers();
        if (wpDir !== "") Services.appearance.wallpaperDir = wpDir;
        // The host attaches before loading this file; qml6 has no backend.
        if (typeof LughBackend !== "undefined" && LughBackend && !Services.live) Services.attach(LughBackend);
        if (_devConfig) {
            if (_args.indexOf("--dark") >= 0) ShellSettings.dark = true;
            if (_arg("--accent", "") !== "") ShellSettings.accent = _arg("--accent", "");
            if (_args.indexOf("--reduce-motion") >= 0) ShellSettings.reduceMotion = true;
        }
        _applySettings();
        // Mock only: the media equalizer in the tray animates while playing.
        if (_args.indexOf("--no-media") >= 0 && !Services.live) Services.media.playing = false;
        startLocked = Services.session.locked;
        _applyLowPower();
        _syncScreens();     // creates the per-screen windows
    }

    // Run from the source tree (ui/shell/qml/main.qml, not installed under
    // /usr and not embedded): the repo's wallpapers, so nothing probes
    // /usr/share/backgrounds/lugh when lugh-branding isn't installed.
    function _sourceTreeWallpapers() {
        const self = Qt.resolvedUrl("main.qml").toString();
        if (!self.startsWith("file://") || self.startsWith("file:///usr/") || !/\/ui\/shell\/qml\/main\.qml$/.test(self))
            return "";
        return Qt.resolvedUrl("../../../branding/wallpapers/").toString();
    }

    // ---- appearance from ShellSettings ---------------------------------------------
    // Dev flags: --dark, --accent <name>, --reduce-motion. With --dev-config
    // they were written into ShellSettings at start (throwaway config) and
    // the user may change them in Customize; without, they win for the run.
    readonly property bool _devConfig: _args.indexOf("--dev-config") >= 0
    readonly property bool _flagDark: !_devConfig && _args.indexOf("--dark") >= 0
    readonly property string _flagAccent: _devConfig ? "" : _arg("--accent", "")
    readonly property bool _flagReduce: !_devConfig && _args.indexOf("--reduce-motion") >= 0
    function _applySettings() {
        Theme.dark = _flagDark || ShellSettings.dark;
        Theme.accentName = _flagAccent !== "" ? _flagAccent : ShellSettings.accent;
        if ("animationScale" in Theme) Theme.animationScale = ShellSettings.animationScale;
        const transparency = ShellSettings.transparency;
        const reduce = _flagReduce || ShellSettings.reduceMotion;
        if (_lowPowerOn) {
            // Recorded, shown when low power clears.
            _userTransparency = transparency;
            _userReduceMotion = reduce;
        } else {
            Theme.transparency = transparency;
            Theme.reduceMotion = reduce;
        }
    }
    readonly property Connections _settingsWatch: Connections {
        target: ShellSettings
        function onDarkChanged() { shell._applySettings(); }
        function onAccentChanged() { shell._applySettings(); }
        function onTransparencyChanged() { shell._applySettings(); }
        function onReduceMotionChanged() { shell._applySettings(); }
        function onAnimationScaleChanged() { shell._applySettings(); }
    }

    // ---- low power ------------------------------------------------------------
    // Services.shell.lowPower (software rendering, power saver) forces glass
    // off and reduced motion on. The user's own values are kept and come back
    // when it clears; a change that arrives meanwhile is recorded, not shown.
    property bool _lowPowerOn: false
    property bool _userTransparency: true
    property bool _userReduceMotion: false
    function _applyLowPower() {
        const on = Services.shell.lowPower === true;
        if (on === _lowPowerOn) return;
        if (on) {
            _userTransparency = Theme.transparency;
            _userReduceMotion = Theme.reduceMotion;
            _lowPowerOn = true;
            Theme.transparency = false;
            Theme.reduceMotion = true;
        } else {
            _lowPowerOn = false;
            Theme.transparency = _userTransparency;
            Theme.reduceMotion = _userReduceMotion;
        }
    }
    readonly property Connections _lowPowerWatch: Connections {
        target: Services.shell
        function onLowPowerChanged() { shell._applyLowPower(); }
    }
    readonly property Connections _themeWatch: Connections {
        target: Theme
        enabled: shell._lowPowerOn
        function onTransparencyChanged() {
            if (Theme.transparency) { shell._userTransparency = true; Theme.transparency = false; }
        }
        function onReduceMotionChanged() {
            if (!Theme.reduceMotion) { shell._userReduceMotion = false; Theme.reduceMotion = true; }
        }
    }

    // ---- helpers --------------------------------------------------------------
    readonly property var _components: ({})
    // Component for a Lugh.Shell surface type, or null (warned once).
    function surface(type) {
        if (!type) return null;
        if (_components[type] !== undefined) return _components[type];
        const c = Qt.createComponent("Lugh.Shell", type);
        if (c.status === Component.Error) {
            console.warn("lugh-shell: surface", type, "unavailable:", c.errorString().trim());
            _components[type] = null;
        } else {
            _components[type] = c;
        }
        return _components[type];
    }
    readonly property bool hasNative: typeof LughNative !== "undefined" && LughNative !== null
    // Ask the compositor to map `attached`'s window on the focused output.
    function placeOnActiveScreen(attached) {
        if ("wantsToBeOnActiveScreen" in attached) attached.wantsToBeOnActiveScreen = true;
        else attached.screenConfiguration = LayerShell.Window.ScreenFromCompositor;
    }
    // Rects (surface coordinates) moved by (dx, dy) into window coordinates.
    function offsetRects(rects, dx, dy) {
        const out = [];
        for (let i = 0; rects && i < rects.length; ++i) {
            const r = rects[i];
            if (r && r.width > 0 && r.height > 0) out.push(Qt.rect(r.x + dx, r.y + dy, r.width, r.height));
        }
        return out;
    }

    // ---- start-up sequencing ----------------------------------------------------
    // Locked when the shell started: the desktop waits for the lock's frame.
    property bool startLocked: false
    property bool lockFrame: false
    readonly property bool desktopGate: !startLocked || lockFrame
    // True once a panel has its first frame on screen.
    property bool firstFrame: false
    function _barFrame() {
        if (firstFrame) return;
        firstFrame = true;
        Services.shell.ready();
        console.info("lugh-shell: first-frame-epoch-ms", Date.now());
        if (idleReportSecs > 0) _idleSettle.start();
    }
    // No frame within 2 s (no output, broken surface): go on anyway.
    readonly property Timer _frameFallback: Timer {
        interval: 2000
        running: !shell.firstFrame || (shell.startLocked && !shell.lockFrame)
        onTriggered: { shell.lockFrame = true; shell._barFrame(); }
    }
    // Deferred windows load one after the other: `stage` is the `order` of
    // the one whose turn it is.
    property int stage: 0
    readonly property Timer _stageStep: Timer {
        interval: 30
        onTriggered: shell.stage += 1
    }

    // ---- idle report (dev) --------------------------------------------------------
    property bool counting: false
    readonly property var _windows: []
    readonly property Timer _idleSettle: Timer {
        interval: 3000
        onTriggered: {
            for (const w of shell._windows) w.frames = 0;
            shell.counting = true;
            console.info("lugh-shell: idle-start");
            shell._idleEnd.start();
        }
    }
    readonly property Timer _idleEnd: Timer {
        interval: shell.idleReportSecs * 1000
        onTriggered: {
            shell.counting = false;
            let total = 0;
            const parts = [];
            for (const w of shell._windows) {
                total += w.frames;
                parts.push(w.namespace + (w.screen ? "@" + w.screen.name : "") + "=" + w.frames
                           + (w.visible ? "" : "(unmapped)"));
            }
            console.info("lugh-shell: idle-frames total=" + total + " in " + shell.idleReportSecs + "s: " + parts.join(" "));
        }
    }

    // ---- screens (hot-plug: delegates are added/removed per output name) -----------
    readonly property ListModel _screens: ListModel {}
    function screenNamed(name) {
        const list = Qt.application.screens;
        for (let i = 0; i < list.length; ++i) if (list[i].name === name) return list[i];
        return null;
    }
    function _syncScreens() {
        const names = Qt.application.screens.map(s => s.name);
        for (let i = _screens.count - 1; i >= 0; --i)
            if (names.indexOf(_screens.get(i).name) < 0) _screens.remove(i);
        names.forEach(n => {
            let found = false;
            for (let i = 0; i < _screens.count; ++i) if (_screens.get(i).name === n) found = true;
            if (!found) _screens.append({ name: n, primary: false });
        });
        for (let i = 0; i < _screens.count; ++i)
            _screens.setProperty(i, "primary", _screens.get(i).name === names[0]);
    }
    readonly property Connections _screenWatch: Connections {
        target: Qt.application
        function onScreensChanged() { shell._syncScreens(); }
    }

    // ---- window templates ---------------------------------------------------------
    // A transparent layer-shell window holding one surface. `pad*` are
    // transparent margins between the window edge and the surface.
    component LayerWindow: Window {
        id: lw
        required property string surfaceType
        required property string namespace
        property bool onActiveScreen: false
        property int padTop: 0
        property int padRight: 0
        // Synchronous windows load when `load` is true. Deferred ones load
        // asynchronously after the first frame, when it is their turn
        // (`order`) or as soon as they are `wanted`, and stay loaded.
        property bool load: true
        property bool deferred: false
        property int order: 0
        property bool wanted: false
        // Never preloaded: created on its first open only (rarely used and
        // heavy, e.g. Customize). Its stage passes at once.
        property bool onDemand: false
        // ShellState flag that opens this overlay ("launcherOpen", …); lets
        // a request made before the surface loaded be replayed (below).
        property string stateKey: ""
        property bool _latched: false
        property bool _replay: false
        readonly property bool _turn: deferred && shell.firstFrame
                                      && (wanted || (!shell.lazyOverlays && !onDemand && shell.stage >= order))
        // Deferred / from a signal handler, never from inside a binding
        // update: _openWhenLoaded writes the ShellState flag `wanted` reads.
        on_TurnChanged: if (_turn) {
            if (wanted && stateKey !== "") Qt.callLater(lw._openWhenLoaded);
            else _latched = true;
        }
        function _onStateChanged() {
            if (ShellState[stateKey] && _latched && loader.status !== Loader.Ready) _openWhenLoaded();
        }
        // Asked for before the surface is Ready: take the request back, load
        // synchronously (the surface is created closed), then ask again on
        // the next turn of the event loop. The surface's open animation then
        // starts from a complete, laid-out surface, exactly like a preloaded
        // one, instead of being created already open mid-animation.
        function _openWhenLoaded() {
            if (loader.status === Loader.Ready || stateKey === "" || _replay
                || shell.surface(surfaceType) === null || !(stateKey in ShellState)) {
                _latched = true;
                return;
            }
            const key = stateKey;
            _replay = true;
            ShellState[key] = false;
            _latched = true;   // with _replay set the Loader loads synchronously
            Qt.callLater(() => { lw._replay = false; ShellState[key] = true; });
        }
        readonly property Item surface: loader.item as Item
        readonly property real surfaceImplicitWidth: surface ? surface.implicitWidth : 0
        readonly property real surfaceImplicitHeight: surface ? surface.implicitHeight : 0
        // Input region in window coordinates; null = the whole window.
        property var inputRects: null
        property int frames: 0

        color: "transparent"
        flags: Qt.FramelessWindowHint
        title: namespace
        LayerShell.Window.scope: namespace
        LayerShell.Window.exclusionZone: -1
        LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone

        Loader {
            id: loader
            x: 0
            y: lw.padTop
            width: lw.width - lw.padRight
            height: lw.height - lw.padTop
            focus: true
            active: lw.deferred ? lw._latched : lw.load
            // An overlay asked for before its turn is needed now.
            // (Overlays with a stateKey are replayed instead, see above.)
            asynchronous: lw.deferred && !lw._replay && !(lw.wanted && lw.stateKey === "")
            sourceComponent: shell.surface(lw.surfaceType)
        }
        // Its turn and loaded, failed or absent: let the next one load.
        readonly property bool _done: deferred && shell.firstFrame && !shell.lazyOverlays && shell.stage === order
                                      && (onDemand || loader.status === Loader.Ready || loader.status === Loader.Error
                                          || shell.surface(surfaceType) === null)
        on_DoneChanged: if (_done) shell._stageStep.start()

        // Input mask, at most once per frame (the tray width animates).
        function _applyMask() {
            if (shell.hasNative && visible && inputRects !== null) LughNative.setInputRegion(lw, inputRects);
        }
        Timer { id: maskTimer; interval: 16; onTriggered: lw._applyMask() }
        onInputRectsChanged: if (shell.hasNative && visible) maskTimer.start()
        onVisibleChanged: if (visible) _applyMask()

        Connections {
            target: lw
            enabled: shell.counting
            function onFrameSwapped() { lw.frames += 1; }
        }
        Component.onCompleted: {
            if (stateKey !== "" && (stateKey + "Changed") in ShellState)
                ShellState[stateKey + "Changed"].connect(lw._onStateChanged);
            if (onActiveScreen) shell.placeOnActiveScreen(LayerShell.Window);
            shell._windows.push(lw);
        }
        Component.onDestruction: {
            const i = shell._windows.indexOf(lw);
            if (i >= 0) shell._windows.splice(i, 1);
        }
    }

    // Full-screen overlay: mapped only while the surface is `shown`, keyboard
    // exclusive while it `wantsKeyboard`.
    component OverlayWindow: LayerWindow {
        onActiveScreen: true
        deferred: true
        visible: surface !== null && surface.shown === true
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom
                                   | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
        LayerShell.Window.keyboardInteractivity: surface && surface.wantsKeyboard
                                                 ? LayerShell.Window.KeyboardInteractivityExclusive
                                                 : LayerShell.Window.KeyboardInteractivityNone
        onVisibleChanged: if (visible) requestActivate()
    }

    // ---- per-screen surfaces ---------------------------------------------------------
    readonly property Instantiator perScreen: Instantiator {
        model: shell._screens
        delegate: QtObject {
            id: perScreen
            required property string name
            required property bool primary
            // Re-evaluated when the screen list changes (hot-plug); its
            // width/height notify on resolution, scale and rotation changes.
            readonly property var screenInfo: shell.screenNamed(name)
            readonly property int screenWidth: screenInfo ? screenInfo.width : 0
            readonly property int screenHeight: screenInfo ? screenInfo.height : 0
            // Window x/y at the output's origin: Qt re-assigns a window to the
            // screen its geometry lies on when it is shown, so at (0, 0) every
            // per-screen window (and its layer surface) went to the first
            // output. The compositor ignores the position otherwise.
            readonly property int screenX: screenInfo ? screenInfo.virtualX : 0
            readonly property int screenY: screenInfo ? screenInfo.virtualY : 0
            // The focused output (Services.wm.activeOutput); "" or a name no
            // screen has → the primary one.
            readonly property bool active: {
                const a = Services.wm.activeOutput;
                return a !== "" && shell.screenNamed(a) !== null ? a === name : primary;
            }

            // Lock screen, declared first so a restart while locked maps it
            // before anything else. GAP: production must use
            // ext-session-lock-v1 (ui/shell/README.md); this overlay is not a
            // secure lock (a crash unlocks).
            readonly property Window lock: LayerWindow {
                id: lockWin
                surfaceType: "LockScreen"
                namespace: "lugh-lock"
                screen: perScreen.screenInfo
                x: perScreen.screenX
                y: perScreen.screenY
                width: perScreen.screenWidth
                height: perScreen.screenHeight
                // Synchronously when locked at start, else lazily (deferred).
                deferred: !shell.startLocked
                load: shell.startLocked
                order: 5
                wanted: Services.session.locked
                visible: surface !== null && surface.shown === true
                LayerShell.Window.layer: LayerShell.Window.LayerOverlay
                LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom
                                           | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
                LayerShell.Window.keyboardInteractivity: surface && surface.wantsKeyboard
                                                         ? LayerShell.Window.KeyboardInteractivityExclusive
                                                         : LayerShell.Window.KeyboardInteractivityNone
                onVisibleChanged: if (visible && perScreen.primary) requestActivate()
                Connections {
                    target: lockWin
                    enabled: shell.startLocked && !shell.lockFrame
                    function onFrameSwapped() { shell.lockFrame = true; }
                }
            }

            readonly property Window wallpaper: LayerWindow {
                id: wallWin
                surfaceType: "Wallpaper"
                namespace: "lugh-wallpaper"
                load: shell.desktopGate
                screen: perScreen.screenInfo
                x: perScreen.screenX
                y: perScreen.screenY
                width: perScreen.screenWidth
                height: perScreen.screenHeight
                visible: surface !== null
                LayerShell.Window.layer: LayerShell.Window.LayerBackground
                LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom
                                           | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
                Binding { target: wallWin.surface; when: wallWin.surface !== null; property: "dark"; value: Theme.dark }
            }

            // The bottom Panel. Namespace "lugh-dock": Hyprland layer rules
            // and the usable-area code key on it.
            readonly property Window panel: LayerWindow {
                id: panelWin
                surfaceType: "Panel"
                namespace: "lugh-dock"
                load: shell.desktopGate
                screen: perScreen.screenInfo
                x: perScreen.screenX
                y: perScreen.screenY + perScreen.screenHeight - height
                width: perScreen.screenWidth
                height: Math.max(1, surfaceImplicitHeight)
                visible: surface !== null
                LayerShell.Window.layer: LayerShell.Window.LayerTop
                LayerShell.Window.anchors: LayerShell.Window.AnchorBottom | LayerShell.Window.AnchorLeft
                                           | LayerShell.Window.AnchorRight
                LayerShell.Window.exclusionZone: surface && surface.exclusiveZone !== undefined ? surface.exclusiveZone : 0
                // Keyboard mode (Super+B): exclusive, so the panel gets the
                // keyboard without a click and keeps it until it lets go
                // (the compositor then refocuses the previous window). A
                // context menu opened with the pointer: on demand.
                readonly property bool keyboardMode: surface !== null && surface.keyboardMode === true
                LayerShell.Window.keyboardInteractivity: keyboardMode ? LayerShell.Window.KeyboardInteractivityExclusive
                                                         : surface && surface.menuOpen
                                                         ? LayerShell.Window.KeyboardInteractivityOnDemand
                                                         : LayerShell.Window.KeyboardInteractivityNone
                onKeyboardModeChanged: if (keyboardMode) requestActivate()
                // Whole window while a menu is open (outside click closes it),
                // else only the visible panel (and its toast).
                inputRects: !surface ? null
                    : surface.menuOpen ? [Qt.rect(0, 0, width, height)]
                    : surface.inputRects ? surface.inputRects : [surface.inputRect]
                // Output-local coordinates for ShellState; only the panel on
                // the active output publishes (and answers Super+B).
                Binding { target: panelWin.surface; when: panelWin.surface !== null; property: "screenHeight"; value: perScreen.screenHeight }
                Binding { target: panelWin.surface; when: panelWin.surface !== null; property: "publish"; value: perScreen.active }
                Connections {
                    target: panelWin
                    enabled: !shell.firstFrame
                    function onFrameSwapped() { shell._barFrame(); }
                }
            }
        }
    }

    // ---- active-screen surfaces --------------------------------------------------------
    // Toasts: top-right corner, content-sized (no top bar any more). The
    // offsets from the edges (10 px) are transparent padding.
    // Mapped as soon as there is a popup, even at 1×1: layouts only compute
    // implicit sizes once polished in a visible window.
    readonly property Window notificationPopups: LayerWindow {
        surfaceType: "NotificationPopups"
        namespace: "lugh-notifications"
        onActiveScreen: true
        deferred: true
        order: 0
        wanted: Services.notifications.popups.count > 0
        padTop: 10
        padRight: 10
        width: Math.max(1, surfaceImplicitWidth + padRight)
        height: Math.max(1, surfaceImplicitHeight + padTop)
        visible: surface !== null && (surface.shown === true || Services.notifications.popups.count > 0)
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorRight
        LayerShell.Window.exclusionZone: 0
        inputRects: !surface ? null
            : surface.inputRects ? shell.offsetRects(surface.inputRects, 0, padTop)
            : [Qt.rect(0, padTop, surfaceImplicitWidth, surfaceImplicitHeight)]
    }
    readonly property Window launcher: OverlayWindow {
        surfaceType: "Launcher"; namespace: "lugh-launcher"
        order: 1; stateKey: "launcherOpen"; wanted: ShellState.launcherOpen
    }
    readonly property Window controlCenter: OverlayWindow {
        surfaceType: "ControlCenter"; namespace: "lugh-controlcenter"
        order: 2; stateKey: "controlCenterOpen"; wanted: ShellState.controlCenterOpen
    }
    readonly property Window notificationCenter: OverlayWindow {
        surfaceType: "NotificationCenter"; namespace: "lugh-notification-center"
        order: 3; stateKey: "notificationCenterOpen"; wanted: ShellState.notificationCenterOpen
    }
    readonly property Window lughMenu: OverlayWindow {
        surfaceType: "LughMenu"; namespace: "lugh-menu"
        order: 4; stateKey: "lughMenuOpen"; wanted: ShellState.lughMenuOpen
    }
    readonly property Window overview: OverlayWindow {
        surfaceType: "Overview"; namespace: "lugh-overview"
        order: 6; stateKey: "overviewOpen"; wanted: ShellState.overviewOpen
    }
    readonly property Window customize: OverlayWindow {
        surfaceType: "Customize"; namespace: "lugh-customize"
        order: 7; stateKey: "customizeOpen"; wanted: ShellState.customizeOpen
        onDemand: true
    }
}
