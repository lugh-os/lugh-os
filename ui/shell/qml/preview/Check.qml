// Load-check harness (scripts/qml-check.sh): loads one QML file (--file URL)
// or one Lugh.Shell type (--type Name) into a 1440×900 window, lets it run
// for --delay ms (default 600), then exits 0. --wallpaper-dir as in preview.qml. Exit 2 if it fails to load.
// The script fails the check on any warning printed meanwhile.
import QtQuick
import QtQuick.Window
import Lugh.Shell

Window {
    id: win
    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    width: 1440
    height: 900
    visible: true
    color: "#808080"
    title: "lugh-qml-check"

    Loader {
        id: loader
        anchors.fill: parent
        Component.onCompleted: {
            const wpDir = win.arg("--wallpaper-dir", "");
            if (wpDir !== "" && "wallpaperDir" in Services.appearance) Services.appearance.wallpaperDir = wpDir;
            const file = win.arg("--file", "");
            const type = win.arg("--type", "");
            if (file !== "") {
                source = file;
            } else {
                const c = Qt.createComponent(win.arg("--module", "Lugh.Shell"), type);
                if (c.status === Component.Error) {
                    console.error("qml-check:", type, c.errorString().trim());
                    Qt.exit(2);
                    return;
                }
                sourceComponent = c;
            }
        }
        onStatusChanged: if (status === Loader.Error) { console.error("qml-check: failed to load", source); Qt.exit(2); }
    }
    Timer {
        interval: Number(win.arg("--delay", 600))
        running: loader.status === Loader.Ready
        onTriggered: Qt.exit(0)
    }
}
