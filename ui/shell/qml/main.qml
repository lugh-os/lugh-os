// lugh-shell — production root. Composes the shell surfaces into wlr-layer-shell
// windows (LayerShellQt) on Hyprland. Run it with scripts/shell-run.sh today;
// the Rust binary (cxx-qt) loads this same file later.
//
//   per screen:   Wallpaper (background layer) + Bar (top layer, exclusive 30)
//   primary only: Dock (top layer, exclusive = Dock.exclusiveZone)
//   active screen (the compositor picks the focused output on every map):
//                 LughMenu, Launcher, ControlCenter, NotificationCenter,
//                 NotificationPopups, Osd, LockScreen (overlay layer)
//
// API notes (details in ui/shell/README.md):
//   - Only the LayerShellQt QML API of Debian trixie (layer-shell-qt 6.3.4) is
//     used: layer, anchors, exclusionZone, keyboardInteractivity, scope,
//     screenConfiguration. `margins` is not used: on Qt 6.8 a QMargins can't be
//     built from QML ("Unable to assign QJSValue to QMargins"), so toasts carry
//     their offsets as transparent padding inside the window instead.
//   - "On the active screen" uses `wantsToBeOnActiveScreen` when the installed
//     LayerShellQt has it (6.6+) and `screenConfiguration: ScreenFromCompositor`
//     otherwise (trixie).
//   - Input regions: QML can't call QWindow::setMask. When the Rust binary
//     injects the `LughNative` context object, the Dock and the notification
//     toasts get exact input regions through LughNative.setInputRegion(window,
//     [rect…]); without it their transparent headroom/padding takes clicks.
//   - Every surface is created through Qt.createComponent("Lugh.Shell", type):
//     a surface that is missing or fails to compile logs one warning and the
//     rest of the shell still runs.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShell
import Lugh.UI
import Lugh.Shell

