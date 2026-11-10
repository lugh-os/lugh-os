// Greeter demo: the Greeter with a MockGreetd shaped by flags.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/greeter/qml/GreeterDemo.qml \
//       /tmp/lugh-shots/greeter/light.png 1440 900 [900 -- flags]
//
// Flags: --dark, --error (wrong-password state), --busy (authenticating),
//        --caps (Caps Lock warning), --many (14 users → username field),
//        --sessions (two sessions → session picker), --reduce, --a11y (opens
//        the accessibility menu), --confirm (shut-down confirmation).
// Live: `qml6 -I ui/components ui/greeter/qml/GreeterDemo.qml`; password "lugh".
import QtQuick
import Lugh.UI

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    function has(flag) { return Qt.application.arguments.indexOf(flag) >= 0 }

    MockGreetd {
        id: mock
        capsLock: demo.has("--caps")
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
        if (has("--a11y") || has("--confirm")) Qt.callLater(demo._openPopup);
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
