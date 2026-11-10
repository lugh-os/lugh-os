// Greeter demo: the Greeter with a MockGreetd shaped by flags.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/greeter/qml/GreeterDemo.qml \
//       /tmp/lugh-shots/greeter/light.png 1440 900 [900 -- flags]
//
// Flags: --dark, --error (wrong-password state), --busy (authenticating),
//        --caps (Caps Lock warning), --many (14 users → username capsule),
//        --hide (hide_users), --sessions (two sessions → session picker),
//        --prompt (a second prompt: one-time code), --info (PAM info line),
//        --slow (PAM takes 2 s), --reduce, --typed, --a11y (opens the
//        accessibility menu), --confirm (shut-down confirmation).
// Motion capture: --motion <error-shake|unlock|user-switch> --frames <dir>
//        saves a scene grab every 33 ms to <dir>/<kind>-NN.png, then quits
//        (give qml-shot a delay longer than the capture, e.g. 4000).
// Live: `qml6 -I ui/components ui/greeter/qml/GreeterDemo.qml`; password
// "lugh" (then "123456" with --prompt).
import QtQuick
import Lugh.UI

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
    readonly property string frames: arg("--frames", "/tmp/lugh-shots/greeter/motion")

    MockGreetd {
        id: mock
        capsLock: demo.has("--caps")
        hideUsers: demo.has("--hide")
        mockDelay: demo.has("--slow") ? 2000 : 700
        mockInfo: demo.has("--info") ? "Password expires in 3 days." : ""
        mockSecondPrompt: demo.has("--prompt") ? "One-time code:" : ""
        Component.onCompleted: {
            if (demo.has("--many")) {
                const names = ["Amara Nkusi", "Keza Uwase", "Jean-Paul Habimana", "Aline Mukamana", "Eric Niyonzima",
                               "Grace Ingabire", "Olivier Mugisha", "Diane Uwimana", "Patrick Habineza", "Sandrine Iradukunda",
                               "Yves Nshuti", "Claudine Umutoni", "Emmanuel Twagira", "Josiane Mutesi"];
                users = names.map(n => ({ userName: n.split(" ")[0].toLowerCase(), realName: n, avatar: "" }));
            }
            if (demo.has("--sessions"))
                sessions = sessions.concat([{ id: "hyprland", name: "Hyprland", comment: "Plain Hyprland", exec: "Hyprland" }]);
        }
    }

    Greeter {
        id: greeter
        anchors.fill: parent
        backend: mock
    }

    Component.onCompleted: {
        Theme.dark = has("--dark");
        Theme.reduceMotion = has("--reduce");
        if (has("--error")) mock.authFailed(qsTr("Wrong password. Try again."));
        if (has("--busy")) {
            mock.sessionUser = "amara";
            mock.authenticating = true;
        }
        if (has("--prompt") && motion === "") {
            // Straight to the second prompt.
            mock.sessionUser = "amara";
            mock.authenticating = true;
            mock.promptRequested(false, "One-time code:");
        }
        if (has("--typed")) Qt.callLater(() => greeter.typeText("sunrise"));
        if (has("--a11y") || has("--confirm")) Qt.callLater(demo._openPopup);
        if (motion !== "") capture.start();
    }

    // ---- motion capture --------------------------------------------------------
    Timer {
        id: capture
        property int n: 0
        interval: 33
        repeat: true
        onTriggered: {
            if (n === 2) {
                if (demo.motion === "error-shake") mock.authFailed("Wrong password. Try again.");
                else if (demo.motion === "unlock") mock.authSucceeded();
                else if (demo.motion === "user-switch") greeter.selectUser(greeter.currentIndex + 1);
            }
            const k = n++;
            demo.grabToImage(r => {
                r.saveToFile(demo.frames + "/" + demo.motion + "-" + String(k).padStart(2, "0") + ".png");
                if (k >= 23) Qt.quit();
            });
            if (n > 23) stop();
        }
    }
    function _openPopup() {
        const want = has("--a11y") ? "Accessibility" : "Shut down";
        const b = _find(greeter, it => it.tooltip === want);
        if (b) b.clicked();
    }
    function _find(item, pred) {
        if (!item) return null;
        if (pred(item)) return item;
        for (let i = 0; i < item.children.length; ++i) {
            const f = _find(item.children[i], pred);
            if (f) return f;
        }
        return null;
    }
}
