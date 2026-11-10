// Control center demo (1440×900): wallpaper + the open ControlCenter.
//
//   scripts/qml-shot.sh ui/shell/qml/demos/controlcenter.qml /tmp/cc.png 1440 900 -- --page wifi --dark
//
// Args: --dark, --accent <name>, --reduce, --page <main|wifi|bluetooth|sound>,
//       --wifi-error (failed password attempt on MTN-Fiber-2F), --scanning,
//       --wifi-off, --no-networks, --bt-off, --profiles (power modes open),
//       --focus (keyboard focus on the first control of the page).
import QtQuick
import Lugh.UI
import Lugh.Shell
import "../preview"

Item {
    id: demo

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }

    property bool ready: false
    // GlassPanel draws the blurred backdrop itself when Theme has the preview
    // hook (Theme.backdrop); otherwise the demo draws it under the panel.
    readonly property bool frameBackdrop: !("backdrop" in Theme)
    // Without lugh-branding installed, use the repo's art (--wallpaper-dir as in preview.qml).
    readonly property string wallDir: arg("--wallpaper-dir", Qt.resolvedUrl("../../../../branding/wallpapers/").toString())
    function wall(kind) { return wallDir + "dawn-" + (Theme.dark ? "dark" : "light") + "-" + kind + ".jpg"; }

    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce");
        const net = Services.network;
        if (flag("--wifi-off")) net.setWifiEnabled(false);
        if (flag("--no-networks")) { net.disconnect(); net.networks.clear(); }
        if (flag("--scanning")) net.scanning = true;
        if (flag("--bt-off")) Services.bluetooth.setEnabled(false);
        ShellState.controlCenterOpen = true;
        ready = true;
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // Pre-blurred wallpaper: the source of the simulated compositor blur.
    Loader {
        id: blurred
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { blurred: true; source: demo.wall("blur") }
        onLoaded: if (!demo.frameBackdrop) Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { source: demo.wall("2560x1600") }
    }

    // What Hyprland's blur would show behind the glass panel.
    GlassBackdrop {
        visible: demo.frameBackdrop && cc.item !== null && blurred.item !== null
        source: blurred.item
        x: cc.item ? cc.item.panelRect.x : 0
        y: cc.item ? cc.item.panelRect.y : 0
        width: cc.item ? cc.item.panelRect.width : 0
        height: cc.item ? cc.item.panelRect.height : 0
        radius: Theme.radiusXl
        opacity: cc.item ? cc.item.panel.opacity : 0
        sourcePos: Qt.point(x, y)
    }

    Loader {
        id: cc
        anchors.fill: parent
        active: demo.ready
        focus: true
        sourceComponent: ControlCenter {}
        onLoaded: {
            const page = demo.arg("--page", "main");
            if (demo.flag("--wifi-error")) {
                item.wifiAttemptSsid = "MTN-Fiber-2F";
                item.wifiExpandedSsid = "MTN-Fiber-2F";
                Services.network.lastError = qsTr("Couldn't connect to %1. Wrong password?").arg("MTN-Fiber-2F");
            }
            if (demo.flag("--profiles")) item.showPowerModes();
            if (page !== "main") item.openPage(page, demo.flag("--focus"));
            else if (demo.flag("--focus")) item.focusFirst();
        }
    }
}
