// OSD demo: wallpaper + the OSD pill at the bottom centre (96 px above the
// edge, as the frame anchors it), shown through Services.osd.show().
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/osd.qml \
//       /tmp/lugh-shots/osd/volume-light.png 1440 900 600 [-- flags]
//   --kind <k>        volume (default) | brightness | mic | caps | layout | airplane | mode
//   --value <0..1>    level, or 1 = on / 0 = off for toggles (default 0.62)
//   --muted           volume muted
//   --dark, --accent <name>, --reduce
//   --cycle           re-request every 600 ms through all kinds (manual check)
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
    readonly property string repo: Qt.resolvedUrl("../../../../")

    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce");
        Services.audio.muted = flag("--muted");
        Services.osd.show(arg("--kind", "volume"), Number(arg("--value", 0.62)));
    }

    // The repo's art directly: no lookup in /usr/share (warns when lugh-branding
    // isn't installed).
    Wallpaper {
        anchors.fill: parent
        source: demo.repo + "branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-2560x1600.jpg"
    }

    Osd {
        anchors { bottom: parent.bottom; bottomMargin: 96; horizontalCenter: parent.horizontalCenter }
        visible: shown
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
