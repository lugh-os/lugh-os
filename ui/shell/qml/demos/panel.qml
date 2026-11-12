// Panel demo (1440×900): the wallpaper with the bottom Panel where the frame
// puts it, optionally with the Lugh menu.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/panel.qml \
//       /tmp/lugh-shots/panel/light.png 1440 900 900 [-- flags]
//   --dark, --accent <name>, --reduce-motion
//   --strip              edge-to-edge strip instead of the floating pill
//   --left               apps aligned left
//   --magnify-at <x>     magnify on, pointer resting at x (window coords)
//   --autohide           auto-hide (hidden while a window overlaps: --overlapped)
//   --hover <index>      hover label on a tile (app count = Trash)
//   --menu <index>       context menu open on a tile (--confirm: the Trash
//                        menu's "Empty Trash?" step)
//   --panel-menu         the panel's own right-click menu
//   --toast              the launch-failure toast
//   --osd [kind]         an OSD request in the tray (volume, brightness, caps …)
//   --lugh-menu          open the Lugh menu (grows up from the start button)
//   --focus <name>       keyboard focus on start | search | workspaces | tray
//   --keyboard           keyboard mode, as Super+B (ShellState.focusPanel())
//   --many [n=20]        n apps (the list shrinks, then scrolls)
//   --states a           Wi-Fi off, muted, charging, do not disturb, workspace 3
// Panel settings (height, icon size, search, tray icons…) come from
// ShellSettings (the user's lugh-shell.conf); the demo does not write them.
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
        // The last one wins: the qml-shot harness has its own args before ours.
        const i = args.lastIndexOf(name);
        return i >= 0 && i + 1 < args.length && !args[i + 1].startsWith("--") ? args[i + 1] : fallback;
    }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        const kids = item.children;
        for (let i = 0; i < kids.length; ++i) {
            const hit = find(kids[i], name);
            if (hit) return hit;
        }
        return null;
    }
    readonly property string wallDir: arg("--wallpaper-dir", Qt.resolvedUrl("../../../../branding/wallpapers/").toString())
    function wall(kind) { return wallDir + "dawn-" + (Theme.dark ? "dark" : "light") + "-" + kind + ".jpg"; }
    property bool ready: false

    Component.onCompleted: {
        Theme.dark = has("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = has("--reduce") || has("--reduce-motion");
        const d = Services.apps.dock;
        if (has("--many")) {
            const inst = Services.apps.installed, n = Number(arg("--many", 20));
            for (let i = 0; d.count < n; ++i) {
                const a = inst.get(i % inst.count);
                d.append({ appId: a.appId + "-" + i, name: a.name + " " + (i + 1), icon: a.icon, pinned: false,
                           running: i % 3 === 0, windows: i % 3 === 0 ? 1 + i % 2 : 0, launching: false, attention: false });
            }
        }
        if (arg("--states", "") === "a") {
            Services.network.wifiEnabled = false;
            Services.network.connected = false;
            Services.audio.muted = true;
            Services.power.charging = true;
            Services.notifications.dnd = true;
            Services.wm.activeWorkspace = 3;
            Services.media.playing = false;
        }
        if (has("--overlapped")) Services.wm.dockOverlapped = true;
        ready = true;
        afterLoad.start();
    }
    Timer {
        id: afterLoad
        interval: 120
        onTriggered: {
            if (demo.has("--toast"))
                panel.showLaunchError("lugh-store", "lugh-store.service: Main process exited, code=exited, status=127/n/a\n"
                                      + "lugh-store: error while loading shared libraries: libappstream.so.5: cannot open shared object file");
            if (demo.has("--osd")) Services.osd.show(demo.arg("--osd", "volume"), 0.62);
            if (demo.has("--panel-menu")) panel._openPanelMenu(panel._pillW * 0.3);
            if (demo.has("--lugh-menu")) ShellState.lughMenuOpen = true;
            if (demo.has("--keyboard")) ShellState.focusPanel();
            const f = demo.arg("--focus", "");
            if (f !== "") {
                const t = demo.find(panel, f);
                if (t) t.forceActiveFocus(Qt.TabFocusReason);
                else console.warn("demo: no focus target", f);
            }
        }
    }
    Timer {
        interval: 500
        running: demo.has("--confirm")
        onTriggered: panel._menu._run(1)
    }

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

    Panel {
        id: panel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
        screenHeight: demo.height
        floating: !demo.has("--strip")
        alignment: demo.has("--left") ? "left" : "center"
        magnify: demo.has("--magnify-at")
        autohide: demo.has("--autohide")
        _debugPointerX: Number(demo.arg("--magnify-at", -1))
        _debugHoverIndex: Number(demo.arg("--hover", -1))
        _debugMenuIndex: Number(demo.arg("--menu", -1))
    }

    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: LughMenu { visible: shown }
    }
}
