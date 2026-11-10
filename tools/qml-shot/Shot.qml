// Screenshot harness: loads one QML file into a window and saves a PNG.
//   scripts/qml-shot.sh <file.qml> <out.png> [width] [height] [delay-ms]
// The loaded root may be an Item (filled to the window) or a Window-less
// component. Extra args after the size are passed through as
// Qt.application.arguments for the loaded file to read (e.g. --dark).
import QtQuick
import QtQuick.Window

Window {
    id: win
    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    width: Number(arg("--width", 1440))
    height: Number(arg("--height", 900))
    visible: true
    color: "#808080"
    title: "lugh-qml-shot"

    Loader {
        id: loader
        anchors.fill: parent
        source: win.arg("--file", "")
        onStatusChanged: if (status === Loader.Error) { console.error("qml-shot: failed to load", source); Qt.exit(2); }
    }
    Timer {
        interval: Number(win.arg("--delay", 900))
        running: loader.status === Loader.Ready
        onTriggered: win.contentItem.grabToImage(r => {
            if (!r.saveToFile(win.arg("--out", "/tmp/lugh-shot.png"))) Qt.exit(3);
            Qt.exit(0);
        })
    }
}
