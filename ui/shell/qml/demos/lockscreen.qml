// Lock screen demo: locks the mock session and shows LockScreen full size.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/lockscreen.qml \
//       /tmp/lugh-shots/lock/light.png 1440 900 [900 -- flags]
//
// Flags: --dark, --error (wrong-password state), --idle (clock only),
//        --busy (authenticating), --caps (Caps Lock warning), --reduce,
//        --typed (a few characters in the field). Run it with `qml` for a live
//        session: the password "lugh" unlocks (Ctrl+L locks again).
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    function has(flag) { return Qt.application.arguments.indexOf(flag) >= 0 }

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
        Theme.dark = has("--dark");
        Theme.reduceMotion = has("--reduce");
        Services.keyboard.capsLock = has("--caps");
        Services.session.lock();
        if (has("--error"))
            Services.session.authError = qsTr("Wrong password. Try again.");
        if (has("--busy")) {
            Services.session.authenticating = true;
        }
        if (has("--idle"))
            Qt.callLater(() => lock.idle = true);
        if (has("--typed"))
            Qt.callLater(() => { const f = demo._field(lock); if (f) f.insert(0, "sunrise"); });
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
}
