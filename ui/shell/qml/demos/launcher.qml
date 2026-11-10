// Launcher demo: the wallpaper with the launcher open over it.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/launcher.qml \
//       /tmp/lugh-shots/launcher/fi-light.png 1440 900 900 -- --query fi
//
// Args: --dark, --accent <name>, --reduce-motion, --query <text> (typed into
// the field after opening, as ShowLauncher(query) would).
// Glass: the compositor blurs behind the panel; here the pre-blurred
// wallpaper is drawn under the panel instead (as preview.qml does for the
// bar and dock).
import QtQuick
import Lugh.UI
import Lugh.Shell
import "../preview"

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }

    property bool configured: false
    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion");
        configured = true;
        ShellState.openLauncher();
        const q = arg("--query", "");
        if (q !== "") Qt.callLater(() => { launcher.query = q; });
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // The repo's art (the demo runs without lugh-branding installed).
    Loader {
        id: blurredWall
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { blurred: true; _useRepo: true }
    }
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { _useRepo: true }
    }

    // Simulated compositor blur under the launcher panel.
    GlassBackdrop {
        readonly property Item p: launcher.panelItem
        readonly property point pos: {
            p.parent.x; p.parent.y; p.width; p.height;
            return p.mapToItem(demo, 0, 0);
        }
        visible: launcher.shown && blurredWall.item !== null
        opacity: p.parent.parent.opacity
        source: blurredWall
        radius: Theme.radiusXl
        x: pos.x; y: pos.y
        width: p.width; height: p.height
    }

    Launcher {
        id: launcher
        anchors.fill: parent
        visible: shown
        focus: true
    }
}
