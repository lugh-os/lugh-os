// Control center demo (1440×900): wallpaper, a status island, and the control
// center growing out of it.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/controlcenter.qml \
//       /tmp/lugh-shots/cc/wifi-dark.png 1440 900 1500 -- --page wifi --dark
//
// Args:
//   --dark, --accent <name>, --reduce-motion
//   --page <main|wifi|bluetooth|sound|power|session>
//                      opened as ShellState.openControlCenter(page) would
//   --states <full|minimal|stress>
//                      minimal: no Bluetooth, battery, backlight, media, night
//                      light, power profiles; one keyboard layout.
//                      stress: 40 networks, long names, 6 outputs, 5 app streams.
//   --wifi-error       failed password attempt on MTN-Fiber-2F
//   --wifi-off, --no-networks, --scanning, --bt-off, --confirm <logout|restart|shutdown>
//   --focus            keyboard focus (ring) on the first control
//   --motion <open|drawer|toggle|close> --out <dir>
//                      grab the scene every ~33 ms into <dir>/<motion>-NN.png
//                      and log the panel geometry per frame, then quit (pass a
//                      long qml-shot delay, e.g. 20000). `drawer` opens --page
//                      (default wifi) in the open panel; `toggle` switches
//                      Do Not Disturb.
// Glass: the compositor blurs behind the panel; here GlassPanel draws the
// pre-blurred wallpaper under itself (Theme.backdrop, GPU renderers only).
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
    readonly property string outDir: arg("--out", "/tmp/lugh-shots/cc/motion")
    readonly property string page: arg("--page", "main")
    readonly property string states: arg("--states", "full")

    property bool configured: false
    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion");
        if (states === "minimal") minimal();
        else if (states === "stress") stress();
        const net = Services.network;
        if (flag("--wifi-off")) net.setWifiEnabled(false);
        if (flag("--no-networks")) { net.disconnect(); net.networks.clear(); }
        if (flag("--scanning")) net.scanning = true;
        if (flag("--bt-off")) Services.bluetooth.setEnabled(false);
        configured = true;
        if (motion === "") start.start();
        else settle.start();
    }

    function minimal() {
        Services.bluetooth.available = false;
        Services.power.hasBattery = false;
        Services.power.profiles = [];
        Services.display.brightnessAvailable = false;
        Services.display.nightLightAvailable = false;
        Services.media.hasPlayer = false;
        Services.keyboard.layouts = ["us"];
        Services.audio.streams.clear();
        Services.audio.inputs.remove(1);
    }
    function stress() {
        const net = Services.network, a = Services.audio, bt = Services.bluetooth;
        net.networks.setProperty(0, "ssid", "Kigali Heights Residences — Block C, 5th floor (5 GHz, guests welcome)");
        net.ssid = net.networks.get(0).ssid;
        for (let i = 0; i < 36; ++i)
            net.networks.append({ ssid: i % 5 === 0 ? "DIRECT-" + i + "-HP OfficeJet Pro 9010 series with a very long name"
                                                    : "Neighbour " + (i + 1),
                                  strength: Math.max(2, 70 - i * 2), secure: i % 3 !== 0, known: false, connected: false });
        bt.devices.setProperty(0, "name", "Keza's Sony WH-1000XM5 over-ear noise cancelling headphones");
        for (let i = 0; i < 6; ++i)
            bt.devices.append({ address: "AC:12:2F:00:22:0" + i, name: "Device " + (i + 1), icon: i % 2 ? "mouse" : "",
                                paired: true, connected: false, battery: -1, busy: i === 1 });
        a.outputs.append({ devId: "hdmi.2", name: "HDMI — Dell U2723QE (DisplayPort 1.4, audio channel 2)", icon: "monitor", active: false });
        a.outputs.append({ devId: "usb.dac", name: "USB DAC", icon: "speaker", active: false });
        a.outputs.append({ devId: "bluez.spk", name: "Living room speaker", icon: "speaker", active: false });
        a.inputs.append({ devId: "usb.mic", name: "Blue Yeti USB condenser microphone", icon: "mic", active: false });
        a.streams.append({ streamId: 60, name: "Spotify", icon: "spotify", volume: 0.5, muted: true });
        a.streams.append({ streamId: 61, name: "Chromium Web Browser (video call)", icon: "chromium", volume: 0.3, muted: false });
        a.streams.append({ streamId: 62, name: "", icon: "", volume: 0.9, muted: false });
        Services.media.title = "Symphony No. 9 in D minor, Op. 125 “Choral”: IV. Presto — Allegro assai";
        Services.media.artist = "Berliner Philharmoniker, Herbert von Karajan";
        Services.power.timeRemaining = "12 h 40 min until fully charged";
        Services.keyboard.layouts = ["us", "fr", "de"];
    }

    function openNow() {
        if (flag("--wifi-error")) {
            cc.wifiAttemptSsid = "MTN-Fiber-2F";
            Services.network.lastError = qsTr("Couldn't connect to %1. Wrong password?").arg("MTN-Fiber-2F");
        }
        if (motion === "drawer" || page === "main") ShellState.toggleControlCenter();
        else if (page === "session") { ShellState.toggleControlCenter(); cc.openPage("session", false); }
        else ShellState.openControlCenter(page);
        cc.forceActiveFocus();
        if (arg("--confirm", "") !== "") { cc.openPage("session", false); cc.sessionConfirm = arg("--confirm", ""); }
        if (flag("--focus")) cc.focusFirst();
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

    // The status island the panel grows out of.
    Island {
        id: island
        anchors.right: parent.right
        anchors.rightMargin: Theme.islandSideMargin
        y: Theme.islandMargin
        height: Theme.islandHeight
        active: ShellState.controlCenterOpen
        text: qsTr("Status")
        onClicked: ShellState.toggleControlCenter()

        Icon { anchors.verticalCenter: parent.verticalCenter; name: "wifi"; size: 16 }
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "volume-1"; size: 16 }
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "battery-medium"; size: 16 }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "64%"
            font: Theme.typeLabelTnum
            color: Theme.text
        }
    }
    Binding { target: ShellState; property: "statusIsland"; value: island.sceneRect }

    ControlCenter {
        id: cc
        anchors.fill: parent
        visible: shown
        focus: true
    }

    // ---- --motion ---------------------------------------------------------------
    property int _frame: 0
    property int _pending: 0
    property double _t0: 0
    readonly property int _frames: motion === "toggle" || motion === "close" ? 14 : 22
    Timer {     // let the wallpaper load, then go
        id: settle
        interval: 1800
        onTriggered: {
            if (demo.motion === "open") { demo._t0 = Date.now(); demo.openNow(); grabber.start(); }
            else { demo.openNow(); later.start(); }
        }
    }
    Timer {
        id: later
        interval: 1000
        onTriggered: {
            demo._t0 = Date.now();
            if (demo.motion === "drawer") cc.openPage(demo.page === "main" ? "wifi" : demo.page, false);
            else if (demo.motion === "toggle") Services.notifications.setDnd(!Services.notifications.dnd);
            else if (demo.motion === "close") ShellState.closeAll();
            grabber.start();
        }
    }
    Timer {
        id: grabber
        interval: 33
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const n = demo._frame++;
            const p = cc.panelItem;
            console.log("frame " + String(n).padStart(2, "0") + " t=" + (Date.now() - demo._t0) + "ms panel x=" + p.x.toFixed(1)
                        + " y=" + p.y.toFixed(1) + " w=" + p.width.toFixed(1) + " h=" + p.height.toFixed(1)
                        + " r=" + p.radius.toFixed(1) + " op=" + p.opacity.toFixed(2) + " shown=" + cc.shown
                        + " target.h=" + cc.panelRect.height.toFixed(1));
            demo._pending++;
            demo.grabToImage(r => {
                r.saveToFile(demo.outDir + "/" + demo.motion + "-" + String(n).padStart(2, "0") + ".png");
                if (--demo._pending === 0 && !grabber.running) Qt.exit(0);
            });
            if (demo._frame >= demo._frames) stop();
        }
    }
}
