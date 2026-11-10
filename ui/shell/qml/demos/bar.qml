// Demo: the top bar and the Lugh menu over the wallpaper.
//   scripts/qml-shot.sh ui/shell/qml/demos/bar.qml /tmp/lugh-shots/bar/light.png 1440 900
//   ... -- --dark            dark theme
//   ... -- --accent teal     another accent
//   ... -- --alt             other states: Wi-Fi off, muted, charging, DND,
//                            three layouts, workspace 3, long app name
//   ... -- --low             low battery, weak Wi-Fi, low volume
//   ... -- --focus clock     keyboard focus ring on logo|workspace-2|layout|cluster|bell|clock
//   ... -- --confirm         the Shut down confirmation instead of the menu
//   ... -- --reduce          reduce motion
// Top half: the bar alone. Bottom half: the bar with the Lugh menu open.
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    width: 1440
    height: 900

    readonly property var args: Qt.application.arguments
    function has(flag) { return args.indexOf(flag) >= 0 }
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (let i = 0; i < item.children.length; ++i) {
            const hit = find(item.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    Component.onCompleted: {
        Theme.dark = has("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = has("--reduce");
        if (has("--alt")) {
            Services.network.wifiEnabled = false;
            Services.network.connected = false;
            Services.audio.muted = true;
            Services.power.charging = true;
            Services.notifications.dnd = true;
            Services.keyboard.layouts = ["us", "fr", "rw"];
            Services.keyboard.current = "fr";
            Services.wm.activeWorkspace = 3;
            Services.wm.focusedAppName = "LibreOffice Calc — Rwanda trip budget (quarterly forecast, revised)";
        }
        if (has("--low")) {
            Services.network.strength = 22;
            Services.audio.volume = 0.2;
            Services.power.batteryPercent = 8;
            Services.notifications.clearAll();
            Services.keyboard.layouts = ["us"];
        }
        if (has("--confirm"))
            menu.pendingConfirm = "shutdown";
        else
            ShellState.lughMenuOpen = true;
        const f = arg("--focus", "");
        if (f !== "") {
            const target = find(topBar, f);
            if (target) target.forceActiveFocus(Qt.TabFocusReason);
            else console.warn("demo: no focus target", f);
        }
    }

    component Backdrop: Item {
        clip: true
        Loader {
            id: wp
            anchors.fill: parent
            source: Qt.resolvedUrl("../Lugh/Shell/wallpaper/Wallpaper.qml")
        }
        Rectangle {
            anchors.fill: parent
            visible: wp.status === Loader.Error
            color: Theme.bg
        }
    }

    Column {
        anchors.fill: parent

        Backdrop {
            width: parent.width
            height: parent.height / 2
            Bar {
                id: topBar
                width: parent.width
            }
        }

        Backdrop {
            width: parent.width
            height: parent.height / 2
            Bar {
                width: parent.width
            }
            LughMenu {
                id: menu
                anchors.fill: parent
            }
        }
    }

    // Seam between the two halves.
    Rectangle {
        y: parent.height / 2
        width: parent.width
        height: 1
        color: Theme.border
    }
}
