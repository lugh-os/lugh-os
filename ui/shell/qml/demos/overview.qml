// Workspace overview demo (1440×900): the wallpaper with the overview open on
// the mock Services (2 × 2 grid, windows on workspaces 1 and 2).
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/overview.qml \
//       /tmp/lugh-shots/overview/light.png 1440 900 1200
//
// Args:
//   --dark, --accent <name>, --reduce-motion
//   --grid <rows>x<cols>   e.g. 3x3 (ShellSettings.workspaceRows/Cols)
//   --hide-empty           ShellSettings.overviewShowEmpty = false
//                          Both write ShellSettings, which persists to
//                          lugh-shell.conf; the demo puts the old values back
//                          on exit, but run it with XDG_CONFIG_HOME=/tmp/… to
//                          be safe.
//   --many                 more windows, long titles, one without geometry
//   --others               windows on workspaces past the grid (5, 7, 12):
//                          the "Other workspaces" strip
//   --active <n>           Services.wm.activeWorkspace = n (e.g. 7: in the strip)
//   --select <n>           keyboard selection on workspace n
//   --query <text>         type a search
//   --motion <open|close> --out <dir>
//                          grab the scene every ~33 ms into <dir>/<motion>-NN.png,
//                          then quit (pass a long qml-shot delay, e.g. 20000).
// Glass: the compositor blurs behind the overlay; here the overview draws the
// pre-blurred wallpaper (Theme.backdrop) under its tint.
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.lastIndexOf(name);    // ours come after qml-shot's own --out/--delay
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }

    readonly property string motion: arg("--motion", "")
    readonly property string outDir: arg("--out", "/tmp/lugh-shots/overview/motion")

    // Demo settings must not touch the user's lugh-shell.conf: remember and
    // restore the values changed here.
    property var _saved: null
    function applySettings() {
        if (!flag("--grid") && !flag("--hide-empty")) return;
        const s = ShellSettings;
        _saved = { rows: s.workspaceRows, cols: s.workspaceCols, empty: s.overviewShowEmpty };
        const g = arg("--grid", "2x2").split("x");
        s.workspaceRows = Math.max(1, Math.min(4, Number(g[0]) || 2));
        s.workspaceCols = Math.max(1, Math.min(4, Number(g[1]) || 2));
        s.overviewShowEmpty = !flag("--hide-empty");
    }
    Component.onDestruction: if (_saved) {
        ShellSettings.workspaceRows = _saved.rows;
        ShellSettings.workspaceCols = _saved.cols;
        ShellSettings.overviewShowEmpty = _saved.empty;
    }

    property bool configured: false
    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion");
        applySettings();
        if (flag("--many")) many();
        if (flag("--others")) others();
        if (flag("--active")) Services.wm.activeWorkspace = Number(arg("--active", 1)) || 1;
        configured = true;
        if (motion === "") start.start();
        else settle.start();
    }

    function many() {
        const t = Services.wm.toplevels;
        t.append({ winId: "0x4", appId: "org.gnome.Nautilus", title: "Documents — Projects — Lugh OS design review, final final (2)",
                   workspace: 2, focused: false, x: 80, y: 520, width: 640, height: 420, monitorWidth: 1920, monitorHeight: 1080 });
        t.append({ winId: "0x5", appId: "org.codeberg.dnkl.foot", title: "cargo test -p lugh-shell-core", workspace: 3,
                   focused: false, x: 0, y: 0, width: 0, height: 0, monitorWidth: 0, monitorHeight: 0 });
        t.append({ winId: "0x6", appId: "unknown-app", title: "", workspace: 3,
                   focused: false, x: 0, y: 0, width: 0, height: 0, monitorWidth: 0, monitorHeight: 0 });
        t.append({ winId: "0x7", appId: "firefox", title: "Kigali weather — Mozilla Firefox", workspace: 1,
                   focused: false, x: 260, y: 420, width: 900, height: 560, monitorWidth: 1920, monitorHeight: 1080 });
    }

    function others() {
        const t = Services.wm.toplevels;
        t.append({ winId: "0x8", appId: "org.gnome.Nautilus", title: "Downloads", workspace: 5,
                   focused: false, x: 200, y: 120, width: 1000, height: 640, monitorWidth: 1920, monitorHeight: 1080 });
        t.append({ winId: "0x9", appId: "firefox", title: "Release notes — Lugh OS 0.3 — a very long page title that will not fit anywhere",
                   workspace: 7, focused: false, x: 0, y: 0, width: 1920, height: 1080, monitorWidth: 1920, monitorHeight: 1080 });
        t.append({ winId: "0xa", appId: "org.codeberg.dnkl.foot", title: "htop", workspace: 12,
                   focused: false, x: 0, y: 0, width: 0, height: 0, monitorWidth: 0, monitorHeight: 0 });
    }

    function openNow() {
        ShellState.openOverview();
        ov.forceActiveFocus();
        const sel = Number(arg("--select", 0));
        if (sel > 0) ov.selected = sel;
        const q = arg("--query", "");
        if (q !== "") ov.query = q;
    }

    Timer { id: start; interval: 1; onTriggered: demo.openNow() }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // The repo's art (the demo runs without lugh-branding installed).
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { blurred: true; _useRepo: true }
        onLoaded: Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { _useRepo: true }
    }

    Overview {
        id: ov
        anchors.fill: parent
        visible: shown
        focus: true
        previewArt: true
    }

    // ---- --motion ---------------------------------------------------------------
    property int _frame: 0
    property int _pending: 0
    Timer {     // let the wallpaper load, then go
        id: settle
        interval: 1800
        onTriggered: {
            if (demo.motion === "open") { demo.openNow(); grabber.start(); }
            else { demo.openNow(); later.start(); }
        }
    }
    Timer {
        id: later
        interval: 800
        onTriggered: { ShellState.closeAll(); grabber.start(); }
    }
    Timer {
        id: grabber
        interval: 33
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const n = demo._frame++;
            if (n >= 12) { stop(); if (demo._pending === 0) Qt.exit(0); return; }
            console.log("frame " + String(n).padStart(2, "0") + " reveal=" + ov.reveal.toFixed(2));
            demo._pending++;
            demo.grabToImage(r => {
                r.saveToFile(demo.outDir + "/" + demo.motion + "-" + String(n).padStart(2, "0") + ".png");
                if (--demo._pending === 0 && !grabber.running) Qt.exit(0);
            });
        }
    }
}
