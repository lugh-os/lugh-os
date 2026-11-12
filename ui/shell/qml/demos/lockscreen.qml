// Lock screen demo: locks the mock session and shows LockScreen full size.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/lockscreen.qml \
//       /tmp/lugh-shots/lock/light.png 1440 900 [900 -- flags]
//
// Flags: --dark, --error (wrong-password state), --long-error (a long error
//        text), --idle (clock only), --busy (authenticating), --caps (Caps
//        Lock warning), --reduce, --typed (a few characters in the field),
//        --bare (no battery, one layout, no media, no sleep, long name).
// Motion capture: --motion <error-shake|unlock|lock|message> --frames <dir>
//        saves a scene grab every 33 ms to <dir>/<kind>-NN.png, then quits
//        (give qml-shot a delay longer than the capture, e.g. 4000).
// Run it with `qml` for a live session: the password "lugh" unlocks (Ctrl+L
// locks again).
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function has(flag) { return args.indexOf(flag) >= 0 }
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    readonly property string motion: arg("--motion", "")
    readonly property string frames: arg("--frames", "/tmp/lugh-shots/lock/motion")

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        Text {
            anchors.centerIn: parent
            text: "Unlocked. Ctrl+L locks again."
            font: Theme.typeTitle3
            color: Theme.textMuted
        }
    }

    LockScreen {
        id: lock
        anchors.fill: parent
        visible: shown
    }

    Shortcut { sequence: "Ctrl+L"; onActivated: Services.session.lock() }

    Component.onCompleted: {
        // The repo's art (the demo runs without lugh-branding installed).
        Services.appearance.wallpaperDir = Qt.resolvedUrl("../../../../branding/wallpapers/");
        Theme.dark = has("--dark");
        Theme.reduceMotion = has("--reduce");
        Services.keyboard.capsLock = has("--caps");
        if (has("--bare")) {
            Services.power.hasBattery = false;
            Services.keyboard.layouts = ["us"];
            Services.media.hasPlayer = false;
            Services.session.canSuspend = false;
            Services.notifications.history.clear();
            Services.session.realName = "Dr. Marie-Chantal Uwamahoro-Niyonsenga de la Fontaine-Mukandayisenga";
        }
        if (motion !== "lock") Services.session.lock();
        if (has("--error"))
            Services.session.authError = qsTr("Wrong password. Try again.");
        if (has("--long-error"))
            Services.session.authError = "Too many attempts. Try again in 8 s. If you forgot your password, an administrator of this computer can reset it from another account.";
        if (has("--busy")) {
            Services.session.authenticating = true;
        }
        if (has("--idle"))
            Qt.callLater(() => lock.idle = true);
        if (has("--typed"))
            Qt.callLater(() => { const f = demo._field(lock); if (f) f.insert(0, "sunrise"); });
        if (motion !== "") capture.start();
    }

    // Finds the password field for the --typed preview.
    function _field(item) {
        if (item && item.password === true) return item;
        for (let i = 0; item && i < item.children.length; ++i) {
            const f = _field(item.children[i]);
            if (f) return f;
        }
        return null;
    }

    // ---- motion capture --------------------------------------------------------
    Timer {
        id: capture
        property int n: 0
        interval: 33
        repeat: true
        onTriggered: {
            if (n === 2) {
                if (demo.motion === "error-shake") Services.session.authError = "Wrong password. Try again.";
                else if (demo.motion === "unlock") Services.session.locked = false;
                else if (demo.motion === "lock") Services.session.lock();
                else if (demo.motion === "message") Services.keyboard.capsLock = true;
            }
            const k = n++;
            demo.grabToImage(r => {
                r.saveToFile(demo.frames + "/" + demo.motion + "-" + String(k).padStart(2, "0") + ".png");
                if (k >= 23) Qt.quit();
            });
            if (n > 23) stop();
        }
    }
}
