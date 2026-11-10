// Notifications demo: wallpaper + a stand-in bar, three toasts top-right
// (one with actions and a thumbnail, one critical, one with a long body) and,
// optionally, the notification center.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/notifications.qml \
//       /tmp/lugh-shots/notify/popups-light.png 1440 900 900 [-- flags]
//   --dark            dark theme
//   --accent <name>   amber | teal | green | blue | red | graphite
//   --center          open the notification center
//   --empty           clear the history first (empty state)
//   --more            post 5 toasts (shows the "+N more" pill)
//   --scrolled        scroll the center's history to the Mail group (collapsed)
//   --reduce          reduce motion
// Glass shows its plain tint here: the blur comes from the compositor.
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

    function post(appName, appIcon, summary, body, urgency, actions, image, ageMin, historyOnly) {
        const n = Services.notifications;
        const row = { nid: n._next++, appName: appName, appIcon: appIcon, summary: summary, body: body,
                      urgency: urgency, time: Date.now() - (ageMin || 0) * 60000,
                      actions: JSON.stringify(actions || []), image: image || "" };
        n.history.insert(0, row);
        if (!historyOnly) n.popups.insert(0, row);
    }
    function find(it, name) {
        if (it.objectName === name) return it;
        for (let i = 0; i < it.children.length; ++i) { const r = find(it.children[i], name); if (r) return r; }
        return null;
    }

    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce");
        if (flag("--empty")) Services.notifications.clearAll();
        if (!flag("--empty")) {
            // Older mail, history only: the Mail group gets 3 and collapses.
            post("Mail", "mail-client", "Jean-Paul Habimana — Icon review", "Attached are the new dock icons.", 1, [], "", 52, true);
            post("Mail", "mail-client", "Lugh weekly", "Phase 1 shell: bar, dock and launcher landed.", 0, [], "", 20, true);
            if (flag("--more")) {
                post("Files", "system-file-manager", "Copy finished", "4 files copied to Documents.", 1, [], "", 3);
                post("Terminal", "utilities-terminal", "Build finished", "cargo build --release finished in 41 s.", 0, [], "", 2);
            }
            post("Mail", "mail-client", "Keza Uwase — Notes from the shell review",
                 "Thanks for walking us through the dock and the launcher today. A few things we agreed on: the "
                 + "<b>notification stack</b> keeps three toasts, critical ones stay, and the calendar opens from the "
                 + "clock. Full notes are in <a href=\"https://lugh.space/notes\">the shared doc</a>.", 1, [], "", 1);
            post("Battery", "battery", "Battery critically low",
                 "8% left. Plug in the charger or the laptop will suspend in about 5 minutes.", 2,
                 [{ key: "settings", label: "Power settings" }], "", 0);
            post("Screenshot", "applets-screenshooter", "Screenshot saved",
                 "Saved to Pictures/Screenshots and copied to the clipboard.", 1,
                 [{ key: "default", label: "Open" }, { key: "edit", label: "Edit" }, { key: "folder", label: "Show in Files" }],
                 demo.repo + "branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-blur.jpg", 0);
        }
        if (flag("--center")) ShellState.notificationCenterOpen = true;
        if (flag("--scrolled")) Qt.callLater(() => { const l = find(center, "notificationHistory"); if (l) l.positionViewAtIndex(2, ListView.Beginning); });
    }

    // The repo's art directly: no lookup in /usr/share (warns when lugh-branding
    // isn't installed).
    Wallpaper {
        anchors.fill: parent
        source: demo.repo + "branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-2560x1600.jpg"
    }

    // Stand-in for the bar (30 px glass) so the toasts sit where they will.
    Rectangle {
        width: parent.width
        height: 30
        color: Theme.glass
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.glassBorder }
        Text {
            anchors { right: parent.right; rightMargin: Theme.space16; verticalCenter: parent.verticalCenter }
            text: Services.clock.date + "  " + Services.clock.time
            font: Theme.typeBodyTnum
            color: Theme.text
        }
    }

    NotificationPopups {
        anchors { top: parent.top; topMargin: 38; right: parent.right; rightMargin: 8 }
        visible: shown
    }

    NotificationCenter {
        id: center
        anchors.fill: parent
        visible: shown
    }
}
