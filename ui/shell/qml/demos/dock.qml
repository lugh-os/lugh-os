// Dock demo (1440×900): the wallpaper with three docks stacked so one frame
// shows every state the dock has.
//   top     hovered tile (tooltip + lift), attention dot, launch-failure toast
//   middle  context menu open on Firefox (two windows: two dots + window list)
//   bottom  the dock at rest, where the frame puts it
//
//   scripts/qml-shot.sh ui/shell/qml/demos/dock.qml /tmp/lugh-shots/dock/light.png 1440 900 [900 -- --dark]
// Args: --dark, --accent <name>, --reduce, --magnify, --autohide,
//       --single (only the bottom dock, no forced states),
//       --focus (keyboard focus on the bottom dock's third tile).
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
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    readonly property bool single: has("--single")

    Component.onCompleted: {
        Theme.dark = has("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = has("--reduce");
        if (has("--focus")) focusTimer.start();
        if (single) return;
        // A second Firefox window, Terminal asking for attention.
        Services.wm.toplevels.append({ winId: "0x9", appId: "firefox", title: "Kigali Heights — rent and utilities 2026 — Google Sheets — Mozilla Firefox",
                                       workspace: 1, focused: false });
        Services.apps._syncRunning();
        const d = Services.apps.dock;
        for (let i = 0; i < d.count; ++i)
            if (d.get(i).appId === "org.codeberg.dnkl.foot") d.setProperty(i, "attention", true);
        top.showLaunchError("lugh-store", "lugh-store.service: Main process exited, code=exited, status=127/n/a\n"
                            + "lugh-store: error while loading shared libraries: libappstream.so.5: cannot open shared object file");
    }

    Timer { id: focusTimer; interval: 150; onTriggered: bottom._focusAt(2) }

    Loader {
        anchors.fill: parent
        source: Qt.resolvedUrl("../Lugh/Shell/wallpaper/Wallpaper.qml")
        onStatusChanged: if (status === Loader.Error) sourceComponent = plain
    }
    Component { id: plain; Rectangle { color: Theme.bg } }

    Dock {
        id: top
        visible: !demo.single
        anchors.left: parent.left
        anchors.right: parent.right
        y: 300 - height
        height: implicitHeight
        magnify: demo.has("--magnify")
        _debugHoverIndex: 2
        _debugPointerX: magnify ? demo.width / 2 - 60 : -1
    }

    Dock {
        id: middle
        visible: !demo.single
        anchors.left: parent.left
        anchors.right: parent.right
        y: 600 - height
        height: implicitHeight
        _debugMenuIndex: demo.single ? -1 : 0
    }

    Dock {
        id: bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
        magnify: demo.has("--magnify")
        autohide: demo.has("--autohide")
    }
}
