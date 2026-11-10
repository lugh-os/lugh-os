// Lugh desktop preview: the whole Lugh-mode desktop in ONE normal window, laid
// out exactly as the layer-shell surfaces of main.qml appear on screen, so it
// can be seen and screenshotted on any machine (no Hyprland needed).
//
//   scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
//       [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
//       [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast]
//       [--query <text>] [--screenshot <out.png>] [--measure]
//       [--wallpaper-dir <file URL/>]   (set by the script when needed)
//
// Keys: Meta/Ctrl+Space launcher · Ctrl+C control center · Ctrl+N
// notifications · Ctrl+L lock · Ctrl+D dark toggle · Esc closes.
//
// Stacking mirrors the layer-shell layers: background (Wallpaper) < app
// windows < top (Bar, Dock) < overlay (menus, centers, toasts, OSD, lock).
// Glass: behind glass the compositor blurs; here the pre-blurred wallpaper
// (`Wallpaper { blurred: true }`) is drawn under each glass surface instead.
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
    readonly property string startState: arg("--state", "none")
    readonly property string shotPath: arg("--screenshot", "")

    width: Number(arg("--width", 1440))
    height: Number(arg("--height", 900))
    visible: true
    color: "#000000"
    title: "Lugh preview"

    // Layer-shell geometry (contract in ui/shell/README.md).
    readonly property int barHeight: bar.item ? bar.item.implicitHeight : 30
    readonly property int dockZone: dock.item ? dock.item.exclusiveZone : 0
    // Theme.backdrop (preview-only hook in Lugh.UI): when Theme has it,
    // GlassPanel draws the blurred wallpaper itself and the frame-side
    // fallback below the Bar/Dock is switched off.
    readonly property bool themeBackdrop: "backdrop" in Theme

    // Surfaces are created only once Theme/Services are configured from the
    // args (no light→dark cross-fade at start, no wallpaper lookup misses).
    property bool configured: false

    // A surface from Lugh.Shell, tolerant of missing types.
    component Surface: Loader {
        required property string type
        active: win.configured
        sourceComponent: Opt.component("Lugh.Shell", type)
    }
    // A full-screen overlay surface: drawn only while `shown` (an unmapped
    // layer window in production), takes focus while open.
    component Overlay: Surface {
        id: ov
        anchors.fill: parent
        // Created asynchronously after the first frame, as in main.qml.
        active: win.configured && win._firstFrame
        asynchronous: true
        readonly property bool shown: item !== null && item.shown === true
        visible: shown
        onShownChanged: {
            if (shown && item.wantsKeyboard !== false) ov.forceActiveFocus();
            else if (!shown && ov.activeFocus) desk.forceActiveFocus();
        }
    }

    // Simulated blur under a surface's `panelItem` (when it has one).
    component Backdrop: PanelBackdrop {
        required property Loader surface
        source: blurredWall
        panel: !win.themeBackdrop && surface.item && surface.item.panelItem
               ? surface.item.panelItem : null
    }

    Item {
        id: desk
        anchors.fill: parent
        focus: true

        // ---- background layer ---------------------------------------------
        // Pre-blurred wallpaper, under the sharp one: the source of every
        // glass backdrop (sampled through ShaderEffectSource).
        Surface {
            id: blurredWall
            type: "Wallpaper"
            anchors.fill: parent
            onLoaded: item.blurred = true
        }
        Surface {
            id: wallpaper
            type: "Wallpaper"
            anchors.fill: parent
        }

        // ---- app windows (work area between the bar and the dock zone) -----
        Item {
            id: windows
            anchors { fill: parent; topMargin: win.barHeight; bottomMargin: win.dockZone }
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

            MockWindow {
                id: filesWin
                title: "Documents"
                x: Math.round(windows.width * 0.05)
                y: Math.round(windows.height * 0.05)
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
                y: Math.round(windows.height * 0.08)
                width: Math.round(windows.width * 0.55)
                height: Math.round(windows.height * 0.8)
                z: windows.stack.indexOf("browser")
                focused: windows.focusedId === "browser"
                onActivated: windows.focusWindow("browser")
                BrowserContent { anchors.fill: parent }
            }
        }

        // ---- top layer ------------------------------------------------------
        GlassBackdrop {
            visible: !win.themeBackdrop && bar.item !== null && blurredWall.item !== null
            source: blurredWall
            x: bar.x; y: bar.y
            width: bar.width; height: bar.height
        }
        Surface {
            id: bar
            type: "Bar"
            x: 0; y: 0
            width: parent.width
            height: item ? item.implicitHeight : 0
        }

        GlassBackdrop {
            readonly property rect r: dock.item ? dock.item.inputRect : Qt.rect(0, 0, 0, 0)
            visible: !win.themeBackdrop && dock.item !== null && blurredWall.item !== null && r.width > 0
            source: blurredWall
            radius: Theme.radiusXl
            x: dock.x + r.x; y: dock.y + r.y
            width: r.width; height: r.height
        }
        Surface {
            id: dock
            type: "Dock"
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: item ? item.implicitHeight : 0
        }

        // ---- overlay layer (most recently stacked on top) -------------------
        // Each overlay that exposes `readonly property Item panelItem` (its
        // glass panel) gets the simulated blur under that panel.
        Backdrop { surface: lughMenu }
        Overlay { id: lughMenu; type: "LughMenu" }
        Backdrop { surface: launcher }
        Overlay { id: launcher; type: "Launcher" }
        Backdrop { surface: controlCenter }
        Overlay { id: controlCenter; type: "ControlCenter" }
        Backdrop { surface: notificationCenter }
        Overlay { id: notificationCenter; type: "NotificationCenter" }

        Surface {
            id: popups
            type: "NotificationPopups"
            active: win.configured && win._firstFrame
            asynchronous: true
            // top 30 + 8, right 8 (main.qml: below the bar's exclusive zone).
            anchors { top: parent.top; topMargin: win.barHeight + 8; right: parent.right; rightMargin: 8 }
            visible: item !== null && item.shown === true
        }
        Surface {
            id: osd
            type: "Osd"
            active: win.configured && win._firstFrame
            asynchronous: true
            // 96 px above the bottom edge, but never closer than 24 px to the
            // dock's exclusive zone (main.qml does the same).
            anchors { bottom: parent.bottom; bottomMargin: Math.max(96, win.dockZone + 24); horizontalCenter: parent.horizontalCenter }
            visible: item !== null && item.shown === true
        }

        Overlay { id: lockScreen; type: "LockScreen" }
    }

    // ---- keyboard ---------------------------------------------------------
    Shortcut { sequences: ["Meta+Space", "Ctrl+Space"]; onActivated: ShellState.toggleLauncher() }
    Shortcut { sequence: "Ctrl+C"; enabled: !Services.session.locked; onActivated: ShellState.toggleControlCenter() }
    Shortcut { sequence: "Ctrl+N"; enabled: !Services.session.locked; onActivated: ShellState.toggleNotificationCenter() }
    Shortcut { sequence: "Ctrl+L"; onActivated: { ShellState.closeAll(); Services.session.lock(); } }
    Shortcut { sequence: "Ctrl+D"; onActivated: Theme.dark = !Theme.dark }
    Shortcut { sequence: "Esc"; enabled: ShellState.anyOverlayOpen; onActivated: ShellState.closeAll() }

    // ---- start-up -----------------------------------------------------------
    // --state is applied once every deferred surface has loaded (or failed).
    readonly property bool overlaysReady: _firstFrame
        && [lughMenu, launcher, controlCenter, notificationCenter, lockScreen, popups, osd]
           .every(l => l.status !== Loader.Loading && (l.status === Loader.Ready || l.sourceComponent === null))
    onOverlaysReadyChanged: if (overlaysReady) applyState(startState)

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
        case "controlcenter": ShellState.toggleControlCenter(); break;
        case "notifications": ShellState.toggleNotificationCenter(); break;
        case "menu": ShellState.toggleLughMenu(); break;
        case "lock": Services.session.lock(); break;
        case "osd": Services.osd.show("volume", 0.62); break;
        case "toast":
            Services.notifications.notify("Calendar", "Design review in 15 minutes",
                                          "Shell visuals with Keza and Jean-Paul · Room 2");
            Services.notifications.notify("Firefox", "Download complete",
                                          "lugh-0.1-amd64.iso (1.9 GB) is in Downloads.");
            break;
        case "none": case "": break;
        default: console.warn("lugh-preview: unknown --state", s);
        }
        _stateApplied = true;
    }

    Component.onCompleted: {
        if (flag("--dark")) Theme.dark = true;
        Theme.accentName = arg("--accent", "amber");
        if (flag("--reduce-motion")) Theme.reduceMotion = true;
        // Bundled wallpaper dir when lugh-branding isn't installed (passed by
        // scripts/shell-preview.sh); needs Services.appearance.wallpaperDir.
        const wpDir = arg("--wallpaper-dir", "");
        if (wpDir !== "" && "wallpaperDir" in Services.appearance) Services.appearance.wallpaperDir = wpDir;
        configured = true;
        if (themeBackdrop) Theme.backdrop = blurredWall;
    }

    // First frame: printed for the start-up budget (scripts/shell-preview.sh
    // --measure turns it into ms since process start).
    property bool _firstFrame: false
    onFrameSwapped: if (!_firstFrame) {
        _firstFrame = true;
        console.info("lugh-preview: first-frame-epoch-ms", Date.now());
        if (flag("--measure")) measureQuit.start();
    }
    // Quit 1.5 s after the first frame (deferred overlays have loaded by then,
    // so max RSS includes them).
    Timer { id: measureQuit; interval: 1500; onTriggered: Qt.quit() }

    // --screenshot: once the state is applied, let loads and open animations
    // settle (~1.2 s), grab, quit.
    property bool _stateApplied: false
    Timer {
        running: win.shotPath !== "" && win._stateApplied
        interval: 1200
        onTriggered: win.contentItem.grabToImage(r => {
            if (!r.saveToFile(win.shotPath)) {
                console.error("lugh-preview: could not write", win.shotPath);
                Qt.exit(3);
            } else {
                console.info("lugh-preview: wrote", win.shotPath);
                Qt.exit(0);
            }
        })
    }
}
