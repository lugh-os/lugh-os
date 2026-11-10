// lugh-greeter entry point: one full-screen window under cage (greetd's
// greeter session). The Rust host (ui/greeter/src) sets the root context
// property `greetdBackend` to its backend object before loading this file;
// without it (development) the Greeter uses its own MockGreetd. See
// ../README.md for the backend contract.
//
//   qml6 -I ui/components ui/greeter/qml/main.qml        # mock, windowed
import QtQuick
import QtQuick.Window
import Lugh.UI

Window {
    id: window
    width: 1440
    height: 900
    visible: true
    // cage gives the only client the whole output; FullScreen makes the
    // intent explicit and also fills the screen when run elsewhere.
    visibility: Window.FullScreen
    color: Theme.bg
    title: qsTr("Lugh sign-in")

    Greeter {
        id: greeter
        anchors.fill: parent
        focus: true
        // `greetdBackend` is undefined unless the Rust host provides it.
        backend: typeof greetdBackend !== "undefined" && greetdBackend ? greetdBackend : _mock
    }

    // One line in the journal when the sign-in screen is on screen (the VM
    // test, scripts/test-desktop.sh, waits for it).
    property bool _marked: false
    onFrameSwapped: {
        if (_marked) return;
        _marked = true;
        console.info("LUGH-MARK: greeter-ready");
    }

    Component.onCompleted: {
        Theme.dark = false;     // light theme by default (shell spec §Greeter)
        greeter.forceActiveFocus();
    }
}