QtObject {
    id: shell

    // ---- dev flags (production reads lugh-settingsd instead) --------------
    readonly property var _args: Qt.application.arguments
    function _arg(name, fallback) {
        const i = _args.indexOf(name);
        return i >= 0 && i + 1 < _args.length ? _args[i + 1] : fallback;
    }
    Component.onCompleted: {
        if (_args.indexOf("--dark") >= 0) Theme.dark = true;
        Theme.accentName = _arg("--accent", Theme.accentName);
        if (_args.indexOf("--reduce-motion") >= 0) Theme.reduceMotion = true;
        const wpDir = _arg("--wallpaper-dir", "");
        if (wpDir !== "" && "wallpaperDir" in Services.appearance) Services.appearance.wallpaperDir = wpDir;
        _syncScreens();
    }

    // ---- helpers ----------------------------------------------------------
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
    // Native input-region hook (Rust side). Rects are in window coordinates.
    readonly property bool hasNative: typeof LughNative !== "undefined" && LughNative !== null
    function setInputRegion(win, rects) {
        if (hasNative) LughNative.setInputRegion(win, rects);
    }
    // Ask the compositor to map `attached`'s window on the focused output.
    function placeOnActiveScreen(attached) {
        if ("wantsToBeOnActiveScreen" in attached) attached.wantsToBeOnActiveScreen = true;
        else attached.screenConfiguration = LayerShell.Window.ScreenFromCompositor;
    }

    // True once any bar has drawn its first frame (or after 1 s without one);
    // deferred surfaces start loading then.
    property bool firstFrame: false
    readonly property Timer _firstFrameFallback: Timer {
        interval: 1000; running: !shell.firstFrame; onTriggered: shell.firstFrame = true
    }

    // ---- screens (hot-plug: delegates are added/removed per output name) --
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
        names.forEach((n, idx) => {
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

    // ---- window templates --------------------------------------------------
    // A transparent layer-shell window holding one surface. `pad*` are
    // transparent margins between the window edge and the surface.
    component LayerWindow: Window {
        id: lw
        required property string surfaceType
        required property string namespace
        property bool onActiveScreen: false
        property int padTop: 0
        property int padRight: 0
        property int padBottom: 0
        // Created asynchronously after the shell's first frame (overlays):
        // keeps start-up to the bar/dock/wallpaper only.
        property bool deferred: false
        readonly property Item surface: loader.item as Item
        readonly property real surfaceImplicitWidth: surface ? surface.implicitWidth : 0
        readonly property real surfaceImplicitHeight: surface ? surface.implicitHeight : 0

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
            height: lw.height - lw.padTop - lw.padBottom
            focus: true
            active: !lw.deferred || shell.firstFrame
            asynchronous: lw.deferred
            sourceComponent: shell.surface(lw.surfaceType)
        }
        Component.onCompleted: if (onActiveScreen) shell.placeOnActiveScreen(LayerShell.Window)
    }

    // Full-screen overlay: mapped only while the surface is `shown`, keyboard
    // exclusive while it `wantsKeyboard`.
    component OverlayWindow: LayerWindow {
        id: ow
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

    // ---- per-screen surfaces ----------------------------------------------
    readonly property Instantiator perScreen: Instantiator {
        model: shell._screens
        delegate: QtObject {
            id: perScreen
            required property string name
            required property bool primary
            readonly property var screenInfo: shell.screenNamed(name)

            readonly property Window wallpaper: LayerWindow {
                id: wallWin
                surfaceType: "Wallpaper"
                namespace: "lugh-wallpaper"
                screen: perScreen.screenInfo
                width: screen ? screen.width : 0
                height: screen ? screen.height : 0
                visible: surface !== null
                LayerShell.Window.layer: LayerShell.Window.LayerBackground
                LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom
                                           | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
                Binding { target: wallWin.surface; when: wallWin.surface !== null; property: "dark"; value: Theme.dark }
            }

            readonly property Window bar: LayerWindow {
                surfaceType: "Bar"
                namespace: "lugh-bar"
                screen: perScreen.screenInfo
                width: screen ? screen.width : 0
                height: Math.max(1, surfaceImplicitHeight || 30)
                visible: surface !== null
                LayerShell.Window.layer: LayerShell.Window.LayerTop
                LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorLeft
                                           | LayerShell.Window.AnchorRight
                LayerShell.Window.exclusionZone: height
                onFrameSwapped: if (!shell.firstFrame) shell.firstFrame = true
            }

            // One dock, on the primary output.
            readonly property Window dock: LayerWindow {
                id: dockWin
                surfaceType: perScreen.primary ? "Dock" : ""
                namespace: "lugh-dock"
                screen: perScreen.screenInfo
                width: screen ? screen.width : 0
                height: Math.max(1, surfaceImplicitHeight)
                visible: perScreen.primary && surface !== null
                LayerShell.Window.layer: LayerShell.Window.LayerTop
                LayerShell.Window.anchors: LayerShell.Window.AnchorBottom | LayerShell.Window.AnchorLeft
                                           | LayerShell.Window.AnchorRight
                LayerShell.Window.exclusionZone: surface ? surface.exclusiveZone : 0
                LayerShell.Window.keyboardInteractivity: surface && surface.menuOpen
                                                         ? LayerShell.Window.KeyboardInteractivityOnDemand
                                                         : LayerShell.Window.KeyboardInteractivityNone
                // Whole window while a menu is open (outside click closes it),
                // else only the visible dock.
                readonly property var inputRects: !surface ? []
                    : surface.menuOpen ? [Qt.rect(0, 0, width, height)] : [surface.inputRect]
                onInputRectsChanged: if (visible) shell.setInputRegion(dockWin, inputRects)
                onVisibleChanged: if (visible) shell.setInputRegion(dockWin, inputRects)
            }
        }
    }

    // ---- overlays (one each, on the active screen) -------------------------
    readonly property Window lughMenu: OverlayWindow { surfaceType: "LughMenu"; namespace: "lugh-menu" }
    readonly property Window launcher: OverlayWindow { surfaceType: "Launcher"; namespace: "lugh-launcher" }
    readonly property Window controlCenter: OverlayWindow { surfaceType: "ControlCenter"; namespace: "lugh-controlcenter" }
    readonly property Window notificationCenter: OverlayWindow { surfaceType: "NotificationCenter"; namespace: "lugh-notification-center" }

    // Content-sized windows are mapped as soon as the surface is `shown`, even at
    // 1×1: positioners and layouts only compute implicit sizes once polished in
    // a visible window, so gating on the size would never map them.
    // Toasts: anchored top-right. exclusionZone 0 makes the compositor place
    // them below the bar's exclusive zone; the 8 px gap is transparent padding.
    readonly property Window notificationPopups: LayerWindow {
        id: popupsWin
        surfaceType: "NotificationPopups"
        namespace: "lugh-notifications"
        onActiveScreen: true
        deferred: true
        padTop: 8
        padRight: 8
        width: Math.max(1, surfaceImplicitWidth + padRight)
        height: Math.max(1, surfaceImplicitHeight + padTop)
        // Also map on new popups: the surface's `shown` follows its ListView,
        // which doesn't update while the window is unmapped.
        visible: surface !== null && (surface.shown === true || Services.notifications.popups.count > 0)
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorRight
        LayerShell.Window.exclusionZone: 0
        readonly property rect inputRect: Qt.rect(0, padTop, surfaceImplicitWidth, surfaceImplicitHeight)
        onInputRectChanged: if (visible) shell.setInputRegion(popupsWin, [inputRect])
        onVisibleChanged: if (visible) shell.setInputRegion(popupsWin, [inputRect])
    }

    // Dock exclusive zone on the primary screen (0 when hidden / no dock).
    readonly property int dockZone: {
        for (let i = 0; i < shell.perScreen.count; ++i) {
            const o = shell.perScreen.objectAt(i);
            if (o && o.primary && o.dock.surface) return o.dock.surface.exclusiveZone;
        }
        return 0;
    }

    // OSD: bottom centre, 96 px above the screen edge but at least 24 px above
    // the dock's exclusive zone (exclusion zone -1, so the offset is ours).
    // Takes no input at all, so the padding below it is free.
    readonly property Window osd: LayerWindow {
        surfaceType: "Osd"
        namespace: "lugh-osd"
        onActiveScreen: true
        deferred: true
        padBottom: Math.max(96, shell.dockZone + 24)
        flags: Qt.FramelessWindowHint | Qt.WindowTransparentForInput
        width: Math.max(1, surfaceImplicitWidth)
        height: Math.max(1, surfaceImplicitHeight + padBottom)
        visible: surface !== null && surface.shown === true
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.anchors: LayerShell.Window.AnchorBottom
    }

    // Lock screen. GAP: production must use ext-session-lock-v1 (spec FR-6),
    // which QML can't reach; this overlay is NOT a secure lock (a crash
    // unlocks, other outputs stay visible). See ui/shell/README.md.
    readonly property Window lockScreen: OverlayWindow { surfaceType: "LockScreen"; namespace: "lugh-lock" }
}
