// Demo: the three top islands and the Lugh menu over the wallpaper.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/bar.qml \
//       /tmp/lugh-shots/bar/light.png 1440 900 900 [-- flags]
//   --dark, --accent <name>, --reduce-motion
//   --menu               open the Lugh menu
//   --confirm            the Shut down confirmation
//   --states [a|b]       alternative states:
//                          a: Wi-Fi off, muted, charging, do not disturb, long
//                             app name, workspace 3, media paused
//                          b: no battery, one layout, no focused app, nine
//                             workspaces, airplane mode, no player, no Bluetooth
//   --low                low battery (percent shown), weak Wi-Fi, connecting
//   --focus <name>       keyboard focus on logo | workspaces | centerIsland | statusIsland
//   --drop               play the first-show drop-in (off by default for stills)
//   --motion <name> --frames <dir>
//                        write a frame every ~33 ms to <dir>/f-NNN.png, then
//                        quit: osd | menu | workspace | drop
// Glass: Theme.backdrop is set to the pre-blurred wallpaper, which GlassPanel
// draws under its tint (what the compositor's blur does on Hyprland).
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function flag(name) { return args.indexOf(name) >= 0; }
    function arg(name, fallback) {
        const i = args.indexOf(name);
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

    readonly property string motion: arg("--motion", "")
    property bool configured: false

    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion");
        const s = flag("--states") ? arg("--states", "a") : "";
        if (s === "a") {
            Services.network.wifiEnabled = false;
            Services.network.connected = false;
            Services.audio.muted = true;
            Services.power.charging = true;
            Services.notifications.dnd = true;
            Services.keyboard.layouts = ["us", "fr"];
            Services.keyboard.current = "fr";
            Services.wm.activeWorkspace = 3;
            Services.wm.focusedAppName = "LibreOffice Calc — Rwanda trip budget (quarterly forecast, revised)";
            Services.media.playing = false;
        } else if (s === "b") {
            Services.power.hasBattery = false;
            Services.keyboard.layouts = ["us"];
            Services.wm.focusedAppName = "";
            for (let i = 5; i <= 9; ++i)
                Services.wm.workspaces.append({ wsId: i, name: String(i), occupied: i % 2 === 0 });
            Services.wm.activeWorkspace = 7;
            Services.network.airplaneMode = true;
            Services.media.hasPlayer = false;
            Services.bluetooth.available = false;
            Services.notifications.clearAll();
        }
        if (flag("--low")) {
            Services.network.strength = 22;
            Services.network.connectingSsid = "Kigali Heights 5G";
            Services.audio.volume = 0.2;
            Services.power.batteryPercent = 8;
        }
        configured = true;
        if (flag("--confirm"))
            menu.item.pendingConfirm = "shutdown";
        else if (flag("--menu"))
            ShellState.lughMenuOpen = true;
        const f = arg("--focus", "");
        if (f !== "") {
            const target = find(bar.item, f);
            if (target) target.forceActiveFocus(Qt.TabFocusReason);
            else console.warn("demo: no focus target", f);
        }
        if (motion !== "")
            settle.start();
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // The repo's art (the demo runs without lugh-branding installed). The
    // blurred copy is what glass shows behind itself.
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

    Loader {
        id: bar
        width: parent.width
        active: demo.configured
        sourceComponent: Bar { dropIn: demo.flag("--drop") || demo.motion === "drop" }
    }
    Loader {
        id: menu
        anchors.fill: parent
        active: demo.configured
        sourceComponent: LughMenu { visible: shown }
    }

    // ---- motion capture ----------------------------------------------------
    Timer {
        // Let the window map and the wallpaper decode first ("drop" records
        // from the very start instead).
        id: settle
        interval: demo.motion === "drop" ? 1 : 400
        onTriggered: { recorder.t0 = Date.now(); recorder.start(); }
    }
    Timer {
        id: recorder

        readonly property var scripts: ({
            osd: { end: 2300, steps: [
                [100, () => Services.osd.show("volume", 0.3)],
                [500, () => Services.osd.show("volume", 0.62)]] },
            menu: { end: 1300, steps: [
                [100, () => ShellState.toggleLughMenu()],
                [800, () => ShellState.closeAll()]] },
            workspace: { end: 1500, steps: [
                [100, () => Services.wm.switchWorkspace(3)],
                [700, () => { Services.wm.focusedAppName = "Files"; }],
                [1000, () => Services.wm.switchWorkspace(2)]] },
            drop: { end: 900, steps: [] }
        })
        readonly property var script: scripts[demo.motion] || { end: 0, steps: [] }
        readonly property string dir: demo.arg("--frames", "/tmp/lugh-shots/bar/motion")
        property double t0: 0
        property int frame: 0
        property int next: 0
        property int pending: 0
        property bool done: false

        interval: 33
        repeat: true
        onTriggered: {
            const t = Date.now() - t0;
            while (next < script.steps.length && script.steps[next][0] <= t)
                script.steps[next++][1]();
            if (t > script.end) {
                done = true;
                stop();
                if (pending === 0) Qt.exit(0);
                return;
            }
            const n = String(frame++).padStart(3, "0");
            const ok = demo.grabToImage(r => {
                r.saveToFile(dir + "/f-" + n + ".png");
                if (--recorder.pending === 0 && recorder.done) Qt.exit(0);
            });
            if (ok) ++pending;
        }
    }
}
