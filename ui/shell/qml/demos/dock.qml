// Dock demo (1440×900): the wallpaper with three docks stacked so one frame
// shows every state the dock has.
//   top     hovered tile (magnify + label), attention ring, launch-failure toast
//   middle  context menu open on Firefox (two windows: two embers + window list)
//   bottom  the dock at rest, where the frame puts it
//
//   scripts/qml-shot.sh ui/shell/qml/demos/dock.qml /tmp/lugh-shots/dock/light.png 1440 900 [900 -- --dark]
// Args: --dark, --accent <name>, --reduce-motion (or --reduce), --no-magnify,
//       --icon-size <px>, --autohide,
//       --single          only the bottom dock; the flags below then drive it
//       --magnify-at <x>  pointer resting at x (window coords)
//       --hover <index>   hover label on a tile (dock count = Trash)
//       --menu <index>    context menu open on a tile (--confirm: the Trash
//                         menu's "Empty Trash?" step)
//       --toast           the launch-failure toast
//       --focus           keyboard focus on the third tile
//       --many [n=20]     n apps in the dock; --apps <n>: only the first n
//       --broken          icons that do not resolve and very long names
//       --motion <magnify-sweep|launch|add-app|menu|autohide> --out <dir>
//                         saves a frame every ~33 ms into <dir>/f###.png and
//                         quits (use a long qml-shot delay); assemble with
//                         `montage <dir>/f*.png -tile 8x -geometry +2+2 sheet.png`
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function has(flag) { return args.indexOf(flag) >= 0; }
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length && !args[i + 1].startsWith("--") ? args[i + 1] : fallback;
    }
    readonly property string motion: arg("--motion", "")
    readonly property bool single: has("--single") || motion !== ""
    readonly property bool magnifyOn: !has("--no-magnify")
    readonly property int iconSize: Number(arg("--icon-size", 48))
    readonly property string wallDir: arg("--wallpaper-dir", Qt.resolvedUrl("../../../../branding/wallpapers/").toString())
    function wall(kind) { return wallDir + "dawn-" + (Theme.dark ? "dark" : "light") + "-" + kind + ".jpg"; }
    property bool ready: false

    Component.onCompleted: {
        Theme.dark = has("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = has("--reduce") || has("--reduce-motion");
        const d = Services.apps.dock;
        if (has("--apps")) while (d.count > Number(arg("--apps", 1))) d.remove(d.count - 1);
        if (has("--many")) {
            const inst = Services.apps.installed, n = Number(arg("--many", 20));
            for (let i = 0; d.count < n; ++i) {
                const a = inst.get(i % inst.count);
                d.append({ appId: a.appId + "-" + i, name: a.name + " " + (i + 1), icon: a.icon, pinned: false,
                           running: i % 3 === 0, windows: i % 3 === 0 ? 1 + i % 2 : 0, launching: false, attention: false });
            }
        }
        if (has("--broken")) {
            d.setProperty(1, "icon", "no-such-icon-anywhere");
            d.setProperty(1, "name", "Kigali Heights Property Management and Tenant Accounting Suite 2026 (Community Edition)");
            d.setProperty(3, "icon", "");
            Services.wm.toplevels.setProperty(0, "title", "Kigali Heights — rent and utilities 2026 — quarterly reconciliation — Google Sheets — Mozilla Firefox");
        }
        ready = true;
        if (has("--focus")) focusTimer.start();
        if (single) {
            if (has("--toast")) failToast(bottom);
            if (motion !== "") motionStart.start();
            return;
        }
        // A second Firefox window, Terminal asking for attention.
        Services.wm.toplevels.append({ winId: "0x9", appId: "firefox", title: "Kigali Heights — rent and utilities 2026 — Google Sheets — Mozilla Firefox",
                                       workspace: 1, focused: false });
        Services.apps._syncRunning();
        for (let i = 0; i < d.count; ++i)
            if (d.get(i).appId === "org.codeberg.dnkl.foot") d.setProperty(i, "attention", true);
        failToast(top);
    }
    function failToast(dock) {
        dock.showLaunchError("lugh-store", "lugh-store.service: Main process exited, code=exited, status=127/n/a\n"
                             + "lugh-store: error while loading shared libraries: libappstream.so.5: cannot open shared object file");
    }

    Timer { id: focusTimer; interval: 150; onTriggered: bottom._focusAt(2) }

    Rectangle { anchors.fill: parent; color: Theme.bg }
    // Pre-blurred wallpaper: the source of the simulated compositor blur.
    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { blurred: true; source: demo.wall("blur") }
        onLoaded: Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { source: demo.wall("2560x1600") }
    }

    Dock {
        id: top
        visible: !demo.single
        anchors.left: parent.left
        anchors.right: parent.right
        y: 300 - height
        height: implicitHeight
        magnify: demo.magnifyOn
        iconSize: demo.iconSize
        _debugHoverIndex: demo.single ? -1 : 2
        _debugPointerX: demo.single ? -1 : demo.width / 2 - 75
    }

    Dock {
        id: middle
        visible: !demo.single
        anchors.left: parent.left
        anchors.right: parent.right
        y: 600 - height
        height: implicitHeight
        magnify: demo.magnifyOn
        iconSize: demo.iconSize
        _debugMenuIndex: demo.single ? -1 : 0
    }

    Dock {
        id: bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
        magnify: demo.magnifyOn
        iconSize: demo.iconSize
        autohide: demo.has("--autohide")
        _debugPointerX: demo.single ? (demo.sweeping ? demo.sweepX : Number(demo.arg("--magnify-at", -1))) : -1
        _debugHoverIndex: demo.single ? Number(demo.arg("--hover", -1)) : -1
        _debugMenuIndex: demo.single ? Number(demo.arg("--menu", -1)) : -1
    }
    Timer {
        interval: 500
        running: demo.single && demo.has("--confirm")
        onTriggered: bottom._menu._run(1)
    }

    // ---- motion capture -----------------------------------------------------
    property bool sweeping: false
    property real sweepX: -1
    property int frame: 0
    property int frames: 0
    readonly property string outDir: arg("--out", "/tmp/lugh-shots/dock/motion")
    readonly property real pillLeft: (width - bottom._baseWTarget) / 2
    NumberAnimation {
        id: sweep
        target: demo; property: "sweepX"
        from: demo.pillLeft + 4; to: demo.pillLeft + bottom._baseWTarget - 4
        duration: 1300
        onFinished: demo.sweeping = false
    }
    Timer {
        id: motionStart
        interval: 700
        onTriggered: {
            const m = demo.motion;
            if (m === "magnify-sweep") { demo.frames = 64; demo.sweepX = sweep.from; demo.sweeping = true; sweep.start(); }
            else if (m === "launch") { demo.frames = 48; Services.apps.launch("lugh-files"); }
            else if (m === "add-app") { demo.frames = 72; Services.apps.launch("qalculate-qt"); quitTimer.start(); }
            else if (m === "menu") { demo.frames = 40; bottom._openMenu(0); closeTimer.start(); }
            else if (m === "autohide") { demo.frames = 56; bottom.autohide = true; Services.wm.dockOverlapped = true; showTimer.start(); }
            grabber.start();
        }
    }
    Timer { id: quitTimer; interval: 1500; onTriggered: Services.apps.quit("qalculate-qt") }
    Timer { id: closeTimer; interval: 800; onTriggered: bottom._menu.close() }
    Timer { id: showTimer; interval: 900; onTriggered: Services.wm.dockOverlapped = false }
    Timer {
        id: grabber
        interval: 33
        repeat: true
        onTriggered: {
            const i = demo.frame++;
            if (i >= demo.frames) { stop(); doneTimer.start(); return; }
            demo.grabToImage(r => r.saveToFile(demo.outDir + "/f" + String(i).padStart(3, "0") + ".png"));
        }
    }
    Timer { id: doneTimer; interval: 400; onTriggered: Qt.exit(0) }
}
