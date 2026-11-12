// OSD demo: there is no OSD surface in Lugh mode; the Panel's tray is the
// OSD. This shows the panel (demos/panel.qml) with one OSD request up.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/osd.qml \
//       /tmp/lugh-shots/osd/volume-light.png 1440 900 600 [-- flags]
//   --kind <k>        volume (default) | brightness | mic | caps | layout | airplane | mode
//   --value <0..1>    level, or 1 = on / 0 = off for toggles (default 0.62)
//   --muted           volume muted
//   --cycle           re-request every 600 ms through all kinds (manual check)
//   plus every flag of demos/panel.qml (--dark, --accent <name>, --reduce-motion, …)
// The request times out after 1.2 s: keep the shot delay under that.
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function flag(n) { return args.indexOf(n) >= 0 }
    function arg(n, d) { const i = args.indexOf(n); return i >= 0 && i + 1 < args.length ? args[i + 1] : d }

    Loader {
        anchors.fill: parent
        source: "panel.qml"
        onLoaded: {
            Services.audio.muted = demo.flag("--muted");
            Services.osd.show(demo.arg("--kind", "volume"), Number(demo.arg("--value", 0.62)));
        }
    }

    Timer {
        readonly property var steps: [["volume", 0.3], ["volume", 0.8], ["brightness", 0.4], ["mic", 0],
                                      ["caps", 1], ["layout", 0], ["airplane", 1], ["mode", 0]]
        property int i: 0
        interval: 600
        repeat: true
        running: demo.flag("--cycle")
        onTriggered: { const s = steps[i++ % steps.length]; Services.osd.show(s[0], s[1]); }
    }
}
